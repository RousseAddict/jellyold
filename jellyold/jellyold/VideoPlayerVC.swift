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

    private let playSessionId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var initialPosition = 0.0
    private var positionTicks: Int64 = 0
    private var reportTimer: Timer?
    private var playbackReady = false
    private var didBeginPlayback = false
    private var appeared = false
    private var closing = false
    private var completed = false
    private weak var playbackNavigation: UINavigationController?
    private var reportedStart = false
    private var reportedStop = false
    private var lastReportTime = Date.distantPast
    private var lastSampleTime = Date()
    private var lastSamplePosition = 0.0
    private var lastPaused = false

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
        // The singleton audio player and this screen must never hold the audio
        // session at the same time.
        AudioPlayer.shared.pause()
        activateAudioSession()
        if isAudio { setupArtwork() }
        // Fetch again at Play time: another device may have advanced since
        // the shelf/detail was loaded. A server zero overrides stale local resume.
        loadServerPosition()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !closing else { return }
        playbackNavigation = navigationController
        if !isAudio {
            navigationController?.setNavigationBarHidden(true, animated: animated)
            UIApplication.shared.setStatusBarHidden(true, with: .none)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !closing else { return }
        appeared = true
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
        if playbackReady { beginPlayback() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // UIKit can lay out the outgoing video during the pop transition.
        // It must not hide the status bar again after viewWillDisappear restored it.
        guard !isAudio, !closing else { return }
        UIApplication.shared.setStatusBarHidden(true, with: .none)
#if IOS6_TARGET
        player?.view.frame = view.bounds
        bufferSpinner?.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
#else
        playerVC?.view.frame = view.bounds
#endif
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if !isAudio {
            UIApplication.shared.setStatusBarHidden(false, with: .none)
            navigationController?.setNavigationBarHidden(false, animated: animated)
        }
        closing = true
        sampleProgress(force: false)
        stopReporting(ended: false, failed: false)
        savePosition()
        reportTimer?.invalidate()
        reportTimer = nil
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
        // Only give the session up if AudioPlayer isn't using it — otherwise
        // backing out of a video would kill background audio.
        if !AudioPlayer.shared.isPlaying {
            try? AVAudioSession.sharedInstance().setActive(false)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Finish restoration after UIKit's outgoing full-screen transition.
        // A late appearance/layout callback must not leave the browser full-screen.
        guard closing, !isAudio, let nav = playbackNavigation,
              !(nav.topViewController is VideoPlayerVC) else { return }
        UIApplication.shared.setStatusBarHidden(false, with: .none)
        nav.setNavigationBarHidden(false, animated: false)
        nav.view.setNeedsLayout()
        nav.view.layoutIfNeeded()
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
                "api_key=\(token)",
                "MediaSourceId=\(item.id)",
                "DeviceId=\(JellyfinServer.deviceId)",
                "MaxStreamingBitrate=8000000",
                "VideoCodec=h264",
                "AudioCodec=aac",
                "PlaySessionId=\(playSessionId)"
            ]
            if forceTranscode {
                // A unique PlaySessionId prevents Jellyfin reusing a cached direct-stream
                // session for the same DeviceId, which would silently ignore the params.
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
        player.initialPlaybackTime = initialPosition
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
        bufferSpinner?.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
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
        if !closing { sampleProgress(force: true) }
    }

    @objc private func durationAvailable() {
        guard let player = player else { return }
        DebugLog.shared.log("Player", "duration=\(String(format: "%.1f", player.duration))s naturalSize=\(Int(player.naturalSize.width))x\(Int(player.naturalSize.height))")
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
        finishPlayback(ended: false, failed: true)
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
        DispatchQueue.main.async { [weak self, weak item] in
            guard let self = self, let item = item, !self.closing else { return }
            self.handlePlayerStatus(item)
        }
    }

    private func handlePlayerStatus(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            DebugLog.shared.log("Player", "AVPlayerItem status=readyToPlay duration=\(String(format: "%.1f", item.duration.seconds))s")
            if appeared && playbackReady { beginPlayback() }
        case .failed:
            DebugLog.shared.log("Player", "AVPlayerItem status=FAILED \(describe(item.error as NSError?))")
            finishPlayback(ended: false, failed: true)
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


#endif

    // MARK: - Shared

    private func savePosition() {
        if completed { UserDefaults.standard.removeObject(forKey: resumeKey) }
        else { UserDefaults.standard.set(PlaybackPosition.seconds(ticks: positionTicks), forKey: resumeKey) }
    }

    private var resumeKey: String { "resume_\(item.id)" }

    @objc private func playbackFinished(_ notification: Notification) {
#if IOS6_TARGET
        let reason = (notification.userInfo?[MPMoviePlayerPlaybackDidFinishReasonUserInfoKey] as? NSNumber)?.intValue ?? -1
        let ended = reason == MPMovieFinishReason.playbackEnded.rawValue
        let failed = reason == MPMovieFinishReason.playbackError.rawValue
#else
        let ended = true
        let failed = false
#endif
        finishPlayback(ended: ended, failed: failed)
    }

    private func finishPlayback(ended: Bool, failed: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.finishPlayback(ended: ended, failed: failed) }
            return
        }
        guard !closing else { return }
        closing = true
        completed = ended && !failed
        stopReporting(ended: ended, failed: failed)
        if ended && !failed { UserDefaults.standard.removeObject(forKey: resumeKey) }
        else { savePosition() }
        navigationController?.popViewController(animated: true)
    }

    private func loadServerPosition() {
        guard let server = JellyfinServer.serverURL, let user = JellyfinServer.userId else { return }
        HTTPClient.get(url: "\(server)/Users/\(user)/Items/\(item.id)",
                       headers: ["Authorization": JellyfinServer.authHeader()]) { [weak self] data, _ in
            guard let self = self, !self.closing else { return }
            var serverTicks = self.item.playbackPositionTicks
            if let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let userData = json["UserData"] as? [String: Any],
               let ticks = userData["PlaybackPositionTicks"] as? NSNumber { serverTicks = ticks.int64Value }
            self.initialPosition = PlaybackPosition.resume(serverTicks: serverTicks,
                localSeconds: UserDefaults.standard.double(forKey: self.resumeKey), duration: self.item.durationSeconds ?? 0)
            self.positionTicks = PlaybackPosition.ticks(seconds: self.initialPosition) ?? 0
            self.lastSamplePosition = self.initialPosition
            self.setupBufferSpinner()
            self.setupPlayer()
            guard !self.closing else { return }
            self.playbackReady = true
            NotificationCenter.default.addObserver(self, selector: #selector(self.backgrounded),
                name: UIApplication.didEnterBackgroundNotification, object: nil)
            self.reportTimer = Timer.scheduledTimer(timeInterval: 1, target: self,
                selector: #selector(self.pollProgress), userInfo: nil, repeats: true)
            if self.appeared { self.beginPlayback() }
        }
    }

    private func beginPlayback() {
        guard !closing, !didBeginPlayback else { return }
#if IOS6_TARGET
        guard let player = player else { return }
        didBeginPlayback = true
        player.play()
#else
        guard let player = avPlayer, player.currentItem?.status == .readyToPlay else { return }
        didBeginPlayback = true
        if initialPosition > 0 {
            player.seek(to: CMTime(seconds: initialPosition, preferredTimescale: 1000)) { [weak self, weak player] _ in
                DispatchQueue.main.async {
                    guard let self = self, !self.closing else { return }
                    player?.play()
                }
            }
        } else { player.play() }
#endif
    }
    @objc private func pollProgress() { sampleProgress(force: false) }
    @objc private func backgrounded() {
#if IOS6_TARGET
        player?.pause()
#else
        avPlayer?.pause()
#endif
        sampleProgress(force: true)
        savePosition()
    }
    private func sampleProgress(force: Bool) {
        guard playbackReady, !reportedStop else { return }
#if IOS6_TARGET
        guard let player = player else { return }
        let state = player.playbackState
        guard state == .playing || state == .paused || state == .seekingForward || state == .seekingBackward else { return }
        let time = player.currentPlaybackTime
        let paused = state != .playing
        guard player.loadState.contains(.playable) else { return }
#else
        guard let player = avPlayer, player.currentItem?.status == .readyToPlay else { return }
        let time = CMTimeGetSeconds(player.currentTime())
        let paused = player.rate == 0
#endif
        guard let ticks = PlaybackPosition.ticks(seconds: time, duration: item.durationSeconds ?? 0) else { return }
        // Before initial resume has landed, the player may announce time zero.
        if !reportedStart && initialPosition > 0 && time < initialPosition - 2 { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSampleTime)
        let seeked = abs(time - lastSamplePosition) > max(3, elapsed + 2)
        positionTicks = ticks
        lastSamplePosition = time
        lastSampleTime = now
        if !reportedStart {
            guard !paused else { return }
            reportedStart = true
            report("Playing", paused: false)
        } else if !closing && (force || seeked || paused != lastPaused || now.timeIntervalSince(lastReportTime) >= 10) {
            report("Playing/Progress", paused: paused)
        }
        lastPaused = paused
        savePosition()
    }
    private func stopReporting(ended: Bool, failed: Bool) {
        guard !reportedStop else { return }
        reportedStop = true
        reportTimer?.invalidate()
        reportTimer = nil
        // A decode/load failure before the first frame is not a watched item.
        guard reportedStart else { return }
        positionTicks = PlaybackPosition.stopped(last: positionTicks, duration: item.durationSeconds ?? 0,
                                                  ended: ended, failed: failed)
        report("Playing/Stopped", paused: true, failed: failed)
    }
    private func report(_ endpoint: String, paused: Bool, failed: Bool = false) {
        guard let server = JellyfinServer.serverURL else { return }
        var body: [String: Any] = ["ItemId": item.id, "MediaSourceId": item.id,
            "PlaySessionId": playSessionId, "PositionTicks": NSNumber(value: positionTicks)]
        if endpoint == "Playing/Stopped" {
            body["Failed"] = failed
        } else {
            body["CanSeek"] = true
            body["IsPaused"] = paused
            body["IsMuted"] = false
            body["PlayMethod"] = DownloadManager.isDownloaded(item.id) ? "DirectPlay" : "Transcode"
            if let index = selectedAudioIndex { body["AudioStreamIndex"] = index }
            if let index = selectedSubtitleIndex { body["SubtitleStreamIndex"] = index }
        }
        lastReportTime = Date()
        // CurlFetcher's serial API queue preserves Start → Progress → Stopped
        // order, including when Back immediately opens the home shelves.
        let ticks = positionTicks
        let itemId = item.id
        HTTPClient.post(url: server + "/Sessions/" + endpoint,
                        headers: ["Authorization": JellyfinServer.authHeader()], body: body) { _, error in
            DebugLog.shared.log("Sync", "\(endpoint) \(error == nil ? "OK" : "FAILED") item=\(itemId) ticks=\(ticks) paused=\(paused) failed=\(failed)")
        }
    }
}
