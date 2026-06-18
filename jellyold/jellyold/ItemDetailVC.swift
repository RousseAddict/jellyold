import UIKit

class ItemDetailVC: UIViewController {

    private let item: MediaItem
    private let bgColor = UIColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1.0)
    private let accentColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1.0)
    private var scrollView: UIScrollView!
    private var lastBuiltWidth: CGFloat = 0

    private var mediaStreams: [MediaStream] = []
    private var selectedAudioIndex: Int?
    private var selectedSubtitleIndex: Int?
    private var forceTranscode = false

#if IOS6_TARGET
    private var pendingAudioOptions: [Int] = []
    private var pendingSubtitleOptions: [Int?] = []
    private var activeActionSheet: UIActionSheet?
#endif

    init(item: MediaItem) {
        self.item = item
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = item.name
        view.backgroundColor = bgColor
        scrollView = UIScrollView(frame: view.bounds)
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.backgroundColor = bgColor
        view.addSubview(scrollView)

        if item.type != "Audio" {
            JellyfinAPI.getMediaStreams(itemId: item.id) { [weak self] streams in
                guard let self = self else { return }
                self.mediaStreams = streams
                let audioStreams = streams.filter { $0.isAudio }
                if let def = audioStreams.first(where: { $0.isDefault }) ?? audioStreams.first {
                    self.selectedAudioIndex = def.index
                }
                DispatchQueue.main.async { self.forceRebuild() }
            }
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let w = view.bounds.width
        guard w > 0, w != lastBuiltWidth else { return }
        lastBuiltWidth = w
        scrollView.subviews.forEach { $0.removeFromSuperview() }
        buildContent(width: w)
    }

    private func forceRebuild() {
        lastBuiltWidth = 0
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    private func buildContent(width w: CGFloat) {
        let posterW: CGFloat = min(w - 80, 220)
        let posterH: CGFloat = posterW * 1.5
        let posterX = (w - posterW) / 2
        var y: CGFloat = 24

        let poster = AsyncImageView(frame: CGRect(x: posterX, y: y, width: posterW, height: posterH))
        poster.contentMode = .scaleAspectFill
        poster.clipsToBounds = true
        poster.layer.cornerRadius = 8
        poster.backgroundColor = UIColor(white: 0.15, alpha: 1.0)
        if let serverURL = JellyfinServer.serverURL {
            poster.load(url: "\(serverURL)/Items/\(item.id)/Images/Primary?width=400")
        }
        scrollView.addSubview(poster)
        y += posterH + 20

        let titleLabel = UILabel(frame: CGRect(x: 16, y: y, width: w - 32, height: 0))
        titleLabel.text = item.name
        titleLabel.textColor = .white
        titleLabel.backgroundColor = .clear
        titleLabel.font = UIFont.boldSystemFont(ofSize: 22)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.sizeToFit()
        titleLabel.frame = CGRect(x: 16, y: y, width: w - 32, height: titleLabel.frame.height)
        scrollView.addSubview(titleLabel)
        y += titleLabel.frame.height + 6

        if let year = item.year {
            let yearLabel = UILabel(frame: CGRect(x: 16, y: y, width: w - 32, height: 20))
            yearLabel.text = "\(year)  ·  \(item.type)"
            yearLabel.textColor = UIColor.lightGray
            yearLabel.backgroundColor = .clear
            yearLabel.font = UIFont.systemFont(ofSize: 14)
            yearLabel.textAlignment = .center
            scrollView.addSubview(yearLabel)
            y += 28
        }

        if let overview = item.overview, !overview.isEmpty {
            let overviewLabel = UILabel(frame: CGRect(x: 16, y: y, width: w - 32, height: 0))
            overviewLabel.text = overview
            overviewLabel.textColor = UIColor(white: 0.8, alpha: 1.0)
            overviewLabel.backgroundColor = .clear
            overviewLabel.font = UIFont.systemFont(ofSize: 14)
            overviewLabel.numberOfLines = 0
            overviewLabel.sizeToFit()
            overviewLabel.frame = CGRect(x: 16, y: y, width: w - 32, height: overviewLabel.frame.height)
            scrollView.addSubview(overviewLabel)
            y += overviewLabel.frame.height + 24
        } else {
            y += 8
        }

        let playBtn = UIButton(type: .custom)
        playBtn.frame = CGRect(x: 16, y: y, width: w - 32, height: 50)
        playBtn.setTitle("Play", for: .normal)
        playBtn.setTitleColor(.white, for: .normal)
        playBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 18)
        playBtn.backgroundColor = accentColor
        playBtn.layer.cornerRadius = 10
        playBtn.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        scrollView.addSubview(playBtn)
        y += 50 + 12

        // Track pickers + transcode toggle (video only, when tracks are available)
        if item.type != "Audio" {
            let audioStreams = mediaStreams.filter { $0.isAudio }
            let subtitleStreams = mediaStreams.filter { $0.isSubtitle }
            let hasTrackOptions = audioStreams.count > 1 || !subtitleStreams.isEmpty

            if audioStreams.count > 1 {
                let label = audioStreams.first(where: { $0.index == selectedAudioIndex })?.displayTitle ?? "Default"
                let btn = makeTrackButton("Audio: \(label)  ▾", y: y, width: w)
                btn.addTarget(self, action: #selector(audioTapped), for: .touchUpInside)
                scrollView.addSubview(btn)
                y += 40 + 8
            }

            if !subtitleStreams.isEmpty {
                let label = selectedSubtitleIndex.flatMap { idx in
                    subtitleStreams.first(where: { $0.index == idx })?.displayTitle
                } ?? "Off"
                let btn = makeTrackButton("Subtitles: \(label)  ▾", y: y, width: w)
                btn.addTarget(self, action: #selector(subtitleTapped), for: .touchUpInside)
                scrollView.addSubview(btn)
                y += 40 + 8
            }

            if hasTrackOptions {
                let transcodeTitle = forceTranscode ? "Transcode: On  ✓" : "Transcode: Off"
                let transcodeBtn = makeTrackButton(transcodeTitle, y: y, width: w)
                transcodeBtn.addTarget(self, action: #selector(transcodeTapped), for: .touchUpInside)
                if forceTranscode {
                    transcodeBtn.layer.borderColor = accentColor.cgColor
                    transcodeBtn.layer.borderWidth = 1.5
                }
                scrollView.addSubview(transcodeBtn)
                y += 40 + 6

                let hint = UILabel(frame: CGRect(x: 16, y: y, width: w - 32, height: 0))
                hint.text = "Transcode must be enabled to apply audio track or subtitle changes."
                hint.textColor = UIColor(white: 0.45, alpha: 1.0)
                hint.backgroundColor = .clear
                hint.font = UIFont.systemFont(ofSize: 12)
                hint.textAlignment = .center
                hint.numberOfLines = 0
                hint.sizeToFit()
                hint.frame = CGRect(x: 16, y: y, width: w - 32, height: hint.frame.height)
                scrollView.addSubview(hint)
                y += hint.frame.height + 8
            }
        }

        y += 30
        scrollView.contentSize = CGSize(width: w, height: y)
    }

    private func makeTrackButton(_ title: String, y: CGFloat, width w: CGFloat) -> UIButton {
        let btn = UIButton(type: .custom)
        btn.frame = CGRect(x: 16, y: y, width: w - 32, height: 40)
        btn.setTitle(title, for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        btn.backgroundColor = UIColor(white: 1.0, alpha: 0.08)
        btn.layer.cornerRadius = 8
        btn.layer.borderColor = UIColor(white: 1.0, alpha: 0.15).cgColor
        btn.layer.borderWidth = 1
        return btn
    }

    // MARK: - Track pickers

    @objc private func audioTapped() {
        let audioStreams = mediaStreams.filter { $0.isAudio }
        guard audioStreams.count > 1 else { return }

#if IOS6_TARGET
        pendingAudioOptions = audioStreams.map { $0.index }
        let sheet = UIActionSheet(title: "Audio Track", delegate: self,
                                  cancelButtonTitle: nil, destructiveButtonTitle: nil)
        sheet.tag = 1
        for s in audioStreams {
            let mark = s.index == selectedAudioIndex ? "✓ " : ""
            sheet.addButton(withTitle: "\(mark)\(s.displayTitle)")
        }
        sheet.addButton(withTitle: "Cancel")
        sheet.cancelButtonIndex = sheet.numberOfButtons - 1
        activeActionSheet = sheet
        sheet.show(in: view)
#else
        let alert = UIAlertController(title: "Audio Track", message: nil, preferredStyle: .actionSheet)
        for s in audioStreams {
            let mark = s.index == selectedAudioIndex ? "✓ " : ""
            alert.addAction(UIAlertAction(title: "\(mark)\(s.displayTitle)", style: .default) { [weak self] _ in
                guard let self = self else { return }
                self.selectedAudioIndex = s.index
                self.forceRebuild()
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
#endif
    }

    @objc private func subtitleTapped() {
        let subtitleStreams = mediaStreams.filter { $0.isSubtitle }
        guard !subtitleStreams.isEmpty else { return }

#if IOS6_TARGET
        pendingSubtitleOptions = [nil] + subtitleStreams.map { Optional($0.index) }
        let sheet = UIActionSheet(title: "Subtitles", delegate: self,
                                  cancelButtonTitle: nil, destructiveButtonTitle: nil)
        sheet.tag = 2
        let offMark = selectedSubtitleIndex == nil ? "✓ " : ""
        sheet.addButton(withTitle: "\(offMark)Off")
        for s in subtitleStreams {
            let mark = s.index == selectedSubtitleIndex ? "✓ " : ""
            sheet.addButton(withTitle: "\(mark)\(s.displayTitle)")
        }
        sheet.addButton(withTitle: "Cancel")
        sheet.cancelButtonIndex = sheet.numberOfButtons - 1
        activeActionSheet = sheet
        sheet.show(in: view)
#else
        let alert = UIAlertController(title: "Subtitles", message: nil, preferredStyle: .actionSheet)
        let offMark = selectedSubtitleIndex == nil ? "✓ " : ""
        alert.addAction(UIAlertAction(title: "\(offMark)Off", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.selectedSubtitleIndex = nil
            self.forceRebuild()
        })
        for s in subtitleStreams {
            let mark = s.index == selectedSubtitleIndex ? "✓ " : ""
            alert.addAction(UIAlertAction(title: "\(mark)\(s.displayTitle)", style: .default) { [weak self] _ in
                guard let self = self else { return }
                self.selectedSubtitleIndex = s.index
                self.forceRebuild()
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
#endif
    }

    @objc private func transcodeTapped() {
        forceTranscode = !forceTranscode
        forceRebuild()
    }

    @objc private func playTapped() {
        navigationController?.pushViewController(
            VideoPlayerVC(item: item,
                          audioIndex: selectedAudioIndex,
                          subtitleIndex: selectedSubtitleIndex,
                          forceTranscode: forceTranscode),
            animated: true
        )
    }
}

// MARK: - UIActionSheetDelegate (iOS 6/7 only)

#if IOS6_TARGET
extension ItemDetailVC: UIActionSheetDelegate {
    func actionSheet(_ actionSheet: UIActionSheet, clickedButtonAt buttonIndex: Int) {
        defer { activeActionSheet = nil }
        guard buttonIndex != actionSheet.cancelButtonIndex else { return }
        if actionSheet.tag == 1 {
            guard buttonIndex < pendingAudioOptions.count else { return }
            selectedAudioIndex = pendingAudioOptions[buttonIndex]
        } else {
            guard buttonIndex < pendingSubtitleOptions.count else { return }
            selectedSubtitleIndex = pendingSubtitleOptions[buttonIndex]
        }
        forceRebuild()
    }
}
#endif
