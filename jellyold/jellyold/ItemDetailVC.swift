import UIKit

// MARK: - DownloadQuality
// "Original" requests Jellyfin's static (no-transcode) remux — full quality, near-zero
// server CPU, but only possible when no burned-in subtitle or non-default audio track is
// selected (those require a real transcode to apply). The transcode tiers cap resolution
// and bitrate so a movie download doesn't consume unnecessary space/time on these devices.
private enum DownloadQuality: CaseIterable, Equatable {
    case original, q720, q480, q360

    var label: String {
        switch self {
        case .original: return "Original (no transcode)"
        case .q720: return "720p \u{00b7} 4 Mbps"
        case .q480: return "480p \u{00b7} 2 Mbps"
        case .q360: return "360p \u{00b7} 1 Mbps"
        }
    }
    var maxWidth: Int? {
        switch self {
        case .original: return nil
        case .q720: return 1280
        case .q480: return 854
        case .q360: return 640
        }
    }
    var videoBitrate: Int? {
        switch self {
        case .original: return nil
        case .q720: return 4_000_000
        case .q480: return 2_000_000
        case .q360: return 1_000_000
        }
    }
    var audioBitrate: Int? {
        switch self {
        case .original: return nil
        case .q720, .q480: return 128_000
        case .q360: return 96_000
        }
    }
}

class ItemDetailVC: UIViewController {

    private let item: MediaItem
    private let bgColor = UIColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1.0)
    private let accentColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1.0)
    private var scrollView: UIScrollView!
    private var lastBuiltWidth: CGFloat = 0

    private var mediaStreams: [MediaStream] = []
    private var selectedAudioIndex: Int?
    private var defaultAudioIndex: Int?     // the server-reported default, for the "Original" check
    private var selectedSubtitleIndex: Int?
    private var forceTranscode = false

    private var downloadBtn: UIButton?
    private var downloadPollTimer: Timer?

#if IOS6_TARGET
    private var pendingAudioOptions: [Int] = []
    private var pendingSubtitleOptions: [Int?] = []
    private var pendingDownloadQualities: [DownloadQuality] = []
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
                    self.defaultAudioIndex = def.index
                }
                DispatchQueue.main.async { self.forceRebuild() }
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // A download started from here may still be running after navigating away and
        // back — reattach the button's progress display.
        if DownloadManager.isDownloading(item.id) {
            startDownloadPoll()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        downloadPollTimer?.invalidate()
        downloadPollTimer = nil
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

        if item.type != "Audio" {
            let dl = UIButton(type: .custom)
            dl.frame = CGRect(x: 16, y: y, width: w - 32, height: 44)
            dl.setTitleColor(.white, for: .normal)
            dl.titleLabel?.font = UIFont.boldSystemFont(ofSize: 15)
            dl.layer.cornerRadius = 8
            dl.addTarget(self, action: #selector(downloadTapped), for: .touchUpInside)
            scrollView.addSubview(dl)
            downloadBtn = dl
            updateDownloadButton()
            y += 44 + 20
        }

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

    // MARK: - Download

    private func updateDownloadButton() {
        guard let btn = downloadBtn else { return }
        if DownloadManager.isDownloading(item.id) {
            let pct = Int(DownloadManager.progress(for: item.id) * 100)
            btn.setTitle("Downloading \(pct)%\u{2026}", for: .normal)
            btn.backgroundColor = UIColor(white: 1.0, alpha: 0.08)
            btn.isEnabled = false
        } else if DownloadManager.isDownloaded(item.id) {
            btn.setTitle("Downloaded \u{2713}  (tap to delete)", for: .normal)
            btn.backgroundColor = UIColor(red: 0.15, green: 0.4, blue: 0.15, alpha: 1)
            btn.isEnabled = true
        } else {
            btn.setTitle("Download", for: .normal)
            btn.backgroundColor = UIColor(white: 1.0, alpha: 0.08)
            btn.isEnabled = true
        }
    }

    @objc private func downloadTapped() {
        if DownloadManager.isDownloaded(item.id) {
            confirmDeleteDownload()
            return
        }
        guard !DownloadManager.isDownloading(item.id) else { return }
        presentDownloadQualityPicker()
    }

    private func confirmDeleteDownload() {
#if IOS6_TARGET
        let sheet = UIActionSheet(title: "Delete this download?", delegate: self,
                                  cancelButtonTitle: "Cancel", destructiveButtonTitle: "Delete")
        sheet.tag = 4
        activeActionSheet = sheet
        sheet.show(in: view)
#else
        let alert = UIAlertController(title: "Delete Download", message: "Remove the offline copy of this video?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.deleteDownload()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
#endif
    }

    private func deleteDownload() {
        DownloadManager.remove(item.id)
        updateDownloadButton()
    }

    // "Original" is only offered when no subtitle or non-default audio track is selected —
    // those require Jellyfin to burn in / transcode, which a static remux can't do.
    private var availableDownloadQualities: [DownloadQuality] {
        let originalOK = selectedSubtitleIndex == nil
            && (selectedAudioIndex == nil || selectedAudioIndex == defaultAudioIndex)
        var list: [DownloadQuality] = originalOK ? [.original] : []
        list.append(contentsOf: [.q720, .q480, .q360])
        return list
    }

    private func presentDownloadQualityPicker() {
        let qualities = availableDownloadQualities
#if IOS6_TARGET
        pendingDownloadQualities = qualities
        let sheet = UIActionSheet(title: "Download Quality", delegate: self,
                                  cancelButtonTitle: nil, destructiveButtonTitle: nil)
        sheet.tag = 3
        for q in qualities { sheet.addButton(withTitle: q.label) }
        sheet.addButton(withTitle: "Cancel")
        sheet.cancelButtonIndex = sheet.numberOfButtons - 1
        activeActionSheet = sheet
        sheet.show(in: view)
#else
        let alert = UIAlertController(title: "Download Quality", message: nil, preferredStyle: .actionSheet)
        for q in qualities {
            alert.addAction(UIAlertAction(title: q.label, style: .default) { [weak self] _ in
                self?.beginDownload(quality: q)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
#endif
    }

    private func downloadURL(quality: DownloadQuality) -> URL? {
        guard let serverURL = JellyfinServer.serverURL,
              let token = JellyfinServer.accessToken else { return nil }
        var params = [
            "api_key=\(token)",
            "MediaSourceId=\(item.id)",
            "DeviceId=jellyold-device-01"
        ]
        if quality == .original {
            params.append("Static=true")
        } else {
            let sessionId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            params.append("PlaySessionId=\(sessionId)")
            params.append("EnableDirectStream=false")
            params.append("EnableDirectPlay=false")
            params.append("VideoCodec=h264")
            params.append("AudioCodec=aac")
            if let w = quality.maxWidth { params.append("MaxWidth=\(w)") }
            if let vb = quality.videoBitrate { params.append("VideoBitRate=\(vb)") }
            if let ab = quality.audioBitrate { params.append("AudioBitRate=\(ab)") }
            if let audioIdx = selectedAudioIndex {
                params.append("AudioStreamIndex=\(audioIdx)")
            }
            if let subIdx = selectedSubtitleIndex {
                params.append("SubtitleStreamIndex=\(subIdx)")
                params.append("SubtitleMethod=Encode")
            }
        }
        return URL(string: "\(serverURL)/Videos/\(item.id)/stream.mp4?\(params.joined(separator: "&"))")
    }

    private func beginDownload(quality: DownloadQuality) {
        guard let url = downloadURL(quality: quality) else { return }
        DownloadManager.startDownload(item, url: url.absoluteString)
        updateDownloadButton()
        startDownloadPoll()
    }

    private func startDownloadPoll() {
        downloadPollTimer?.invalidate()
        let t = Timer(timeInterval: 0.5, target: ItemDetailPollProxy { [weak self] in
            guard let self = self else { return }
            self.updateDownloadButton()
            if !DownloadManager.isDownloading(self.item.id) {
                self.downloadPollTimer?.invalidate()
                self.downloadPollTimer = nil
            }
        }, selector: #selector(ItemDetailPollProxy.fire), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        downloadPollTimer = t
    }
}

// MARK: - Timer helper (avoids retain cycles with the download poll timer on iOS 6)

private class ItemDetailPollProxy: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}

// MARK: - UIActionSheetDelegate (iOS 6/7 only)

#if IOS6_TARGET
extension ItemDetailVC: UIActionSheetDelegate {
    func actionSheet(_ actionSheet: UIActionSheet, clickedButtonAt buttonIndex: Int) {
        defer { activeActionSheet = nil }
        guard buttonIndex != actionSheet.cancelButtonIndex else { return }
        switch actionSheet.tag {
        case 1:
            guard buttonIndex < pendingAudioOptions.count else { return }
            selectedAudioIndex = pendingAudioOptions[buttonIndex]
            forceRebuild()
        case 2:
            guard buttonIndex < pendingSubtitleOptions.count else { return }
            selectedSubtitleIndex = pendingSubtitleOptions[buttonIndex]
            forceRebuild()
        case 3:
            guard buttonIndex < pendingDownloadQualities.count else { return }
            beginDownload(quality: pendingDownloadQualities[buttonIndex])
        case 4:
            deleteDownload()
        default:
            break
        }
    }
}
#endif
