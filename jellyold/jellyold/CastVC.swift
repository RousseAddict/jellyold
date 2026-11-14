import UIKit

// Remote-playback screen for an active Chromecast cast. Owns CastController's
// single-slot callbacks while on screen (bound in viewWillAppear, released in
// viewWillDisappear — same lifecycle NowPlayingVC uses), and pops itself when
// the cast ends. The cast itself lives in CastController, so backing out of
// this screen does not stop it, and neither does the phone sleeping: the
// controller reconnects and the screen shows "Reconnecting" meanwhile.
class CastVC: UIViewController {

    private let bgColor = UIColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1)
    private let accentColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)

    private let scrollView = UIScrollView()
    private let artworkView = AsyncImageView()
    private let titleLabel = UILabel()
    private let deviceLabel = UILabel()
    private let stateLabel = UILabel()
    private let slider = UISlider()
    private let currentTimeLabel = UILabel()
    private let remainingLabel = UILabel()
    private let backBtn = UIButton(type: .custom)
    private let playPauseBtn = UIButton(type: .custom)
    private let forwardBtn = UIButton(type: .custom)
    private let stopBtn = UIButton(type: .custom)
    // The TV's own volume (not the phone's).
    private let volumeIcon = UIImageView(image: UIImage(named: "volume"))
    private let volumeSlider = UISlider()
    private var lastVolumeSent: CFAbsoluteTime = 0
    // Replaces the play/pause glyph while the receiver is buffering or catching up on a seek.
    private let busySpinner = UIActivityIndicatorView(style: .white)

    private var duration: Double = 0
    private var currentTime: Double = 0
    private var isPlaying = false
    private var showingBusy = false
    private var lastBuiltWidth: CGFloat = 0

    private static let skipBack: Double = -10
    private static let skipForward: Double = 30

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Casting"
        view.backgroundColor = bgColor
        setupSubviews()
        refreshTrack()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The cast ended while another screen covered this one.
        // Popped on the next turn: popping from inside an appearance transition upsets
        // UINavigationController on iOS 6/7.
        guard CastController.shared.isCasting else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let nav = self.navigationController,
                      nav.topViewController === self else { return }
                nav.popViewController(animated: true)
            }
            return
        }
        bindController()
        refreshTrack()
        currentTime = CastController.shared.currentTime
        duration = CastController.shared.duration
        isPlaying = CastController.shared.isPlaying
        stateLabel.text = CastController.shared.state
        refreshTransport()
        updateProgressUI()
        refreshVolume()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        CastController.shared.onState = nil
        CastController.shared.onProgress = nil
        CastController.shared.onEnded = nil
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

        deviceLabel.backgroundColor = .clear
        deviceLabel.textColor = accentColor
        deviceLabel.font = UIFont.systemFont(ofSize: 14)
        deviceLabel.textAlignment = .center
        scrollView.addSubview(deviceLabel)

        stateLabel.backgroundColor = .clear
        stateLabel.textColor = UIColor(white: 0.5, alpha: 1)
        stateLabel.font = UIFont.systemFont(ofSize: 12)
        stateLabel.textAlignment = .center
        scrollView.addSubview(stateLabel)

        // Dragging only previews the target time; one seek goes out on release. Seeking a
        // cast restarts the server transcode, so a seek per valueChanged would queue dozens.
        slider.minimumTrackTintColor = accentColor
        slider.addTarget(self, action: #selector(sliderMoved), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderReleased), for: [.touchUpInside, .touchUpOutside])
        slider.addTarget(self, action: #selector(sliderCancelled), for: .touchCancel)
        slider.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(sliderTapped(_:))))
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

        // Reuses the existing white transport PNGs; here they seek rather than
        // change track, so they're always enabled.
        configureTransport(backBtn, image: "skip-back", action: #selector(backTapped))
        configureTransport(forwardBtn, image: "skip-forward", action: #selector(forwardTapped))
        configureTransport(playPauseBtn, image: "pause", action: #selector(playPauseTapped))
        playPauseBtn.setImage(UIImage(named: "play"), for: .selected) // shown while paused
        playPauseBtn.layer.cornerRadius = 35
        playPauseBtn.layer.borderWidth = 2
        playPauseBtn.layer.borderColor = UIColor(white: 0.4, alpha: 1).cgColor
        busySpinner.hidesWhenStopped = true
        busySpinner.isUserInteractionEnabled = false
        playPauseBtn.addSubview(busySpinner)

        volumeIcon.contentMode = .center
        volumeIcon.alpha = 0.7   // the PNG is pure white, like the other glyphs here
        scrollView.addSubview(volumeIcon)
        volumeSlider.minimumValue = 0
        volumeSlider.maximumValue = 1
        volumeSlider.minimumTrackTintColor = UIColor(white: 0.85, alpha: 1)
        volumeSlider.addTarget(self, action: #selector(volumeChanged), for: .valueChanged)
        volumeSlider.addTarget(self, action: #selector(volumeReleased), for: [.touchUpInside, .touchUpOutside])
        scrollView.addSubview(volumeSlider)

        stopBtn.setTitle("Stop Casting", for: .normal)
        stopBtn.setTitleColor(.white, for: .normal)
        stopBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        stopBtn.backgroundColor = UIColor(white: 0.18, alpha: 1)
        stopBtn.layer.cornerRadius = 8
        stopBtn.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        scrollView.addSubview(stopBtn)
    }

    private func configureTransport(_ btn: UIButton, image: String, action: Selector) {
        btn.setImage(UIImage(named: image), for: .normal)
        btn.addTarget(self, action: action, for: .touchUpInside)
        scrollView.addSubview(btn)
    }

    private func layoutContent(width w: CGFloat) {
        var y: CGFloat = 20

        let artSize = min(w - 120, 180)
        artworkView.frame = CGRect(x: (w - artSize) / 2, y: y, width: artSize, height: artSize * 1.5)
        y += artSize * 1.5 + 16

        titleLabel.frame = CGRect(x: 20, y: y, width: w - 40, height: 44)
        y += 46
        deviceLabel.frame = CGRect(x: 20, y: y, width: w - 40, height: 20)
        y += 22
        stateLabel.frame = CGRect(x: 20, y: y, width: w - 40, height: 16)
        y += 26

        let isPhoto = CastController.shared.kind == .photo
        // A photo has no timeline, transport or sound — hide rather than show dead controls.
        for v in [slider, currentTimeLabel, remainingLabel, volumeIcon, volumeSlider] { v.isHidden = isPhoto }
        for b in [backBtn, playPauseBtn, forwardBtn] { b.isHidden = isPhoto }

        if !isPhoto {
            slider.frame = CGRect(x: 20, y: y, width: w - 40, height: 30)
            y += 30
            currentTimeLabel.frame = CGRect(x: 20, y: y, width: 70, height: 16)
            remainingLabel.frame = CGRect(x: w - 90, y: y, width: 70, height: 16)
            y += 28

            let ctrlH: CGFloat = 70
            backBtn.frame = CGRect(x: 20, y: y, width: 70, height: ctrlH)
            playPauseBtn.frame = CGRect(x: (w - 70) / 2, y: y, width: 70, height: ctrlH)
            busySpinner.center = CGPoint(x: 35, y: ctrlH / 2)
            forwardBtn.frame = CGRect(x: w - 90, y: y, width: 70, height: ctrlH)
            y += ctrlH + 16

            volumeIcon.frame = CGRect(x: 20, y: y, width: 24, height: 30)
            volumeSlider.frame = CGRect(x: 56, y: y, width: w - 76, height: 30)
            y += 30 + 24
        }

        stopBtn.frame = CGRect(x: 20, y: y, width: w - 40, height: 44)
        y += 44 + 20

        scrollView.contentSize = CGSize(width: w, height: y)
    }

    // MARK: - Binding

    private func bindController() {
        CastController.shared.onState = { [weak self] text in
            self?.stateLabel.text = text
        }
        CastController.shared.onProgress = { [weak self] cur, dur, playing in
            guard let self = self else { return }
            self.currentTime = cur
            self.duration = dur
            self.isPlaying = playing
            self.refreshTransport()
            self.updateProgressUI()
            self.refreshVolume()
        }
        // The controller has already torn the cast down; this screen only has to leave.
        CastController.shared.onEnded = { [weak self] end in
            guard let self = self else { return }
            switch end {
            case .failed(let reason):
                self.showEnd("The Chromecast couldn't play this (\(reason)). Try a lower quality.")
            case .disconnected(let message):
                self.showEnd(message)
            case .finished, .stoppedRemotely:
                self.navigationController?.popViewController(animated: true)
            }
        }
    }

    // Leaves the screen once the alert is acknowledged (iOS 8), or straight away under
    // UIAlertView, which lives in its own window and survives the pop.
    private func showEnd(_ message: String) {
#if IOS6_TARGET
        UIAlertView(title: "Casting stopped", message: message,
                    delegate: nil, cancelButtonTitle: "OK").show()
        navigationController?.popViewController(animated: true)
#else
        let alert = UIAlertController(title: "Casting stopped", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        })
        present(alert, animated: true)
#endif
    }

    private func refreshTrack() {
        deviceLabel.text = "Casting to \(CastController.shared.deviceName)"
        guard let item = CastController.shared.item else { return }
        titleLabel.text = item.name
        if let serverURL = JellyfinServer.serverURL {
            artworkView.load(url: "\(serverURL)/Items/\(item.id)/Images/Primary?width=400")
        }
    }

    private func refreshTransport() {
        let cast = CastController.shared
        playPauseBtn.isSelected = !isPlaying
        // Nothing to command while the connection is being re-established.
        let live = !cast.isReconnecting
        for b in [backBtn, playPauseBtn, forwardBtn] where b.isEnabled != live { b.isEnabled = live }
        let busy = cast.isBuffering || cast.isSeeking || cast.isReconnecting
        guard busy != showingBusy else { return }
        showingBusy = busy
        if busy {
            playPauseBtn.setImage(nil, for: .normal)
            playPauseBtn.setImage(nil, for: .selected)
            busySpinner.startAnimating()
        } else {
            busySpinner.stopAnimating()
            playPauseBtn.setImage(UIImage(named: "pause"), for: .normal)
            playPauseBtn.setImage(UIImage(named: "play"), for: .selected)
        }
    }

    private func updateProgressUI() {
        // duration is the item's runtime; only an item without one waits for the receiver.
        let canScrub = duration > 0 && !CastController.shared.isReconnecting
        if slider.isEnabled != canScrub { slider.isEnabled = canScrub }
        let hasDuration = duration > 0
        // While dragging, the thumb and labels belong to the finger (see sliderMoved).
        guard !slider.isTracking else { return }
        if hasDuration {
            let v = Float(min(1, max(0, currentTime / duration)))
            if slider.value != v { slider.value = v }
        }
        showTimes(at: currentTime, scrubbing: false)
    }

    private func showTimes(at t: Double, scrubbing: Bool) {
        currentTimeLabel.text = fmt(t)
        remainingLabel.text = duration > 0 ? "-\(fmt(max(0, duration - t)))" : "--:--"
        let color = scrubbing ? UIColor.white : UIColor(white: 0.5, alpha: 1)
        currentTimeLabel.textColor = color
        remainingLabel.textColor = color
    }

    private func fmt(_ s: Double) -> String {
        let t = Int(s)
        if t >= 3600 { return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) }
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: - Actions

    @objc private func playPauseTapped() { CastController.shared.togglePlayPause() }
    @objc private func backTapped()      { CastController.shared.seek(by: CastVC.skipBack) }
    @objc private func forwardTapped()   { CastController.shared.seek(by: CastVC.skipForward) }

    @objc private func sliderMoved() {
        guard duration > 0, slider.isTracking else { return }
        showTimes(at: Double(slider.value) * duration, scrubbing: true)
    }

    @objc private func sliderReleased() {
        guard duration > 0 else { return }
        CastController.shared.seek(to: Double(slider.value) * duration)
    }

    @objc private func sliderCancelled() {
        updateProgressUI()
    }

    // UISlider only moves by dragging its thumb; a tap on the track jumps there directly.
    @objc private func sliderTapped(_ g: UITapGestureRecognizer) {
        guard duration > 0 else { return }
        let p = g.location(in: slider)
        let track = slider.trackRect(forBounds: slider.bounds)
        let thumb = slider.thumbRect(forBounds: slider.bounds, trackRect: track, value: slider.value)
        // A tap on the thumb itself isn't a request to move.
        guard !thumb.insetBy(dx: -6, dy: -6).contains(p), track.width > 0 else { return }
        let frac = Double(min(1, max(0, (p.x - track.minX) / track.width)))
        slider.value = Float(frac)
        CastController.shared.seek(to: frac * duration)
    }

    // Unknown (-1) until the TV reports it, or when its output is fixed — then disabled.
    private func refreshVolume() {
        let cast = CastController.shared
        let usable = cast.volume >= 0 && !cast.isReconnecting
        if volumeSlider.isEnabled != usable { volumeSlider.isEnabled = usable }
        volumeIcon.alpha = usable ? 0.7 : 0.3
        // While dragging, the thumb belongs to the finger.
        guard !volumeSlider.isTracking, cast.volume >= 0 else { return }
        let v = Float(cast.volume)
        if abs(volumeSlider.value - v) > 0.005 { volumeSlider.value = v }
    }

    // Follows the finger at up to ~5 changes a second (each is one small message to the
    // TV), and always sends where it was let go.
    @objc private func volumeChanged() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastVolumeSent >= 0.2 else { return }
        lastVolumeSent = now
        CastController.shared.setVolume(Double(volumeSlider.value))
    }

    @objc private func volumeReleased() {
        lastVolumeSent = CFAbsoluteTimeGetCurrent()
        CastController.shared.setVolume(Double(volumeSlider.value))
    }

    @objc private func stopTapped() {
        CastController.shared.stop()
        navigationController?.popViewController(animated: true)
    }
}
