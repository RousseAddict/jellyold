import UIKit
import MediaPlayer
import AVFoundation

class VideoPlayerVC: UIViewController {
    private let item: MediaItem
    private var player: MPMoviePlayerController?
    private var bufferSpinner: UIActivityIndicatorView!

    private var isAudio: Bool { item.type == "Audio" }

    init(item: MediaItem) {
        self.item = item
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // iOS 7+: tell the system to keep status bar hidden for video
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
            player?.view.frame = CGRect(x: 0, y: navBottom, width: view.bounds.width,
                                        height: view.bounds.height - navBottom)
        }
        player?.play()
        restorePosition()
    }

    // Fires on every rotation — keeps video truly fullscreen in any orientation
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !isAudio else { return }
        // Re-assert hidden so status bar doesn't flash back on rotation
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
        savePosition()
        NotificationCenter.default.removeObserver(self)
        player?.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
    }

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

    private func setupPlayer() {
        guard let serverURL = JellyfinServer.serverURL,
              let token = JellyfinServer.accessToken,
              let userId = JellyfinServer.userId else { return }

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

        guard let url = URL(string: urlString),
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

    private var resumeKey: String { "resume_\(item.id)" }

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

    @objc private func playbackFinished(_ notification: Notification) {
        UserDefaults.standard.removeObject(forKey: resumeKey)
        navigationController?.popViewController(animated: true)
    }
}
