import UIKit
import AVFoundation
import MediaPlayer

// MPMoviePlayerController on both targets. The iPad (iOS 8) ran it for months by
// accident, through builds that mixed iOS 6 objects into the iOS 8 app, and everything
// here was tested on it there; the AVPlayerViewController version, once really built,
// had no Done button inside this pushed screen, so no way back out.
class VideoPlayerVC: UIViewController {
    private let item: MediaItem
    private var bufferSpinner: UIActivityIndicatorView!
    private let streamProxy = LocalStreamProxy()

    private var selectedAudioIndex: Int?        // Jellyfin stream index — AudioStreamIndex URL param
    private let subtitle: SubtitleChoice?       // drawn here, or SubtitleStreamIndex URL param
    private var forceTranscode: Bool            // a subtitle the server paints into the picture

    // A drawn subtitle: the track once loaded, the view showing it, and the timer keeping
    // it in step with the player.
    private var subtitleTrack: SubtitleTrack?
    private var subtitleOverlay: SubtitleOverlayView?
    private var subtitleTimer: Timer?

    // Jellyfin's view of this item as the detail page loaded it, weighed against this
    // device's own resume point (ResumeStore) to pick where playback starts.
    private let serverState: ServerPlayState?
    // "Play from Start" on the detail page: every saved resume point is ignored.
    private let startOver: Bool
    private var startPosition: Double = 0
    // The player is handed startPosition before it opens the stream; checked once it has.
    private var startConfirmed = false
    // One per playback: in the transcode URL, so the stop report also ends that ffmpeg
    // job, and in every report.
    private let playSessionId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    // The most a server conversion may use (HEVC files, burned-in subtitles). Jellyfin never
    // goes above the source, and an H.264 file within them still streams untouched — the
    // 4S and iPad mini play 1080p H.264. The bitrate also decides that: an H.264 file above
    // it gets converted, so it sits over the 10–13 Mbps of most 1080p files.
    private static let maxVideoBitrate = 20_000_000
    private static let maxVideoWidth = 1920
    // The detail page's Quality choice: a lower tier replaces both ceilings above.
    private let quality = VideoQuality.playback
    private var reporter: PlaybackReporter?
    // Played to the end: the teardown that follows must not save or report a position.
    private var didFinish = false

    private var player: MPMoviePlayerController?

    private var isAudio: Bool { item.type == "Audio" }

    init(item: MediaItem,
         audioIndex: Int? = nil,
         subtitle: SubtitleChoice? = nil,
         forceTranscode: Bool = false,
         serverState: ServerPlayState? = nil,
         startOver: Bool = false) {
        self.item = item
        self.selectedAudioIndex = audioIndex
        self.subtitle = subtitle
        self.forceTranscode = forceTranscode
        self.serverState = serverState
        self.startOver = startOver
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { return !isAudio }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = item.name
        view.backgroundColor = .black
        // The singleton audio player and this screen must never hold the audio
        // session at the same time.
        AudioPlayer.shared.pause()
        activateAudioSession()
        startPosition = startOver ? 0 : ResumeStore.startPosition(for: item.id, server: serverState)
        if isAudio { setupArtwork() }
        setupPlayer()
        setupBufferSpinner()
        setupSubtitles()
        if !isAudio {
            // The tracks in use, as the stream URL names them.
            reporter = PlaybackReporter(
                item: item, playSessionId: playSessionId,
                playMethod: DownloadManager.isDownloaded(item.id) ? "DirectPlay" : "Transcode",
                audioIndex: selectedAudioIndex,
                subtitleIndex: subtitle?.index)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !isAudio {
            navigationController?.setNavigationBarHidden(true, animated: animated)
            UIApplication.shared.setStatusBarHidden(true, with: .none)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if isAudio {
            let navBottom = navigationController?.navigationBar.frame.maxY ?? 64
            player?.view.frame = CGRect(x: 0, y: navBottom, width: view.bounds.width,
                                        height: view.bounds.height - navBottom)
        }
        player?.play()
        if let r = reporter, !r.isStarted {
            r.begin { [weak self] in
                guard let self = self else { return nil }
                return PlaybackSample(position: self.reportablePosition(), isPlaying: self.playerIsPlaying())
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !isAudio else { return }
        UIApplication.shared.setStatusBarHidden(true, with: .none)
        player?.view.frame = view.bounds
        bufferSpinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if !isAudio {
            navigationController?.setNavigationBarHidden(false, animated: animated)
            UIApplication.shared.setStatusBarHidden(false, with: .fade)
        }
        // Read before the player below is stopped.
        if !didFinish {
            savePosition()
            reporter?.stop(at: reportablePosition())
        }
        reporter = nil
        subtitleTimer?.invalidate()
        subtitleTimer = nil
        subtitleOverlay = nil       // a track still loading then finds nothing to start
        NotificationCenter.default.removeObserver(self)
        player?.stop()
        streamProxy.stop()
        // Only give the session up if AudioPlayer isn't using it — otherwise
        // backing out of a video would kill background audio.
        if !AudioPlayer.shared.isPlaying {
            try? AVAudioSession.sharedInstance().setActive(false)
        }
    }

    // MARK: - Common setup

    private func activateAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func setupArtwork() {
        guard let serverURL = JellyfinServer.serverURL else { return }
        let artView = AsyncImageView(frame: view.bounds)
        artView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        artView.contentMode = .scaleAspectFit
        artView.backgroundColor = .black
        artView.alpha = 0.4
        view.addSubview(artView)
        artView.load(url: "\(serverURL)/Items/\(item.id)/Images/Primary?width=600")
    }

    // MARK: - Stream URL

    // The URL actually handed to the player. Downloaded files are already
    // local, so they play directly — everything else is a remote Jellyfin
    // URL (http or https) and gets routed through the local TLS-safe proxy,
    // since neither MPMoviePlayerController nor AVPlayer can be given a
    // custom networking transport directly and iOS 6/7 Secure Transport
    // can't negotiate the GCM-only cipher suites modern Jellyfin/TLS
    // reverse proxies require.
    private func resolvedPlaybackURL() -> URL? {
        let dev = UIDevice.current
        let subMode: String
        switch subtitle {
        case .drawn?:    subMode = "drawn"
        case .burnedIn?: subMode = "burnedIn"
        case nil:        subMode = "off"
        }
        DebugLog.shared.log("Player", "OPEN \"\(item.name)\" type=\(item.type) id=\(item.id) device=\(dev.model)/\(dev.systemVersion) forceTranscode=\(forceTranscode) audioIdx=\(selectedAudioIndex ?? -1) subIdx=\(subtitle?.index ?? -1) sub=\(subMode) quality=\(quality.shortLabel) downloaded=\(DownloadManager.isDownloaded(item.id))")
        guard let remote = buildStreamURL() else {
            // Only reachable when serverURL/accessToken/userId is missing.
            DebugLog.shared.log("Player", "no stream URL — server=\(JellyfinServer.serverURL ?? "nil") token=\(JellyfinServer.accessToken == nil ? "nil" : "set") userId=\(JellyfinServer.userId == nil ? "nil" : "set")")
            return nil
        }
        if remote.isFileURL {
            let exists = FileManager.default.fileExists(atPath: remote.path)
            let attrs = try? FileManager.default.attributesOfItem(atPath: remote.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            DebugLog.shared.log("Player", "playing LOCAL file exists=\(exists) size=\(size)B \(remote.path)")
            return remote
        }
        DebugLog.shared.log("Player", "remote URL \(DebugLog.redact(remote.absoluteString))")
        guard let local = streamProxy.start(remoteURL: remote) else {
            DebugLog.shared.log("Player", "proxy unavailable — handing the player the DIRECT url (TLS unprotected on iOS 6/7)")
            return remote
        }
        DebugLog.shared.log("Player", "playing via proxy \(local.absoluteString)")
        return local
    }

    private func buildStreamURL() -> URL? {
        // Offline copy takes priority over any remote stream.
        if DownloadManager.isDownloaded(item.id) {
            return URL(fileURLWithPath: DownloadManager.filePath(for: item.id))
        }
        guard let serverURL = JellyfinServer.serverURL,
              let token = JellyfinServer.accessToken,
              let userId = JellyfinServer.userId else { return nil }
        let urlString: String
        if isAudio {
            let params = [
                "ApiKey=\(token)",
                "UserId=\(userId)",
                "DeviceId=\(JellyfinServer.deviceId)",
                "MaxStreamingBitrate=320000",
                "Container=mp3,aac,m4a%7Caac,m4b%7Caac",
                "TranscodingContainer=mp3",
                "TranscodingProtocol=http",
                "AudioCodec=mp3"
            ].joined(separator: "&")
            urlString = "\(serverURL)/Audio/\(item.id)/universal?\(params)"
        } else {
            var params = [
                "ApiKey=\(token)",
                "MediaSourceId=\(item.id)",
                "DeviceId=\(JellyfinServer.deviceId)",
                // master.m3u8 reads only these two (not MaxStreamingBitrate): without them
                // Jellyfin converts at its smallest size, 416 px / 256 kbps. A file within
                // both is still streamed untouched; one above either is converted.
                "VideoBitRate=\(quality.videoBitrate ?? VideoPlayerVC.maxVideoBitrate)",
                "MaxWidth=\(quality.maxWidth ?? VideoPlayerVC.maxVideoWidth)",
                "VideoCodec=h264",
                // What the A5/A6 decoder is rated for (1080p30, level 4.1). Without these
                // Jellyfin passes a 1080p50 or level 5.1 H.264 file along untouched.
                "h264-level=41",
                "MaxFramerate=30",
                "AudioCodec=aac",
                // Unique per playback: Jellyfin can't reuse a cached session for this DeviceId
                // (which would ignore the track params), and the stop report ends the
                // conversion an HEVC file needs even with no track chosen.
                "PlaySessionId=\(playSessionId)"
            ]
            if let audioBitrate = quality.audioBitrate {
                // Kept 5.1, the converted sound gets ~20 kbps a channel at these rates; the
                // phone only plays stereo anyway.
                params.append("AudioBitRate=\(audioBitrate)")
                params.append("MaxAudioChannels=2")
            }
            // Always named, the default track too: with none, Jellyfin plays the file's
            // first audio track, not its default (South Park S25: English first, French
            // the default). It applies the track whether it copies or converts the video.
            if let audioIdx = selectedAudioIndex {
                params.append("AudioStreamIndex=\(audioIdx)")
            }
            if forceTranscode {
                params.append("EnableDirectStream=false")
                params.append("EnableDirectPlay=false")
                if case .burnedIn(let subIdx)? = subtitle {
                    params.append("SubtitleStreamIndex=\(subIdx)")
                    params.append("SubtitleMethod=Encode")
                }
            }
            urlString = "\(serverURL)/Videos/\(item.id)/master.m3u8?\(params.joined(separator: "&"))"
        }
        return URL(string: urlString)
    }

    // MARK: - Player

    private func setupPlayer() {
        guard let url = resolvedPlaybackURL() else { return }
        guard let player = MPMoviePlayerController(contentURL: url) else {
            DebugLog.shared.log("Player", "MPMoviePlayerController init returned nil for \(url.absoluteString)")
            return
        }
        player.view.frame = view.bounds
        player.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        player.controlStyle = isAudio ? .embedded : .fullscreen
        player.shouldAutoplay = false
        if hasResumePoint {
            // The player then asks for the segment holding it first, instead of loading the
            // film's opening one and seeking away from it (~1 MB, ~1 s on the 4S).
            player.initialPlaybackTime = startPosition
        }
        if isAudio { player.view.backgroundColor = .clear }
        view.addSubview(player.view)
        player.prepareToPlay()
        self.player = player
        NotificationCenter.default.addObserver(self, selector: #selector(playbackFinished),
            name: NSNotification.Name.MPMoviePlayerPlaybackDidFinish, object: player)
        NotificationCenter.default.addObserver(self, selector: #selector(loadStateChanged),
            name: NSNotification.Name.MPMoviePlayerLoadStateDidChange, object: player)
        NotificationCenter.default.addObserver(self, selector: #selector(playbackStateChanged),
            name: NSNotification.Name.MPMoviePlayerPlaybackStateDidChange, object: player)
        NotificationCenter.default.addObserver(self, selector: #selector(durationAvailable),
            name: NSNotification.Name.MPMovieDurationAvailable, object: player)
        DebugLog.shared.log("Player", "MPMoviePlayerController prepareToPlay called")
    }

    private func setupBufferSpinner() {
        bufferSpinner = UIActivityIndicatorView(style: .whiteLarge)
        bufferSpinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        bufferSpinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin,
                                          .flexibleTopMargin, .flexibleBottomMargin]
        bufferSpinner.hidesWhenStopped = true
        bufferSpinner.startAnimating()
        view.addSubview(bufferSpinner)
    }

    @objc private func loadStateChanged() {
        guard let player = player else { return }
        let s = player.loadState
        // An empty loadState that never advances past 0 is the classic
        // "server/stream is fine but this device can't decode it" signature.
        var flags: [String] = []
        if s.contains(.playable) { flags.append("playable") }
        if s.contains(.playthroughOK) { flags.append("playthroughOK") }
        if s.contains(.stalled) { flags.append("stalled") }
        DebugLog.shared.log("Player", "loadState=[\(flags.isEmpty ? "none" : flags.joined(separator: "|"))] raw=\(s.rawValue)")
        if s.contains(.playable) { confirmStartPosition() }
        if s.contains(.playable) && !s.contains(.stalled) {
            bufferSpinner.stopAnimating()
        } else {
            bufferSpinner.startAnimating()
        }
    }

    @objc private func playbackStateChanged() {
        guard let player = player else { return }
        let names = ["stopped", "playing", "paused", "interrupted",
                     "seekingForward", "seekingBackward"]
        let raw = player.playbackState.rawValue
        let name = (raw >= 0 && raw < names.count) ? names[raw] : "unknown(\(raw))"
        DebugLog.shared.log("Player", "playbackState=\(name) time=\(String(format: "%.1f", player.currentPlaybackTime))s")
    }

    @objc private func durationAvailable() {
        guard let player = player else { return }
        DebugLog.shared.log("Player", "duration=\(String(format: "%.1f", player.duration))s naturalSize=\(Int(player.naturalSize.width))x\(Int(player.naturalSize.height))")
    }

    // nil until the player knows (NaN before the stream has loaded).
    private func playerTime() -> Double? {
        guard let t = player?.currentPlaybackTime, t.isFinite else { return nil }
        return t
    }

    // playbackState alone says .playing as soon as play() is called, before anything
    // has loaded — a stream that never loads must not count as started.
    private func playerIsPlaying() -> Bool {
        guard let p = player else { return false }
        return p.playbackState == .playing && p.loadState.contains(.playable)
    }

    private func seek(to seconds: Double) {
        player?.currentPlaybackTime = seconds
    }

    // MARK: - Drawn subtitles

    private func setupSubtitles() {
        guard case .drawn(let index)? = subtitle else { return }
        let overlay = SubtitleOverlayView(frame: view.bounds)
        // Over the player's view, its controls included: the overlay ignores touches and
        // lifts the line above the controls while they show (showCurrentCue).
        guard let playerView = player?.view else { return }
        view.insertSubview(overlay, aboveSubview: playerView)
        subtitleOverlay = overlay
        SubtitleTrack.load(itemId: item.id, index: index) { [weak self] track in
            guard let self = self, let overlay = self.subtitleOverlay else { return }
            guard let track = track else {
                overlay.text = "Subtitles couldn't be loaded"
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak overlay] in overlay?.text = nil }
                return
            }
            self.subtitleTrack = track
            let timer = Timer(timeInterval: 0.1, target: SubtitleTicker { [weak self] in self?.showCurrentCue() },
                              selector: #selector(SubtitleTicker.fire), userInfo: nil, repeats: true)
            // .common: keeps running while the scrubber is dragged.
            RunLoop.main.add(timer, forMode: .common)
            self.subtitleTimer = timer
        }
    }

    private func showCurrentCue() {
        guard let overlay = subtitleOverlay else { return }
        let text = playerTime().flatMap { subtitleTrack?.text(at: $0) }
        // Only while a line shows: where the controls are doesn't matter between lines.
        if text != nil {
            if let playerView = player?.view { overlay.keepClear(of: playerView) }
        }
        overlay.text = text
    }

    // MARK: - Shared

    // Under 10 s isn't worth resuming, the same threshold savePosition() keeps to.
    private var hasResumePoint: Bool { return startPosition > 10 }

    // Once the stream has opened, the player should already stand at the resume point it
    // was given before opening (to the segment boundary, a few seconds early at most). A
    // stream that ignored it gets the old seek instead.
    private func confirmStartPosition() {
        guard !startConfirmed else { return }
        startConfirmed = true
        guard hasResumePoint else { return }
        let target = startPosition
        if let t = playerTime(), abs(t - target) < 15 {
            DebugLog.shared.log("Player", "opened at \(String(format: "%.1f", t))s for resume point \(String(format: "%.1f", target))s")
            return
        }
        let at = playerTime().map { String(format: "%.1f", $0) } ?? "?"
        DebugLog.shared.log("Player", "opened at \(at)s, not at resume point \(String(format: "%.1f", target))s — seeking there")
        seek(to: target)
    }

    private func savePosition() {
        guard let t = playerTime(), t > 10 else { return }
        ResumeStore.save(t, for: item.id)
    }

    // The position the reports carry. Under 10 s doesn't count, same as savePosition:
    // backing out before the player has reached the resume point must report the resume
    // point, not wipe it on the server.
    private func reportablePosition() -> Double {
        if let t = playerTime(), t > 10 { return t }
        return startPosition
    }

    @objc private func playbackFinished(_ notification: Notification) {
        // "playbackError" here is the single most telling line when a stream
        // plays on one device but not another — MPMoviePlayerController
        // reports a failed decode/load as a *finish*, not as an error.
        let raw = (notification.userInfo?[MPMoviePlayerPlaybackDidFinishReasonUserInfoKey] as? NSNumber)?.intValue ?? -1
        let reason: String
        switch raw {
        case MPMovieFinishReason.playbackEnded.rawValue: reason = "playbackEnded"
        case MPMovieFinishReason.playbackError.rawValue: reason = "playbackError"
        case MPMovieFinishReason.userExited.rawValue:    reason = "userExited"
        default:                                         reason = "unknown(\(raw))"
        }
        let err = notification.userInfo?["error"] as? NSError
        DebugLog.shared.log("Player", "playbackFinished reason=\(reason)"
            + (err == nil ? "" : " error=[domain=\(err!.domain) code=\(err!.code) \(err!.localizedDescription)]"))
        // Done and errors end here too; viewWillDisappear saves and reports those.
        var playedToEnd = raw == MPMovieFinishReason.playbackEnded.rawValue
        // A stream that dies part-way can still end as "played to the end"; only call it
        // finished if the player got near the end (or can no longer say where it was).
        if playedToEnd, let t = playerTime(), t > 10,
           let dur = item.durationSeconds, t < dur * 0.9 {
            DebugLog.shared.log("Player", "ended at \(Int(t))s of \(Int(dur))s — keeping it resumable")
            playedToEnd = false
        }
        if playedToEnd {
            didFinish = true
            ResumeStore.clear(item.id)
            reporter?.finish()
        }
        navigationController?.popViewController(animated: true)
    }
}
