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

#if IOS6_TARGET
    private var player: MPMoviePlayerController?
#else
    private var avPlayer: AVPlayer?
    private var playerVC: AVPlayerViewController?
#endif

    private var isAudio: Bool { item.type == "Audio" }

    init(item: MediaItem) {
        self.item = item
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
#endif
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

    private func buildStreamURL() -> URL? {
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
            let params = [
                "api_key=\(token)",
                "MediaSourceId=\(item.id)",
                "DeviceId=jellyold-device-01",
                "MaxStreamingBitrate=8000000",
                "VideoCodec=h264",
                "AudioCodec=aac"
            ].joined(separator: "&")
            urlString = "\(serverURL)/Videos/\(item.id)/master.m3u8?\(params)"
        }
        return URL(string: urlString)
    }

    // MARK: - iOS 6/7 player

#if IOS6_TARGET
    private func setupPlayer() {
        guard let url = buildStreamURL(),
              let player = MPMoviePlayerController(contentURL: url) else { return }
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
        if player.loadState.contains(.playable) && !player.loadState.contains(.stalled) {
            bufferSpinner.stopAnimating()
        } else {
            bufferSpinner.startAnimating()
        }
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
        guard let url = buildStreamURL() else { return }
        let avPlayer = AVPlayer(url: url)
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
    }

    // AVPlayerViewController provides its own loading indicator
    private func setupBufferSpinner() {
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
        UserDefaults.standard.removeObject(forKey: resumeKey)
        navigationController?.popViewController(animated: true)
    }
}
