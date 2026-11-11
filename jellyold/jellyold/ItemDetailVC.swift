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
    private var fileInfo: MediaFileInfo?

    private var downloadBtn: UIButton?
    private var downloadPollTimer: Timer?

    private var castBtn: UIButton?
    private var castSpinner: UIActivityIndicatorView?
    // The device chosen in the first sheet, held while the quality sheet is up.
    private var pendingCastDevice: CastDevice?

#if IOS6_TARGET
    private var pendingAudioOptions: [Int] = []
    private var pendingSubtitleOptions: [Int?] = []
    private var pendingDownloadQualities: [DownloadQuality] = []
    private var pendingCastDevices: [CastDevice] = []
    private var pendingCastQualities: [DownloadQuality] = []
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
        // Room for MiniPlayerBar, which floats over the nav controller's view.
        scrollView.contentInset = UIEdgeInsets(top: 0, left: 0,
                                              bottom: MiniPlayerBar.barHeight, right: 0)
        view.addSubview(scrollView)

        // Fetched for every item type (including Audio) — the file-metadata section at the
        // bottom of the page needs size/date/container regardless of media type, even though
        // the audio/subtitle track pickers above it only apply to video.
        JellyfinAPI.getMediaInfo(itemId: item.id) { [weak self] streams, info in
            guard let self = self else { return }
            self.mediaStreams = streams
            self.fileInfo = info
            if self.item.type != "Audio" {
                let audioStreams = streams.filter { $0.isAudio }
                if let def = audioStreams.first(where: { $0.isDefault }) ?? audioStreams.first {
                    self.selectedAudioIndex = def.index
                    self.defaultAudioIndex = def.index
                }
            }
            DispatchQueue.main.async { self.forceRebuild() }
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

        // Play shares its row with the cast button. Photos never reach this screen,
        // so everything that gets here is castable.
        let castW: CGFloat = 50
        let gap: CGFloat = 8
        let playBtn = UIButton(type: .custom)
        playBtn.frame = CGRect(x: 16, y: y, width: w - 32 - castW - gap, height: 50)
        playBtn.setTitle("Play", for: .normal)
        playBtn.setTitleColor(.white, for: .normal)
        playBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 18)
        playBtn.backgroundColor = accentColor
        playBtn.layer.cornerRadius = 10
        playBtn.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        scrollView.addSubview(playBtn)

        let cast = UIButton(type: .custom)
        cast.frame = CGRect(x: w - 16 - castW, y: y, width: castW, height: 50)
        cast.setImage(UIImage(named: "cast"), for: .normal)
        cast.backgroundColor = accentColor
        cast.layer.cornerRadius = 10
        cast.addTarget(self, action: #selector(castTapped), for: .touchUpInside)
        scrollView.addSubview(cast)
        castBtn = cast

        // Bonjour discovery runs for a fixed few seconds with no progress signal,
        // so the glyph swaps for a spinner to show the tap registered.
        let spinner = UIActivityIndicatorView(style: .white)
        spinner.frame = cast.bounds
        spinner.hidesWhenStopped = true
        cast.addSubview(spinner)
        castSpinner = spinner
        y += 50 + 12

        if item.type == "Audio" {
            let playNext = makeTrackButton("Play Next", y: y, width: w)
            playNext.addTarget(self, action: #selector(playNextTapped), for: .touchUpInside)
            scrollView.addSubview(playNext)
            y += 40 + 8

            let addEnd = makeTrackButton("Add to Queue", y: y, width: w)
            addEnd.addTarget(self, action: #selector(addToQueueTapped), for: .touchUpInside)
            scrollView.addSubview(addEnd)
            y += 40 + 20
        }

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

        y = buildFileMetadata(y: y, width: w)

        y += 30
        scrollView.contentSize = CGSize(width: w, height: y)
    }

    // Small metadata block (size / date added / container+codec) at the bottom of the page.
    // Each line only appears if the server actually returned that field. Returns the updated y.
    private func buildFileMetadata(y: CGFloat, width w: CGFloat) -> CGFloat {
        guard let info = fileInfo else { return y }
        var lines: [String] = []
        if let size = info.sizeBytes {
            lines.append("File size: \(DownloadManager.formatBytes(Double(size)))")
        }
        if let date = info.dateCreated {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .none
            lines.append("Added: \(df.string(from: date))")
        }
        let formatParts = [info.container?.uppercased(), info.videoCodec.map(ItemDetailVC.codecLabel)].compactMap { $0 }
        if !formatParts.isEmpty {
            lines.append("Format: \(formatParts.joined(separator: " \u{00b7} "))")
        }
        guard !lines.isEmpty else { return y }

        var y = y + 8
        let divider = UIView(frame: CGRect(x: 16, y: y, width: w - 32, height: 1))
        divider.backgroundColor = UIColor(white: 1.0, alpha: 0.1)
        scrollView.addSubview(divider)
        y += 1 + 14

        let label = UILabel(frame: CGRect(x: 16, y: y, width: w - 32, height: 0))
        label.text = lines.joined(separator: "\n")
        label.textColor = UIColor(white: 0.45, alpha: 1.0)
        label.backgroundColor = .clear
        label.font = UIFont.systemFont(ofSize: 12)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.sizeToFit()
        label.frame = CGRect(x: 16, y: y, width: w - 32, height: label.frame.height)
        scrollView.addSubview(label)
        y += label.frame.height
        return y
    }

    private static func codecLabel(_ raw: String) -> String {
        let known = [
            "h264": "H.264", "avc": "H.264",
            "hevc": "HEVC", "h265": "HEVC",
            "av1": "AV1", "vp9": "VP9", "vp8": "VP8",
            "mpeg4": "MPEG-4", "mpeg2video": "MPEG-2", "vc1": "VC-1"
        ]
        return known[raw.lowercased()] ?? raw.uppercased()
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
        if item.type == "Audio" {
            AudioQueue.shared.play(items: [item], startAt: 0)
            navigationController?.pushViewController(NowPlayingVC(), animated: true)
            return
        }
        navigationController?.pushViewController(
            VideoPlayerVC(item: item,
                          audioIndex: selectedAudioIndex,
                          subtitleIndex: selectedSubtitleIndex,
                          forceTranscode: forceTranscode),
            animated: true
        )
    }

    @objc private func playNextTapped() { AudioQueue.shared.playNext(item) }
    @objc private func addToQueueTapped() { AudioQueue.shared.addToEnd(item) }

    // MARK: - Cast

    @objc private func castTapped() {
        // Already casting — go to the controls rather than restarting the session.
        if CastController.shared.isCasting {
            navigationController?.pushViewController(CastVC(), animated: true)
            return
        }
        castSpinner?.startAnimating()
        castBtn?.setImage(nil, for: .normal)
        CastController.shared.discoverDevices { [weak self] devices in
            guard let self = self else { return }
            self.castSpinner?.stopAnimating()
            self.castBtn?.setImage(UIImage(named: "cast"), for: .normal)
            if devices.isEmpty {
                self.showNoDevicesAlert()
            } else {
                self.presentCastDevicePicker(devices)
            }
        }
    }

    private func showNoDevicesAlert() {
#if IOS6_TARGET
        UIAlertView(title: "No Chromecast found",
                    message: "Make sure a Chromecast is powered on and joined to the same Wi-Fi network as this device.",
                    delegate: nil, cancelButtonTitle: "OK").show()
#else
        let alert = UIAlertController(title: "No Chromecast found",
                                      message: "Make sure a Chromecast is powered on and joined to the same Wi-Fi network as this device.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
#endif
    }

    private func presentCastDevicePicker(_ devices: [CastDevice]) {
#if IOS6_TARGET
        pendingCastDevices = devices
        let sheet = UIActionSheet(title: "Cast to\u{2026}", delegate: self,
                                  cancelButtonTitle: nil, destructiveButtonTitle: nil)
        sheet.tag = 5
        for d in devices { sheet.addButton(withTitle: d.name) }
        sheet.addButton(withTitle: "Cancel")
        sheet.cancelButtonIndex = sheet.numberOfButtons - 1
        activeActionSheet = sheet
        sheet.show(in: view)
#else
        let alert = UIAlertController(title: "Cast to\u{2026}", message: nil, preferredStyle: .actionSheet)
        for d in devices {
            alert.addAction(UIAlertAction(title: d.name, style: .default) { [weak self] _ in
                self?.deviceChosen(d)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
#endif
    }

    // Audio has no quality tiers (the cast stream is always mp3), so it starts
    // immediately; video goes on to the quality sheet.
    private func deviceChosen(_ device: CastDevice) {
        pendingCastDevice = device
        if item.type == "Audio" {
            beginCast(quality: nil)
        } else {
            presentCastQualityPicker()
        }
    }

    private func presentCastQualityPicker() {
        let qualities = availableDownloadQualities
#if IOS6_TARGET
        pendingCastQualities = qualities
        let sheet = UIActionSheet(title: "Cast Quality", delegate: self,
                                  cancelButtonTitle: nil, destructiveButtonTitle: nil)
        sheet.tag = 6
        for q in qualities { sheet.addButton(withTitle: q.label) }
        sheet.addButton(withTitle: "Cancel")
        sheet.cancelButtonIndex = sheet.numberOfButtons - 1
        activeActionSheet = sheet
        sheet.show(in: view)
#else
        let alert = UIAlertController(title: "Cast Quality", message: nil, preferredStyle: .actionSheet)
        for q in qualities {
            alert.addAction(UIAlertAction(title: q.label, style: .default) { [weak self] _ in
                self?.beginCast(quality: q)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
#endif
    }

    private func beginCast(quality: DownloadQuality?) {
        guard let device = pendingCastDevice else { return }
        pendingCastDevice = nil

        let isAudio = item.type == "Audio"
        let kind: CastController.Kind = isAudio ? .audio : .video
        // The Chromecast fetches these URLs itself over the LAN, so they must be the
        // real server URL — LocalStreamProxy binds to 127.0.0.1 and is unreachable
        // from the device.
        let sources = isAudio ? audioCastSources() : videoCastSources(quality: quality ?? .original)

        let start = CastController.shared.savedResumePosition(for: item, kind: kind)
        CastController.shared.start(item: item, kind: kind, device: device,
                                    sources: sources, startTime: start)
        guard CastController.shared.isCasting else { return }
        navigationController?.pushViewController(CastVC(), animated: true)
    }

    // The URL builders below capture values, never self: CastController keeps them for as
    // long as the cast runs, well after this screen is popped.

    // HLS first. Jellyfin publishes the whole segment list up front (a VOD playlist), so the
    // receiver knows the real length and can seek anywhere — asking for a segment past the
    // transcode head makes Jellyfin restart ffmpeg there. The progressive mp4 is kept as a
    // fallback for a receiver that rejects the playlist; being chunked with no length it can
    // only play forward, so seeking re-requests it from the new position.
    private func videoCastSources(quality: DownloadQuality) -> [CastSource] {
        let itemId = item.id
        let audioIndex = selectedAudioIndex
        let subtitleIndex = selectedSubtitleIndex
        return [
            CastSource(contentType: "application/x-mpegURL", seeksByReloading: false) { _ in
                ItemDetailVC.hlsURL(itemId: itemId, quality: quality,
                                    audioIndex: audioIndex, subtitleIndex: subtitleIndex)?.absoluteString
            },
            CastSource(contentType: "video/mp4", seeksByReloading: true) { t in
                ItemDetailVC.streamURL(itemId: itemId, quality: quality, audioIndex: audioIndex,
                                       subtitleIndex: subtitleIndex, startTime: t)?.absoluteString
            }
        ]
    }

    // An mp3 file goes out untouched with a Content-Length, so the receiver seeks it itself
    // and shows its real length. Anything else is transcoded to a chunked mp3 it can only
    // play forward, so seeking re-requests the stream from the new position.
    private func audioCastSources() -> [CastSource] {
        let itemId = item.id
        if fileInfo?.container?.lowercased() == "mp3" {
            return [CastSource(contentType: "audio/mpeg", seeksByReloading: false) { _ in
                ItemDetailVC.castAudioURL(itemId: itemId, direct: true, startTime: 0)?.absoluteString
            }]
        }
        return [CastSource(contentType: "audio/mpeg", seeksByReloading: true) { t in
            ItemDetailVC.castAudioURL(itemId: itemId, direct: false, startTime: t)?.absoluteString
        }]
    }

    private static func hlsURL(itemId: String, quality: DownloadQuality,
                               audioIndex: Int?, subtitleIndex: Int?) -> URL? {
        guard let serverURL = JellyfinServer.serverURL,
              let token = JellyfinServer.accessToken else { return nil }
        var params = [
            "api_key=\(token)",
            "MediaSourceId=\(itemId)",
            "DeviceId=\(JellyfinServer.deviceId)",
            "PlaySessionId=\(newPlaySessionId())",
            "VideoCodec=h264",
            "AudioCodec=aac",
            "SegmentContainer=ts",
            // A single rendition — the receiver mustn't hop between variants Jellyfin
            // would each have to transcode.
            "EnableAdaptiveBitrateStreaming=false"
        ]
        if quality == .original {
            // Remux when the codecs already fit, same as the progressive Original.
            params.append("AllowVideoStreamCopy=true")
            params.append("AllowAudioStreamCopy=true")
        } else {
            params.append("AllowVideoStreamCopy=false")
            if let w = quality.maxWidth { params.append("MaxWidth=\(w)") }
            if let vb = quality.videoBitrate { params.append("VideoBitRate=\(vb)") }
            if let ab = quality.audioBitrate { params.append("AudioBitRate=\(ab)") }
        }
        if let audioIdx = audioIndex {
            params.append("AudioStreamIndex=\(audioIdx)")
        }
        if let subIdx = subtitleIndex {
            params.append("SubtitleStreamIndex=\(subIdx)")
            params.append("SubtitleMethod=Encode")
        }
        return URL(string: "\(serverURL)/Videos/\(itemId)/master.m3u8?\(params.joined(separator: "&"))")
    }

    // `direct` serves the file as-is (only valid for an mp3 source). Otherwise it always goes
    // through ffmpeg (no Static) so the bytes are mp3 whatever the source — matching the
    // contentType the receiver was handed — and StartTimeTicks is honoured.
    private static func castAudioURL(itemId: String, direct: Bool, startTime: Double) -> URL? {
        guard let serverURL = JellyfinServer.serverURL,
              let token = JellyfinServer.accessToken else { return nil }
        var params = [
            "api_key=\(token)",
            "DeviceId=\(JellyfinServer.deviceId)",
            "PlaySessionId=\(newPlaySessionId())"
        ]
        if direct {
            params.append("Static=true")
        } else {
            params.append("AudioCodec=mp3")
            params.append("AudioBitRate=320000")
            params.append("MaxAudioChannels=2")
            if startTime > 0 { params.append("StartTimeTicks=\(Int64(startTime * 10_000_000))") }
        }
        return URL(string: "\(serverURL)/Audio/\(itemId)/stream.mp3?\(params.joined(separator: "&"))")
    }

    // A unique PlaySessionId per request: Jellyfin keys a running transcode on it, and a
    // reused one hands back the old job (from its old start position) instead of a new one.
    private static func newPlaySessionId() -> String {
        return UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    // MARK: - Download

    private func updateDownloadButton() {
        guard let btn = downloadBtn else { return }
        if DownloadManager.isDownloading(item.id) {
            // Percentage relies on the server reporting a Content-Length, which it won't
            // for a chunked transcode/remux response — fall back to bytes-so-far so an
            // unknown-length transfer doesn't look frozen at 0%.
            let pct = Int(DownloadManager.progress(for: item.id) * 100)
            let sz = DownloadManager.fileSizeText(for: item.id)
            btn.setTitle(pct > 0 ? "Downloading \(pct)%\u{2026}"
                                 : "Downloading\u{2026}" + (sz.isEmpty ? "" : " \(sz)"), for: .normal)
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

    private func streamURL(quality: DownloadQuality) -> URL? {
        return ItemDetailVC.streamURL(itemId: item.id, quality: quality, audioIndex: selectedAudioIndex,
                                      subtitleIndex: selectedSubtitleIndex, startTime: 0)
    }

    // Shared by the download and the cast-fallback paths — both want a plain, self-contained
    // mp4 the fetcher (the phone, or the Chromecast) can pull over HTTP. `startTime` starts
    // the stream mid-file (honoured because Direct Play is off, so it always goes through ffmpeg).
    private static func streamURL(itemId: String, quality: DownloadQuality, audioIndex: Int?,
                                  subtitleIndex: Int?, startTime: Double) -> URL? {
        guard let serverURL = JellyfinServer.serverURL,
              let token = JellyfinServer.accessToken else { return nil }
        var params = [
            "api_key=\(token)",
            "MediaSourceId=\(itemId)",
            "DeviceId=\(JellyfinServer.deviceId)",
            "PlaySessionId=\(newPlaySessionId())",
            "VideoCodec=h264",
            "AudioCodec=aac",
            // Direct Play (the old Static=true behaviour) hands back the source file
            // completely unprocessed — wrong container/codec for many sources (e.g. MKV/HEVC),
            // which iOS can't play. Disabling it forces at least a remux into a real mp4
            // container; Direct Stream still avoids a full re-encode when codecs already match.
            "EnableDirectPlay=false"
        ]
        if quality != .original {
            // Resolution/bitrate caps can't be honoured by a remux — force a real transcode.
            params.append("EnableDirectStream=false")
            if let w = quality.maxWidth { params.append("MaxWidth=\(w)") }
            if let vb = quality.videoBitrate { params.append("VideoBitRate=\(vb)") }
            if let ab = quality.audioBitrate { params.append("AudioBitRate=\(ab)") }
            if let audioIdx = audioIndex {
                params.append("AudioStreamIndex=\(audioIdx)")
            }
            if let subIdx = subtitleIndex {
                params.append("SubtitleStreamIndex=\(subIdx)")
                params.append("SubtitleMethod=Encode")
            }
        }
        if startTime > 0 { params.append("StartTimeTicks=\(Int64(startTime * 10_000_000))") }
        return URL(string: "\(serverURL)/Videos/\(itemId)/stream.mp4?\(params.joined(separator: "&"))")
    }

    private func beginDownload(quality: DownloadQuality) {
        guard let url = streamURL(quality: quality) else { return }
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
        case 5:
            guard buttonIndex < pendingCastDevices.count else { return }
            deviceChosen(pendingCastDevices[buttonIndex])
        case 6:
            guard buttonIndex < pendingCastQualities.count else { return }
            beginCast(quality: pendingCastQualities[buttonIndex])
        default:
            break
        }
    }
}
#endif
