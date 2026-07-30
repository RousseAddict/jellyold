import UIKit

// Full-screen audio player UI. Owns AudioPlayer's three single-slot callbacks
// while it's on screen; MiniPlayerBar and QueueVC poll instead so they can't
// steal them.
class NowPlayingVC: UIViewController {

    private let bgColor = UIColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1)
    private let accentColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)

    private let scrollView = UIScrollView()
    private let artworkView = AsyncImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let slider = UISlider()
    private let currentTimeLabel = UILabel()
    private let remainingLabel = UILabel()
    private let prevBtn = UIButton(type: .custom)
    private let playPauseBtn = UIButton(type: .custom)
    private let nextBtn = UIButton(type: .custom)

    private var duration: Double = 0
    private var currentTime: Double = 0
    private var lastDisplayedSecond = -1
    private var lastBuiltWidth: CGFloat = 0
    private var loadedArtworkId: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Now Playing"
        view.backgroundColor = bgColor
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Queue", style: .plain, target: self, action: #selector(queueTapped)
        )
        setupSubviews()
    }

    // Bound here rather than in viewDidLoad, and rebound on every appearance:
    // the closures are released in viewWillDisappear, which also fires when
    // pushing QueueVC on top — binding once would leave a permanently dead
    // screen after popping back.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        bindPlayer()
        refreshTrack()
        refreshTransport()
        currentTime = AudioPlayer.shared.currentTime
        duration = AudioPlayer.shared.duration
        updateProgressUI()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        AudioPlayer.shared.onProgress = nil
        AudioPlayer.shared.onStateChange = nil
        AudioPlayer.shared.onFinish = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = view.bounds.width
        guard w > 0, w != lastBuiltWidth else { return }
        lastBuiltWidth = w
        layoutContent(width: w)
    }

    // MARK: - UI

    private func setupSubviews() {
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.backgroundColor = bgColor
        view.addSubview(scrollView)

        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = 8
        artworkView.backgroundColor = UIColor(white: 0.15, alpha: 1)
        scrollView.addSubview(artworkView)

        titleLabel.backgroundColor = .clear
        titleLabel.textColor = .white
        titleLabel.font = UIFont.boldSystemFont(ofSize: 17)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        scrollView.addSubview(titleLabel)

        subtitleLabel.backgroundColor = .clear
        subtitleLabel.textColor = UIColor(white: 0.55, alpha: 1)
        subtitleLabel.font = UIFont.systemFont(ofSize: 13)
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 2
        scrollView.addSubview(subtitleLabel)

        slider.minimumTrackTintColor = accentColor
        slider.addTarget(self, action: #selector(sliderMoved), for: .valueChanged)
        scrollView.addSubview(slider)

        for label in [currentTimeLabel, remainingLabel] {
            label.backgroundColor = .clear
            label.textColor = UIColor(white: 0.5, alpha: 1)
            label.font = UIFont.systemFont(ofSize: 11)
            scrollView.addSubview(label)
        }
        currentTimeLabel.text = "0:00"
        remainingLabel.textAlignment = .right
        remainingLabel.text = "-0:00"

        // Loose PNGs, not an asset catalog — Assets.car isn't reliably read by the
        // iOS 6 runtime. They're already white, so no tinting is involved (and
        // UIImage.withRenderingMode is iOS 7+ anyway); UIButton's default
        // adjustsImageWhenDisabled dims prev/next at the ends of the queue.
        configureTransport(prevBtn, image: "skip-back", action: #selector(prevTapped))
        configureTransport(nextBtn, image: "skip-forward", action: #selector(nextTapped))
        configureTransport(playPauseBtn, image: "pause", action: #selector(playPauseTapped))
        playPauseBtn.setImage(UIImage(named: "play"), for: .selected) // shown while paused
        playPauseBtn.layer.cornerRadius = 35
        playPauseBtn.layer.borderWidth = 2
        playPauseBtn.layer.borderColor = UIColor(white: 0.4, alpha: 1).cgColor
    }

    private func configureTransport(_ btn: UIButton, image: String, action: Selector) {
        btn.setImage(UIImage(named: image), for: .normal)
        btn.addTarget(self, action: action, for: .touchUpInside)
        scrollView.addSubview(btn)
    }

    private func layoutContent(width w: CGFloat) {
        var y: CGFloat = 20

        let artSize = min(w - 40, 240)
        artworkView.frame = CGRect(x: (w - artSize) / 2, y: y, width: artSize, height: artSize)
        y += artSize + 18

        titleLabel.frame = CGRect(x: 20, y: y, width: w - 40, height: 44)
        y += 46
        subtitleLabel.frame = CGRect(x: 20, y: y, width: w - 40, height: 34)
        y += 40

        slider.frame = CGRect(x: 20, y: y, width: w - 40, height: 30)
        y += 30

        currentTimeLabel.frame = CGRect(x: 20, y: y, width: 70, height: 16)
        remainingLabel.frame = CGRect(x: w - 90, y: y, width: 70, height: 16)
        y += 28

        let ctrlH: CGFloat = 70
        prevBtn.frame = CGRect(x: 20, y: y, width: 70, height: ctrlH)
        playPauseBtn.frame = CGRect(x: (w - 70) / 2, y: y, width: 70, height: ctrlH)
        nextBtn.frame = CGRect(x: w - 90, y: y, width: 70, height: ctrlH)
        y += ctrlH + 20

        scrollView.contentSize = CGSize(width: w, height: y)
    }

    // MARK: - Binding

    private func bindPlayer() {
        AudioPlayer.shared.onProgress = { [weak self] cur, dur in
            guard let self = self else { return }
            self.currentTime = cur
            self.duration = dur
            self.updateProgressUI()
        }
        AudioPlayer.shared.onStateChange = { [weak self] in
            guard let self = self else { return }
            self.refreshTrack()
            self.refreshTransport()
        }
        AudioPlayer.shared.onFinish = { [weak self] in
            // Purely a notification — AudioPlayer advances the queue itself.
            self?.lastDisplayedSecond = -1
        }
    }

    private func refreshTrack() {
        guard let item = AudioQueue.shared.current else { return }
        if titleLabel.text != item.name { titleLabel.text = item.name }
        let sub = [item.artistText, item.album].compactMap { $0 }.joined(separator: " \u{2022} ")
        if subtitleLabel.text != sub { subtitleLabel.text = sub }
        if loadedArtworkId != item.id, let serverURL = JellyfinServer.serverURL {
            loadedArtworkId = item.id
            artworkView.load(url: "\(serverURL)/Items/\(item.id)/Images/Primary?width=400")
        }
    }

    private func refreshTransport() {
        playPauseBtn.isSelected = !AudioPlayer.shared.isPlaying
        prevBtn.isEnabled = AudioQueue.shared.hasPrevious
        nextBtn.isEnabled = AudioQueue.shared.hasNext
    }

    private func updateProgressUI() {
        // duration comes from runTimeTicks when the stream itself doesn't report
        // one, so a transcoded track still gets a working scrubber and labels.
        let hasDuration = duration > 0
        if slider.isEnabled != hasDuration { slider.isEnabled = hasDuration }
        if hasDuration && !slider.isTracking {
            let v = Float(min(1, max(0, currentTime / duration)))
            if slider.value != v { slider.value = v }
        }
        let s = Int(currentTime)
        guard s != lastDisplayedSecond else { return }
        lastDisplayedSecond = s
        currentTimeLabel.text = fmt(currentTime)
        remainingLabel.text = hasDuration ? "-\(fmt(max(0, duration - currentTime)))" : "--:--"
    }

    private func fmt(_ s: Double) -> String {
        let t = Int(s)
        if t >= 3600 { return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) }
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: - Actions

    @objc private func playPauseTapped() { AudioPlayer.shared.togglePlayPause() }
    @objc private func prevTapped()      { AudioQueue.shared.previous() }
    @objc private func nextTapped()      { AudioQueue.shared.next() }

    @objc private func sliderMoved() {
        guard duration > 0 else { return }
        AudioPlayer.shared.seek(to: Double(slider.value) * duration)
    }

    @objc private func queueTapped() {
        navigationController?.pushViewController(QueueVC(), animated: true)
    }
}
