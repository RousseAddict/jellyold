import UIKit
import AVFoundation
import MediaPlayer

// Singleton audio player. Unlike VideoPlayerVC (which is a view controller and
// dies with its screen), this outlives every view controller so audio keeps
// playing while you browse, in the background, and from the lock screen.
//
// Only ObjC-bridged AVFoundation entry points are used here — AVPlayer(playerItem:)
// rather than AVPlayer(url:), CMTimeGetSeconds/CMTimeMakeWithSeconds rather than
// the CMTime Swift overlay properties. Those overlay symbols aren't exported by
// the Swift 5.1.5 runtime dylibs this app ships, and Swift overlay calls bind
// non-lazily: a single missing one crashes the whole binary at dyld load.
final class AudioPlayer: NSObject {
    static let shared = AudioPlayer()

    // Owned for the app's lifetime. Neither AVPlayer nor MPMoviePlayerController
    // can be handed a custom transport, and iOS 6/7 Secure Transport can't
    // negotiate the GCM-only ciphers a modern Jellyfin sits behind — so every
    // stream is fronted by this loopback server, which fetches over
    // libcurl + embedded OpenSSL. Only stopAll() shuts it down; a view
    // controller disappearing must never do so.
    private let proxy = LocalStreamProxy()

    private var player: AVPlayer?
    private var timeObserver: Any?
    private weak var observedItem: AVPlayerItem?
    private(set) var currentItem: MediaItem?

    // Single-slot UI hooks, owned by whichever NowPlayingVC is on screen.
    // MiniPlayerBar and QueueVC deliberately poll instead of registering here.
    var onProgress: ((Double, Double) -> Void)?
    var onStateChange: (() -> Void)?
    var onFinish: (() -> Void)?

    private var progressTick = 0
    private var reportedDuration: Double = 0

    // Resume positions are namespaced away from VideoPlayerVC's "resume_<id>",
    // which it writes for Audio items too with a 10-second threshold — that
    // would drop you into the middle of a three-minute song.
    private static func resumeKey(_ id: String) -> String { return "aresume_\(id)" }

    // Only long-form audio (audiobook chapters, DJ sets, lectures) resumes.
    private static let resumeMinDuration: Double = 900

    private override init() {
        super.init()
    }

    // MARK: - State

    var isPlaying: Bool { return (player?.rate ?? 0) != 0 }

    // False right after a launch: the queue is restored from disk but no player
    // exists yet, because nothing on the launch path may touch the proxy.
    var isLoaded: Bool { return player != nil }

    var currentTime: Double {
        guard let t = player?.currentTime() else { return 0 }
        return AudioPlayer.sane(CMTimeGetSeconds(t))
    }

    // runTimeTicks first, AVPlayerItem.duration only as a fallback: a
    // transcoded (FLAC/Opus-source) track arrives chunked with no
    // Content-Length, so its item duration is indefinite and CMTimeGetSeconds
    // hands back NaN — which would silently kill the scrubber and time labels.
    var duration: Double {
        if reportedDuration > 0 { return reportedDuration }
        guard let d = player?.currentItem?.duration else { return 0 }
        return AudioPlayer.sane(CMTimeGetSeconds(d))
    }

    private static func sane(_ v: Double) -> Double {
        return (v.isNaN || v.isInfinite || v < 0) ? 0 : v
    }

    // MARK: - Playback

    // Starts `item`. Called by AudioQueue on every actual track switch — and
    // only then, since each call is exactly one proxy.start(), which bumps the
    // proxy's generation counter and so aborts any relay still feeding the
    // previous track. That's also why there's no prefetch and no AVQueuePlayer.
    func play(item: MediaItem) {
        teardownPlayer()
        currentItem = item
        activateSession()

        guard let url = resolvedURL(for: item) else {
            DebugLog.shared.log("Audio", "no stream URL for \"\(item.name)\" — server=\(JellyfinServer.serverURL ?? "nil") token=\(JellyfinServer.accessToken == nil ? "nil" : "set")")
            onStateChange?()
            return
        }

        let avItem = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: avItem)
        player = p
        reportedDuration = item.durationSeconds ?? 0

        avItem.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
        observedItem = avItem
        // object: avItem, not nil — on the iOS 8 target a finishing *video*
        // posts this same notification, which would skip the audio queue on.
        NotificationCenter.default.addObserver(self, selector: #selector(itemDidFinish),
            name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: avItem)

        addTimeObserver()

        var startAt: Double = 0
        let saved = UserDefaults.standard.double(forKey: AudioPlayer.resumeKey(item.id))
        if saved > 10, (item.durationSeconds ?? 0) > AudioPlayer.resumeMinDuration { startAt = saved }
        if startAt > 0 { p.seek(to: CMTimeMakeWithSeconds(startAt, preferredTimescale: 1)) }

        p.play()
        updateNowPlaying(item: item, elapsed: startAt)
        onStateChange?()
    }

    func pause() {
        guard player != nil else { return }
        player?.pause()
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        onStateChange?()
    }

    func resume() {
        // After a relaunch the queue is populated but no player was ever built.
        guard let item = currentItem ?? AudioQueue.shared.current else { return }
        guard player != nil, currentItem != nil else { play(item: item); return }
        activateSession() // a video may have taken the session over in between
        player?.play()
        // The whole payload is re-pushed rather than just poking PlaybackRate:
        // on iOS 6 MPMoviePlayerController replaces the now-playing info
        // wholesale, so after watching a video ours is simply gone.
        updateNowPlaying(item: item, elapsed: currentTime)
        onStateChange?()
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func seek(to seconds: Double) {
        guard player != nil else { return }
        player?.seek(to: CMTimeMakeWithSeconds(seconds, preferredTimescale: 1))
        onProgress?(seconds, duration)
    }

    // MARK: - Teardown

    // Between tracks: drops the player and its observers but keeps the queue and
    // the now-playing info, and leaves the proxy alone — play() bumps its
    // generation once, and a second bump here would abort the new track's relay.
    private func teardownPlayer() {
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        timeObserver = nil
        if let observed = observedItem {
            observed.removeObserver(self, forKeyPath: "status")
            NotificationCenter.default.removeObserver(self,
                name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: observed)
            observedItem = nil
        }
        player?.pause()
        player = nil
        progressTick = 0
        reportedDuration = 0
    }

    // The user closed the mini bar. Clears the queue, drops the lock-screen
    // info and releases the loopback socket — the one and only proxy.stop().
    func stopAll() {
        teardownPlayer()
        currentItem = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        proxy.stop()
        AudioQueue.shared.clear()
        try? AVAudioSession.sharedInstance().setActive(false)
        onStateChange?()
    }

    // MARK: - Session

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: - Progress

    private func addTimeObserver() {
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTimeMakeWithSeconds(1, preferredTimescale: 1),
            queue: .main) { [weak self] time in
                self?.tick(time)
        }
    }

    private func tick(_ time: CMTime) {
        let cur = AudioPlayer.sane(CMTimeGetSeconds(time))
        let dur = duration
        progressTick += 1
        onProgress?(cur, dur)
        // Both a UserDefaults write and a now-playing-info push flush on the
        // main thread — doing either every second visibly stalls a 4S, and iOS
        // interpolates the lock-screen scrubber in between anyway.
        if progressTick % 5 == 0 {
            savePosition(cur)
            updateNowPlayingElapsed(cur, duration: dur)
        }
    }

    private func savePosition(_ seconds: Double) {
        guard let item = currentItem,
              (item.durationSeconds ?? 0) > AudioPlayer.resumeMinDuration else { return }
        UserDefaults.standard.set(seconds, forKey: AudioPlayer.resumeKey(item.id))
    }

    // MARK: - Item status / end of track

    // Old-style KVO — Swift's observe() is iOS 9+.
    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        guard keyPath == "status", let item = object as? AVPlayerItem else { return }
        if item.status == .readyToPlay {
            DebugLog.shared.log("Audio", "readyToPlay dur=\(String(format: "%.1f", duration))s")
        } else if item.status == .failed {
            let e = item.error as NSError?
            DebugLog.shared.log("Audio", "status=FAILED "
                + (e == nil ? "(no error object)"
                            : "domain=\(e!.domain) code=\(e!.code) \(e!.localizedDescription)"))
        }
        onStateChange?()
    }

    @objc private func itemDidFinish() {
        guard let item = currentItem else { return }
        DebugLog.shared.log("Audio", "finished \"\(item.name)\"")
        UserDefaults.standard.removeObject(forKey: AudioPlayer.resumeKey(item.id))
        // onFinish is a UI-only notification: it's a single slot that only
        // exists while NowPlayingVC is on screen, so hanging the queue advance
        // off it would stop gapless playback the moment you navigate back.
        onFinish?()
        if !AudioQueue.shared.advanceAfterFinish() {
            // End of queue — leave the track loaded and paused so the bar stays.
            onStateChange?()
        }
    }

    // MARK: - Stream URL

    private func resolvedURL(for item: MediaItem) -> URL? {
        guard let remote = streamURL(for: item) else { return nil }
        let dev = UIDevice.current
        DebugLog.shared.log("Audio", "OPEN \"\(item.name)\" id=\(item.id) device=\(dev.model)/\(dev.systemVersion) dur=\(item.durationSeconds.map { String(format: "%.0f", $0) } ?? "?")s remote=\(DebugLog.redact(remote.absoluteString))")
        // extHint "mp3": /Audio/{id}/universal carries no extension, and the
        // proxy's default for that case is "ts".
        guard let local = proxy.start(remoteURL: remote, extHint: "mp3") else {
            DebugLog.shared.log("Audio", "proxy unavailable — using the DIRECT url (TLS unprotected on iOS 6/7)")
            return remote
        }
        return local
    }

    private func streamURL(for item: MediaItem) -> URL? {
        guard let serverURL = JellyfinServer.serverURL,
              let token = JellyfinServer.accessToken,
              let userId = JellyfinServer.userId else { return nil }
        let params = [
            "api_key=\(token)",
            "UserId=\(userId)",
            "DeviceId=jellyold-device-01",
            "MaxStreamingBitrate=320000",
            "Container=mp3,aac,m4a%7Caac,m4b%7Caac",
            "TranscodingContainer=mp3",
            "TranscodingProtocol=http",
            "AudioCodec=mp3"
        ].joined(separator: "&")
        return URL(string: "\(serverURL)/Audio/\(item.id)/universal?\(params)")
    }

    // MARK: - Now Playing info (lock screen / control centre)

    private func updateNowPlaying(item: MediaItem, elapsed: Double) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.name,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]
        if let artist = item.artistText { info[MPMediaItemPropertyArtist] = artist }
        if let album = item.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        loadArtwork(for: item)
    }

    // Not AsyncImageView: that fetches over NSURLConnection, which on iOS 6
    // can't negotiate the GCM-only TLS a modern Jellyfin sits behind. CurlFetcher
    // goes through libcurl + embedded OpenSSL like the rest of the app's traffic.
    private func loadArtwork(for item: MediaItem) {
        guard let serverURL = JellyfinServer.serverURL else { return }
        let itemId = item.id
        CurlFetcher.fetchData(url: "\(serverURL)/Items/\(itemId)/Images/Primary?width=300") { [weak self] data in
            guard let self = self, let data = data, let image = UIImage(data: data) else { return }
            // The track may have moved on while this was in flight.
            guard self.currentItem?.id == itemId else { return }
            var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            updated[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(image: image)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
        }
    }

    private func updateNowPlayingElapsed(_ elapsed: Double, duration: Double) {
        guard MPNowPlayingInfoCenter.default().nowPlayingInfo != nil else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        if duration > 0 {
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] = duration
        }
    }
}
