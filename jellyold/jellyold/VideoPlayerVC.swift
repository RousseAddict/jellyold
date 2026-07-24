import UIKit
import AVFoundation
#if IOS6_TARGET
import MediaPlayer
#else
import AVKit
#endif

class VideoPlayerVC: UIViewController {
    private let item: MediaItem
    private var bufferSpinner: UIActivityIndicatorView!
    private let streamProxy = LocalStreamProxy()

    private var selectedAudioIndex: Int?        // Jellyfin stream index — AudioStreamIndex URL param
    private var selectedSubtitleIndex: Int?     // Jellyfin stream index — SubtitleStreamIndex URL param
    private var forceTranscode: Bool            // forces Jellyfin to transcode and honour stream index params

#if IOS6_TARGET
    private var player: MPMoviePlayerController?
#else
    private var avPlayer: AVPlayer?
    private var playerVC: AVPlayerViewController?
    private weak var observedItem: AVPlayerItem?
#endif

    private var isAudio: Bool { item.type == "Audio" }

    init(item: MediaItem,
         audioIndex: Int? = nil,
         subtitleIndex: Int? = nil,
         forceTranscode: Bool = false) {
        self.item = item
        self.selectedAudioIndex = audioIndex
        self.selectedSubtitleIndex = subtitleIndex
        self.forceTranscode = forceTranscode
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { return !isAudio }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = item.name
        view.backgroundColor = .black
        activateAudioSession()
        if isAudio { setupArtwork() }
        setupPlayer()
        setupBufferSpinner()
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
#if IOS6_TARGET
            player?.view.frame = CGRect(x: 0, y: navBottom, width: view.bounds.width,
                                        height: view.bounds.height - navBottom)
#else
            playerVC?.view.frame = CGRect(x: 0, y: navBottom, width: view.bounds.width,
                                          height: view.bounds.height - navBottom)
#endif
        }
#if IOS6_TARGET
        player?.play()
#else
        avPlayer?.play()
#endif
        restorePosition()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !isAudio else { return }
        UIApplication.shared.setStatusBarHidden(true, with: .none)
#if IOS6_TARGET
        player?.view.frame = view.bounds
        bufferSpinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
#else
        playerVC?.view.frame = view.bounds
#endif
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if !isAudio {
            navigationController?.setNavigationBarHidden(false, animated: animated)
            UIApplication.shared.setStatusBarHidden(false, with: .fade)
        }
        savePosition()
        NotificationCenter.default.removeObserver(self)
#if IOS6_TARGET
        player?.stop()
#else
        avPlayer?.pause()
        if let observed = observedItem {
            observed.removeObserver(self, forKeyPath: "status")
            observedItem = nil
        }
#endif
        streamProxy.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
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
        DebugLog.shared.log("Player", "OPEN \"\(item.name)\" type=\(item.type) id=\(item.id) device=\(dev.model)/\(dev.systemVersion) forceTranscode=\(forceTranscode) audioIdx=\(selectedAudioIndex ?? -1) subIdx=\(selectedSubtitleIndex ?? -1) downloaded=\(DownloadManager.isDownloaded(item.id))")
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
                "api_key=\(token)",
                "UserId=\(userId)",
                "DeviceId=jellyold-device-01",
                "MaxStreamingBitrate=320000",
                "Container=mp3,aac,m4a%7Caac,m4b%7Caac",
                "TranscodingContainer=mp3",
                "TranscodingProtocol=http",
                "AudioCodec=mp3"
            ].joined(separator: "&")
            urlString = "\(serverURL)/Audio/\(item.id)/universal?\(params)"
        } else {
            var params = [
                "api_key=\(token)",
                "MediaSourceId=\(item.id)",
                "DeviceId=jellyold-device-01",
                "MaxStreamingBitrate=8000000",
                "VideoCodec=h264",
                "AudioCodec=aac"
            ]
            if forceTranscode {
                // A unique PlaySessionId prevents Jellyfin reusing a cached direct-stream
                // session for the same DeviceId, which would silently ignore the params.
                let sessionId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                params.append("PlaySessionId=\(sessionId)")
                params.append("EnableDirectStream=false")
                params.append("EnableDirectPlay=false")
                if let audioIdx = selectedAudioIndex {
                    params.append("AudioStreamIndex=\(audioIdx)")
                }
                if let subIdx = selectedSubtitleIndex {
                    params.append("SubtitleStreamIndex=\(subIdx)")
                    params.append("SubtitleMethod=Encode")
                }
            }
            urlString = "\(serverURL)/Videos/\(item.id)/master.m3u8?\(params.joined(separator: "&"))"
        }
        return URL(string: urlString)
    }

    // MARK: - iOS 6/7 player

#if IOS6_TARGET
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

    private func savePosition() {
        guard let player = player else { return }
        let t = player.currentPlaybackTime
        if t > 10 { UserDefaults.standard.set(t, forKey: resumeKey) }
    }

    private func restorePosition() {
        let saved = UserDefaults.standard.double(forKey: resumeKey)
        guard saved > 10 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.player?.currentPlaybackTime = saved
        }
    }

    // MARK: - iOS 8/9 player

#else
    private func setupPlayer() {
        guard let url = resolvedPlaybackURL() else { return }
        let avPlayer = AVPlayer(url: url)
        DebugLog.shared.log("Player", "AVPlayer created")
        self.avPlayer = avPlayer
        let playerVC = AVPlayerViewController()
        playerVC.player = avPlayer
        playerVC.showsPlaybackControls = true
        if isAudio { playerVC.view.backgroundColor = .clear }
        addChild(playerVC)
        playerVC.view.frame = view.bounds
        playerVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(playerVC.view)
        playerVC.didMove(toParent: self)
        self.playerVC = playerVC
        NotificationCenter.default.addObserver(self, selector: #selector(playbackFinished),
            name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: avPlayer.currentItem)
        NotificationCenter.default.addObserver(self, selector: #selector(itemFailedToPlay(_:)),
            name: NSNotification.Name.AVPlayerItemFailedToPlayToEndTime, object: avPlayer.currentItem)
        NotificationCenter.default.addObserver(self, selector: #selector(itemStalled),
            name: NSNotification.Name.AVPlayerItemPlaybackStalled, object: avPlayer.currentItem)
        // KVO on status is the only place AVFoundation surfaces the real
        // decode/network error behind a stream that just never starts.
        if let currentItem = avPlayer.currentItem {
            currentItem.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
            observedItem = currentItem
        }
    }

    @objc private func itemFailedToPlay(_ notification: Notification) {
        let err = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
        DebugLog.shared.log("Player", "AVPlayerItem FAILED to play to end: \(describe(err))")
    }

    @objc private func itemStalled() {
        DebugLog.shared.log("Player", "AVPlayerItem playback stalled")
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == "status", let item = object as? AVPlayerItem else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        switch item.status {
        case .readyToPlay:
            DebugLog.shared.log("Player", "AVPlayerItem status=readyToPlay duration=\(String(format: "%.1f", item.duration.seconds))s")
        case .failed:
            DebugLog.shared.log("Player", "AVPlayerItem status=FAILED \(describe(item.error as NSError?))")
        case .unknown:
            DebugLog.shared.log("Player", "AVPlayerItem status=unknown")
        @unknown default:
            DebugLog.shared.log("Player", "AVPlayerItem status=unhandled")
        }
    }

    private func describe(_ err: NSError?) -> String {
        guard let e = err else { return "(no error object)" }
        var out = "domain=\(e.domain) code=\(e.code) \(e.localizedDescription)"
        if let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError {
            out += " underlying=[domain=\(underlying.domain) code=\(underlying.code) \(underlying.localizedDescription)]"
        }
        return out
    }

    private func setupBufferSpinner() {
        // AVPlayerViewController provides its own loading indicator
        bufferSpinner = UIActivityIndicatorView(style: .whiteLarge)
    }

    private func savePosition() {
        guard let avPlayer = avPlayer else { return }
        let t = avPlayer.currentTime().seconds
        if t > 10 { UserDefaults.standard.set(t, forKey: resumeKey) }
    }

    private func restorePosition() {
        let saved = UserDefaults.standard.double(forKey: resumeKey)
        guard saved > 10 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let player = self?.avPlayer else { return }
            player.seek(to: CMTime(seconds: saved, preferredTimescale: 1000))
        }
    }
#endif

    // MARK: - Shared

    private var resumeKey: String { "resume_\(item.id)" }

    @objc private func playbackFinished(_ notification: Notification) {
#if IOS6_TARGET
        // "playbackError" here is the single most telling line when a stream
        // plays on one device but not another — MPMoviePlayerController
        // reports a failed decode/load as a *finish*, not as an error.
        let reasons = ["playbackEnded", "userExited", "playbackError"]
        let raw = (notification.userInfo?[MPMoviePlayerPlaybackDidFinishReasonUserInfoKey] as? NSNumber)?.intValue ?? -1
        let reason = (raw >= 0 && raw < reasons.count) ? reasons[raw] : "unknown(\(raw))"
        let err = notification.userInfo?["error"] as? NSError
        DebugLog.shared.log("Player", "playbackFinished reason=\(reason)"
            + (err == nil ? "" : " error=[domain=\(err!.domain) code=\(err!.code) \(err!.localizedDescription)]"))
#else
        DebugLog.shared.log("Player", "playbackFinished (played to end)")
#endif
        UserDefaults.standard.removeObject(forKey: resumeKey)
        navigationController?.popViewController(animated: true)
    }
}
