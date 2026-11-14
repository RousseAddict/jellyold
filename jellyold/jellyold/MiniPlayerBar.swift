import UIKit

// Persistent bar pinned to the bottom of the navigation controller's view, so
// audio stays controllable while browsing.
//
// It lives in the nav controller's view rather than the window: a direct
// UIWindow subview does not rotate on iOS 6/7, and this app allows landscape.
// As a nav-view subview (flexibleWidth | flexibleTopMargin) it survives
// push/pop, floats above pushed content, rotates for free, and stays clear of
// the UIActionSheets that are shown with `show(in: view)`.
//
// Poll-only: it registers none of AudioPlayer's or CastController's callbacks,
// which are single-slot and belong to NowPlayingVC / CastVC.
//
// While casting it is the TV's remote instead: the item on the TV with
// "Playing on <TV>" (or "Reconnecting…" after the phone slept), play/pause
// acting on the TV, close stopping the cast, and a tap opening CastVC. That is
// also the way back to a cast picked up again after iOS killed the app.
final class MiniPlayerBar: UIView {

    static let barHeight: CGFloat = 60

    private let titleLabel = UILabel()
    // Cast only: "Playing on Living Room TV".
    private let statusLabel = UILabel()
    // Whether the bar is laid out for a cast (title + status) or local audio (title).
    private var showingCast = false
    private let playPauseBtn = UIButton(type: .custom)
    private let closeBtn = UIButton(type: .custom)
    private let openBtn = UIButton(type: .custom) // transparent tap-to-expand area
    private var pollTimer: Timer?
    private weak var nav: UINavigationController?

    init(nav: UINavigationController) {
        self.nav = nav
        let b = nav.view.bounds
        super.init(frame: CGRect(x: 0, y: b.height - MiniPlayerBar.barHeight,
                                 width: b.width, height: MiniPlayerBar.barHeight))
        autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        isHidden = true
        setupUI()
        startPolling()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.18, alpha: 0.97)

        let border = UIView(frame: CGRect(x: 0, y: 0, width: bounds.width, height: 1))
        border.autoresizingMask = .flexibleWidth
        border.backgroundColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)
        addSubview(border)

        titleLabel.frame = CGRect(x: 14, y: 8, width: bounds.width - 104, height: 44)
        titleLabel.autoresizingMask = .flexibleWidth
        titleLabel.backgroundColor = .clear
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 13)
        titleLabel.numberOfLines = 2
        titleLabel.isUserInteractionEnabled = false
        addSubview(titleLabel)

        statusLabel.frame = CGRect(x: 14, y: 31, width: bounds.width - 104, height: 18)
        statusLabel.autoresizingMask = .flexibleWidth
        statusLabel.backgroundColor = .clear
        statusLabel.textColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)
        statusLabel.font = UIFont.systemFont(ofSize: 12)
        statusLabel.isUserInteractionEnabled = false
        statusLabel.isHidden = true
        addSubview(statusLabel)

        // Transparent button over the title area — tap to open NowPlayingVC.
        openBtn.frame = CGRect(x: 0, y: 0, width: bounds.width - 88, height: bounds.height)
        openBtn.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        openBtn.backgroundColor = .clear
        openBtn.addTarget(self, action: #selector(openTapped), for: .touchUpInside)
        addSubview(openBtn)

        playPauseBtn.frame = CGRect(x: bounds.width - 80, y: 10, width: 36, height: 40)
        playPauseBtn.autoresizingMask = .flexibleLeftMargin
        // Smaller renders of the same white PNGs NowPlayingVC uses.
        playPauseBtn.setImage(UIImage(named: "pause-small"), for: .normal)   // playing
        playPauseBtn.setImage(UIImage(named: "play-small"), for: .selected)  // paused
        playPauseBtn.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        addSubview(playPauseBtn)

        closeBtn.frame = CGRect(x: bounds.width - 40, y: 10, width: 36, height: 40)
        closeBtn.autoresizingMask = .flexibleLeftMargin
        closeBtn.setImage(UIImage(named: "x"), for: .normal)
        closeBtn.alpha = 0.7   // the PNG is pure white; this is the old glyph's grey
        closeBtn.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        addSubview(closeBtn)
    }

    // .common mode so it keeps firing while a scroll view is tracking.
    private func startPolling() {
        let t = Timer(timeInterval: 0.5, target: self, selector: #selector(poll),
                      userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    @objc private func poll() {
        let cast = CastController.shared
        let top = nav?.topViewController
        if cast.isCasting, let item = cast.item {
            let shouldHide = (top is CastVC) || (top is VideoPlayerVC)
            if isHidden != shouldHide { isHidden = shouldHide }
            guard !shouldHide else { return }
            claimTop()
            setCastLayout(true)
            if titleLabel.text != item.name { titleLabel.text = item.name }
            let status = cast.statusText
            if statusLabel.text != status { statusLabel.text = status }
            // A photo has nothing to play or pause; nothing can be commanded while reconnecting.
            let hidePlay = cast.kind == .photo
            if playPauseBtn.isHidden != hidePlay { playPauseBtn.isHidden = hidePlay }
            let live = !cast.isReconnecting
            if playPauseBtn.isEnabled != live { playPauseBtn.isEnabled = live }
            let wantSelected = !cast.isPlaying
            if playPauseBtn.isSelected != wantSelected { playPauseBtn.isSelected = wantSelected }
            return
        }

        let item = AudioQueue.shared.current
        let shouldHide = (item == nil) || (top is NowPlayingVC) || (top is VideoPlayerVC)
        if isHidden != shouldHide { isHidden = shouldHide }
        guard let item = item, !shouldHide else { return }
        claimTop()
        setCastLayout(false)
        if titleLabel.text != item.name { titleLabel.text = item.name }
        if playPauseBtn.isHidden { playPauseBtn.isHidden = false }
        if !playPauseBtn.isEnabled { playPauseBtn.isEnabled = true }
        let wantSelected = !AudioPlayer.shared.isPlaying
        if playPauseBtn.isSelected != wantSelected { playPauseBtn.isSelected = wantSelected }
    }

    // A pushed view controller's view is added above us, so claim the top
    // slot back. Compared first — bringSubviewToFront forces a layout pass.
    private func claimTop() {
        if let navView = nav?.view, navView.subviews.last !== self {
            navView.bringSubviewToFront(self)
        }
    }

    // Cast: one-line title over the status line. Audio: a two-line title. Only
    // touched when the mode flips — the poll runs twice a second.
    private func setCastLayout(_ cast: Bool) {
        guard cast != showingCast else { return }
        showingCast = cast
        statusLabel.isHidden = !cast
        titleLabel.numberOfLines = cast ? 1 : 2
        var f = titleLabel.frame
        f.origin.y = cast ? 11 : 8
        f.size.height = cast ? 20 : 44
        titleLabel.frame = f
    }

    @objc private func playPauseTapped() {
        if CastController.shared.isCasting {
            CastController.shared.togglePlayPause()
        } else {
            AudioPlayer.shared.togglePlayPause()
        }
    }

    // While casting, close stops the cast (the TV goes back to its own screen).
    @objc private func closeTapped() {
        if CastController.shared.isCasting {
            CastController.shared.stop()
        } else {
            AudioPlayer.shared.stopAll()
        }
        isHidden = true
    }

    @objc private func openTapped() {
        guard let nav = nav else { return }
        if CastController.shared.isCasting {
            guard !(nav.topViewController is CastVC) else { return }
            nav.pushViewController(CastVC(), animated: true)
            return
        }
        guard !(nav.topViewController is NowPlayingVC) else { return }
        nav.pushViewController(NowPlayingVC(), animated: true)
    }
}
