import UIKit

// MARK: - DownloadQuality
// "Original" requests Jellyfin's static (no-transcode) remux — full quality, near-zero
// server CPU, but only possible when no painted-in (image) subtitle or non-default audio
// track is selected (those require a real transcode to apply). The transcode tiers cap resolution
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
    // Downloaded, watched.
    private let doneColor = UIColor(red: 0.15, green: 0.4, blue: 0.15, alpha: 1.0)
    private var scrollView: UIScrollView!
    private var lastBuiltWidth: CGFloat = 0
    private var hasAppeared = false

    private var mediaStreams: [MediaStream] = []
    private var selectedAudioIndex: Int?
    private var defaultAudioIndex: Int?     // the server-reported default, for the "Original" check
    private var selectedSubtitleIndex: Int?
    private var fileInfo: MediaFileInfo?
    // The server's answer to a watched toggle made here, until the next full fetch.
    private var markedState: ServerPlayState?
    // The toggle's new value while the server hasn't answered.
    private var playedPending: Bool?

    // What the server knows of this user and the item, newest first: a toggle made here,
    // the full fetch, the list item this page was opened from.
    private var serverState: ServerPlayState? {
        return markedState ?? fileInfo?.playState ?? item.playState
    }
    private var isPlayed: Bool { return playedPending ?? serverState?.played ?? false }
    // Where Play starts, 0 for the beginning: the same position the player will pick.
    private var resumePosition: Double {
        return item.type == "Audio" ? 0 : ResumeStore.startPosition(for: item.id, server: serverState)
    }

    // A text subtitle is drawn by the player; an image one is painted in by the server.
    // Without the track list (offline) the pick can only be the subtitle saved with the
    // download, which is always text.
    private var subtitleChoice: SubtitleChoice? {
        guard let index = selectedSubtitleIndex else { return nil }
        if let stream = mediaStreams.first(where: { $0.index == index }), !stream.isTextSubtitle {
            return .burnedIn(index)
        }
        return .drawn(index)
    }

    private var burnedInSubtitleIndex: Int? {
        if case .burnedIn(let index)? = subtitleChoice { return index }
        return nil
    }

    // Jellyfin only applies an audio track or paints a subtitle in a full transcode (a remux
    // keeps the file's default tracks), so choosing one is what turns it on.
    private var forceTranscode: Bool {
        return burnedInSubtitleIndex != nil
            || (selectedAudioIndex != nil && selectedAudioIndex != defaultAudioIndex)
    }

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
        // Downloaded with a subtitle: it's the one picked, and the only one offline.
        if DownloadManager.isDownloaded(item.id) {
            selectedSubtitleIndex = DownloadManager.subtitleIndex(for: item.id)
        }
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

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
        // Back from playing it: the server now has a new resume point, or marked it watched.
        NotificationCenter.default.addObserver(self, selector: #selector(playbackReported(_:)),
                                               name: PlaybackReporter.didStopNotification, object: nil)
        loadInfo()
    }

    // The full item: details the list didn't carry (genres, credits, rating, every image),
    // the file's tracks and facts, and the server's current resume point. Fetched for every
    // item type, Audio included — the file facts at the bottom apply to it too.
    private func loadInfo() {
        JellyfinAPI.getMediaInfo(itemId: item.id) { [weak self] streams, info in
            guard let self = self else { return }
            // A failed refresh keeps the page as it was.
            if self.fileInfo != nil && info.item == nil { return }
            self.mediaStreams = streams
            self.fileInfo = info
            self.markedState = nil
            // Only the first time: a refresh after playback keeps the tracks chosen here.
            if self.item.type != "Audio" && self.defaultAudioIndex == nil {
                let audioStreams = streams.filter { $0.isAudio }
                if let def = audioStreams.first(where: { $0.isDefault }) ?? audioStreams.first {
                    self.selectedAudioIndex = def.index
                    self.defaultAudioIndex = def.index
                }
            }
            DispatchQueue.main.async { self.forceRebuild() }
        }
    }

    @objc private func playbackReported(_ note: Notification) {
        // A watched toggle made here has already updated this page.
        if (note.object as? ItemDetailVC) === self { return }
        DispatchQueue.main.async { [weak self] in self?.loadInfo() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // A download started from here may still be running after navigating away and
        // back — reattach the button's progress display.
        if DownloadManager.isDownloading(item.id) {
            startDownloadPoll()
        }
        // Back from the player: the local resume point moved before the server hears of it.
        if hasAppeared { forceRebuild() }
        hasAppeared = true
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

    // MARK: - Layout
    //
    // Narrow screens (a portrait iPhone) get a compact header — a small picture with the
    // title beside it, or a wide still above it — so Play is on screen without scrolling.
    // From 480pt (iPhone landscape, iPad) the picture gets a column of its own and the
    // text a column capped at a readable width, the pair centred. A blurred backdrop sits
    // behind the header. Everything is frames, rebuilt when the width or content changes.

    private var pictureStyle: ShelfStyle {
        switch item.type {
        case "Episode", "Video", "MusicVideo", "Trailer": return .landscape
        case "Audio", "MusicAlbum":                     return .square
        default:                                        return .poster
        }
    }

    private func buildContent(width w: CGFloat) {
        let shown = fileInfo?.item ?? item
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let wide = w >= 480
        let style = pictureStyle
        let aspect = style.imageSize.height / style.imageSize.width

        // Picture frame, then where the header text and the rest of the page go.
        let pic: CGRect
        let textX: CGFloat, textW: CGFloat, textY: CGFloat
        if wide {
            let margin: CGFloat = pad ? 32 : 16
            let gap: CGFloat = pad ? 28 : 16
            let picW: CGFloat
            switch style {
            case .poster:    picW = pad ? 240 : 130
            case .square:    picW = pad ? 240 : 150
            case .landscape: picW = pad ? 320 : 180
            }
            textW = min(w - margin * 2 - picW - gap, 600)
            let left = floor((w - (picW + gap + textW)) / 2)
            pic = CGRect(x: left, y: 24, width: picW, height: floor(picW * aspect))
            textX = left + picW + gap
            textY = pic.minY
        } else if style == .landscape {
            pic = CGRect(x: 16, y: 16, width: w - 32, height: floor((w - 32) * aspect))
            textX = 16; textW = w - 32
            textY = pic.maxY + 12
        } else {
            let picW: CGFloat = style == .square ? 120 : 100
            pic = CGRect(x: 16, y: 16, width: picW, height: floor(picW * aspect))
            textX = pic.maxX + 12; textW = w - textX - 16
            textY = pic.minY
        }

        let picture = AsyncImageView(frame: pic)
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.layer.cornerRadius = pad ? 8 : 6
        picture.backgroundColor = UIColor(white: 0.15, alpha: 1.0)
        // Rounded up to 100 px, so a rotation that nudges the size reuses the cached one.
        let px = Int(ceil(pic.width * UIScreen.main.scale / 100) * 100)
        if let url = style == .landscape ? shown.landscapeImageURL(maxWidth: px)
                                         : shown.posterImageURL(maxWidth: px) {
            picture.load(url: url)
        }
        scrollView.addSubview(picture)

        // Header: show, title, facts, genres.
        var y = textY
        if shown.type == "Episode", let series = shown.seriesName {
            y += addLabel(series, font: UIFont.systemFont(ofSize: 14), color: UIColor(white: 1, alpha: 0.7),
                          x: textX, y: y, width: textW, lines: 1) + 2
        }
        let titleSize: CGFloat = wide ? (pad ? 26 : 22) : 20
        y += addLabel(shown.name, font: UIFont.boldSystemFont(ofSize: titleSize), color: .white,
                      x: textX, y: y, width: textW, lines: wide ? 0 : 3) + 6
        let facts = factsLine(shown)
        if !facts.isEmpty {
            y += addLabel(facts, font: UIFont.systemFont(ofSize: 14), color: UIColor(white: 0.8, alpha: 1),
                          x: textX, y: y, width: textW) + 4
        }
        if let genres = fileInfo?.genres, !genres.isEmpty {
            y += addLabel(genres.prefix(3).joined(separator: " \u{00b7} "), font: UIFont.systemFont(ofSize: 13),
                          color: UIColor(white: 1, alpha: 0.55), x: textX, y: y, width: textW) + 4
        }

        // The rest of the page: under the header on a phone, on in the text column when wide.
        let bodyX: CGFloat, bodyW: CGFloat
        let bandH: CGFloat
        if wide {
            bodyX = textX; bodyW = textW
            y += 14
            bandH = max(pic.minY + pic.height * 0.6, y)
        } else {
            bodyX = 16; bodyW = w - 32
            y = max(y, pic.maxY) + 16
            bandH = y
        }

        y = buildActions(shown, x: bodyX, y: y, width: bodyW)

        if let overview = shown.overview, !overview.isEmpty {
            y += addLabel(overview, font: UIFont.systemFont(ofSize: 14), color: UIColor(white: 0.8, alpha: 1),
                          x: bodyX, y: y, width: bodyW) + 14
        }
        if let credits = creditsText() {
            y += addLabel(credits, font: UIFont.systemFont(ofSize: 13), color: UIColor(white: 1, alpha: 0.55),
                          x: bodyX, y: y, width: bodyW) + 16
        }
        if item.type != "Audio" {
            y = buildTrackRows(x: bodyX, y: y, width: bodyW)
        }
        y = buildFileMetadata(y: y, x: bodyX, width: bodyW)

        if let url = shown.backdropImageURL(maxWidth: 360) {
            // Blurred by the server: a small download and no blur work on the device.
            addBackdrop(url: url + "&blur=12", width: w, height: bandH)
        }

        let bottom = max(y, wide ? pic.maxY : 0) + 30
        scrollView.contentSize = CGSize(width: w, height: bottom)
    }

    // "S02E05 · 2009 · 47 min · TV-14 · ★ 8.2"
    private func factsLine(_ shown: MediaItem) -> String {
        var parts: [String] = []
        if let ep = shown.episodeLabel { parts.append(ep) }
        if let year = shown.year { parts.append(String(year)) }
        if let duration = shown.durationSeconds {
            parts.append(shown.type == "Audio" ? ItemDetailVC.clock(duration) : ItemDetailVC.runtimeText(duration))
        }
        if let rating = fileInfo?.officialRating, !rating.isEmpty { parts.append(rating) }
        if let score = fileInfo?.communityRating, score > 0 {
            parts.append(String(format: "\u{2605} %.1f", score))
        }
        return parts.joined(separator: " \u{00b7} ")
    }

    private func creditsText() -> String? {
        guard let info = fileInfo else { return nil }
        var lines: [String] = []
        if !info.directors.isEmpty {
            lines.append("Directed by " + info.directors.prefix(2).joined(separator: ", "))
        }
        if !info.cast.isEmpty {
            lines.append("With " + info.cast.prefix(4).joined(separator: ", "))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // Play (or Resume, with how far in) beside Cast and, for anything but a track, the
    // watched toggle; then a row of secondary actions: Play from Start + Download when
    // there's a resume point, Download alone otherwise, and Play Next + Add to Queue for a
    // track. Returns the y below them.
    private func buildActions(_ shown: MediaItem, x: CGFloat, y startY: CGFloat, width bodyW: CGFloat) -> CGFloat {
        var y = startY
        let rowW = min(bodyW, 420)
        let isAudio = item.type == "Audio"
        let resumeAt = resumePosition

        let iconW: CGFloat = 50
        let gap: CGFloat = 8
        let playW = rowW - (iconW + gap) * (isAudio ? 1 : 2)
        let playBtn = UIButton(type: .custom)
        playBtn.frame = CGRect(x: x, y: y, width: playW, height: 50)
        playBtn.setTitle(resumeAt > 0 ? "Resume " + ItemDetailVC.clock(resumeAt) : "Play", for: .normal)
        playBtn.setTitleColor(.white, for: .normal)
        playBtn.setTitleColor(UIColor(white: 1, alpha: 0.5), for: .highlighted)
        playBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 18)
        playBtn.backgroundColor = accentColor
        playBtn.layer.cornerRadius = 10
        playBtn.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        scrollView.addSubview(playBtn)

        // Photos never reach this screen, so everything that gets here is castable.
        let cast = UIButton(type: .custom)
        cast.frame = CGRect(x: x + playW + gap, y: y, width: iconW, height: 50)
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

        if !isAudio {
            addWatchedToggle(frame: CGRect(x: x + rowW - iconW, y: y, width: iconW, height: 50))
        }
        y += 50

        if resumeAt > 0, let duration = shown.durationSeconds, duration > 0 {
            let track = UIView(frame: CGRect(x: x + 2, y: y + 6, width: playW - 4, height: 3))
            track.backgroundColor = UIColor(white: 1, alpha: 0.15)
            let fill = UIView(frame: CGRect(x: 0, y: 0, width: floor(track.bounds.width * CGFloat(min(1, resumeAt / duration))),
                                            height: 3))
            fill.backgroundColor = accentColor
            track.addSubview(fill)
            scrollView.addSubview(track)
            y += 9
        }
        y += 10

        let half = floor((rowW - gap) / 2)
        if isAudio {
            let playNext = makeSecondaryButton("Play Next", frame: CGRect(x: x, y: y, width: half, height: 40))
            playNext.addTarget(self, action: #selector(playNextTapped), for: .touchUpInside)
            let addEnd = makeSecondaryButton("Add to Queue",
                                             frame: CGRect(x: x + rowW - half, y: y, width: half, height: 40))
            addEnd.addTarget(self, action: #selector(addToQueueTapped), for: .touchUpInside)
        } else {
            var dlFrame = CGRect(x: x, y: y, width: rowW, height: 40)
            if resumeAt > 0 {
                let fromStart = makeSecondaryButton("Play from Start", frame: CGRect(x: x, y: y, width: half, height: 40))
                fromStart.addTarget(self, action: #selector(playFromStartTapped), for: .touchUpInside)
                dlFrame = CGRect(x: x + rowW - half, y: y, width: half, height: 40)
            }
            let dl = makeSecondaryButton("Download", frame: dlFrame)
            dl.addTarget(self, action: #selector(downloadTapped), for: .touchUpInside)
            downloadBtn = dl
            updateDownloadButton()
        }
        return y + 40 + 20
    }

    // A check in a square, green once watched, as in Jellyfin's own apps. Greyed out while
    // the server hasn't answered a tap.
    private func addWatchedToggle(frame: CGRect) {
        let played = isPlayed
        let btn = UIButton(type: .custom)
        btn.frame = frame
        btn.layer.cornerRadius = 10
        if played {
            btn.backgroundColor = doneColor
        } else {
            btn.backgroundColor = UIColor(white: 1.0, alpha: 0.08)
            btn.layer.borderColor = UIColor(white: 1.0, alpha: 0.15).cgColor
            btn.layer.borderWidth = 1
        }
        btn.setImage(played ? ItemDetailVC.checkOn : ItemDetailVC.checkOff, for: .normal)
        btn.isEnabled = playedPending == nil
        btn.accessibilityLabel = played ? "Watched. Mark as unwatched" : "Mark as watched"
        btn.addTarget(self, action: #selector(watchedTapped), for: .touchUpInside)
        scrollView.addSubview(btn)
    }

    private static let checkOn = checkImage(alpha: 1)
    private static let checkOff = checkImage(alpha: 0.45)

    // Drawn rather than bundled: a 24 pt check mark, 3 pt stroke.
    private static func checkImage(alpha: CGFloat) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(CGSize(width: 24, height: 24), false, 0)
        defer { UIGraphicsEndImageContext() }
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 4, y: 12.5))
        path.addLine(to: CGPoint(x: 9.5, y: 18))
        path.addLine(to: CGPoint(x: 20, y: 6.5))
        path.lineWidth = 3
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        UIColor(white: 1, alpha: alpha).setStroke()
        path.stroke()
        return UIGraphicsGetImageFromCurrentImageContext()
    }

    // Audio and subtitle choices as rows showing the current pick. Choosing anything but
    // the file's defaults makes the server transcode, which a line under them says.
    private func buildTrackRows(x: CGFloat, y startY: CGFloat, width w: CGFloat) -> CGFloat {
        var y = startY
        let audioStreams = mediaStreams.filter { $0.isAudio }
        let subtitleStreams = mediaStreams.filter { $0.isSubtitle }

        if audioStreams.count > 1 {
            let value = audioStreams.first(where: { $0.index == selectedAudioIndex })?.displayTitle ?? "Default"
            let row = makeChoiceRow("Audio", value: value, frame: CGRect(x: x, y: y, width: w, height: 40))
            row.addTarget(self, action: #selector(audioTapped), for: .touchUpInside)
            y += 40 + 8
        }
        if !subtitleStreams.isEmpty {
            let value = selectedSubtitleIndex.flatMap { idx in
                subtitleStreams.first(where: { $0.index == idx })?.displayTitle
            } ?? "Off"
            let row = makeChoiceRow("Subtitles", value: value, frame: CGRect(x: x, y: y, width: w, height: 40))
            row.addTarget(self, action: #selector(subtitleTapped), for: .touchUpInside)
            y += 40 + 8
        }
        if forceTranscode {
            y += addLabel("The server converts the video to apply these tracks, so it may take a moment longer to start.",
                          font: UIFont.systemFont(ofSize: 12), color: UIColor(white: 0.5, alpha: 1),
                          x: x, y: y, width: w) + 8
        }
        return y
    }

    // Small file facts (size and formats, date added) at the bottom of the page. Each part
    // only appears if the server returned it. Returns the updated y.
    private func buildFileMetadata(y: CGFloat, x: CGFloat, width w: CGFloat) -> CGFloat {
        guard let info = fileInfo else { return y }
        var format: [String] = []
        if let size = info.sizeBytes { format.append(DownloadManager.formatBytes(Double(size))) }
        if let container = info.container?.uppercased() { format.append(container) }
        if let codec = info.videoCodec {
            let video = [ItemDetailVC.codecLabel(codec), ItemDetailVC.resolutionLabel(info)].compactMap { $0 }
            format.append(video.joined(separator: " "))
        }
        if let codec = info.audioCodec {
            let audio = [ItemDetailVC.audioCodecLabel(codec), info.audioChannels.map(ItemDetailVC.channelsLabel)]
                .compactMap { $0 }.joined(separator: " ")
            // A FLAC file's container and codec are the same word.
            if audio != format.last { format.append(audio) }
        }
        var lines: [String] = []
        if !format.isEmpty { lines.append(format.joined(separator: " \u{00b7} ")) }
        if let date = info.dateCreated {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .none
            lines.append("Added \(df.string(from: date))")
        }
        guard !lines.isEmpty else { return y }

        var y = y + 8
        let divider = UIView(frame: CGRect(x: x, y: y, width: w, height: 1))
        divider.backgroundColor = UIColor(white: 1.0, alpha: 0.1)
        scrollView.addSubview(divider)
        y += 1 + 12
        y += addLabel(lines.joined(separator: "\n"), font: UIFont.systemFont(ofSize: 12),
                      color: UIColor(white: 0.5, alpha: 1.0), x: x, y: y, width: w)
        return y
    }

    // Behind the header: the backdrop, darkened so white text reads on it, fading into the
    // page at the bottom instead of ending on a hard edge. Goes under everything else.
    private func addBackdrop(url: String, width: CGFloat, height: CGFloat) {
        let band = UIView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        band.clipsToBounds = true
        band.backgroundColor = bgColor
        let image = AsyncImageView(frame: band.bounds)
        image.contentMode = .scaleAspectFill
        image.backgroundColor = .clear
        image.load(url: url)
        band.addSubview(image)
        let shade = UIView(frame: band.bounds)
        shade.backgroundColor = UIColor(white: 0, alpha: 0.45)
        band.addSubview(shade)
        let fade = CAGradientLayer()
        fade.frame = CGRect(x: 0, y: floor(height * 0.4), width: width, height: height - floor(height * 0.4))
        fade.colors = [bgColor.withAlphaComponent(0).cgColor, bgColor.cgColor]
        band.layer.addSublayer(fade)
        scrollView.insertSubview(band, at: 0)
    }

    // Adds a label sized to its text; returns its height.
    @discardableResult
    private func addLabel(_ text: String, font: UIFont, color: UIColor, x: CGFloat, y: CGFloat,
                          width: CGFloat, lines: Int = 0) -> CGFloat {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.backgroundColor = .clear
        label.numberOfLines = lines
        let h = ceil(label.sizeThatFits(CGSize(width: width, height: 10_000)).height)
        label.frame = CGRect(x: x, y: y, width: width, height: h)
        scrollView.addSubview(label)
        return h
    }

    private func makeSecondaryButton(_ title: String, frame: CGRect) -> UIButton {
        let btn = UIButton(type: .custom)
        btn.frame = frame
        btn.setTitle(title, for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.setTitleColor(UIColor(white: 1, alpha: 0.5), for: .highlighted)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        // "Downloading 42%…" has to fit half a phone's width.
        btn.titleLabel?.adjustsFontSizeToFitWidth = true
        btn.titleLabel?.minimumScaleFactor = 0.75
        btn.contentEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        btn.backgroundColor = UIColor(white: 1.0, alpha: 0.08)
        btn.layer.cornerRadius = 8
        btn.layer.borderColor = UIColor(white: 1.0, alpha: 0.15).cgColor
        btn.layer.borderWidth = 1
        scrollView.addSubview(btn)
        return btn
    }

    // "Audio            English - AC3 - 5.1 ›"
    private func makeChoiceRow(_ title: String, value: String, frame: CGRect) -> UIButton {
        let row = makeSecondaryButton("", frame: frame)
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = UIFont.systemFont(ofSize: 15)
        titleLabel.textColor = .white
        titleLabel.backgroundColor = .clear
        let titleW = ceil(titleLabel.sizeThatFits(CGSize(width: frame.width, height: frame.height)).width)
        titleLabel.frame = CGRect(x: 12, y: 0, width: titleW, height: frame.height)
        row.addSubview(titleLabel)

        let valueLabel = UILabel()
        valueLabel.text = value + "  \u{203A}"
        valueLabel.font = UIFont.systemFont(ofSize: 14)
        valueLabel.textColor = UIColor(white: 1, alpha: 0.6)
        valueLabel.backgroundColor = .clear
        valueLabel.textAlignment = .right
        valueLabel.lineBreakMode = .byTruncatingMiddle
        let valueX = 12 + titleW + 12
        valueLabel.frame = CGRect(x: valueX, y: 0, width: frame.width - valueX - 12, height: frame.height)
        row.addSubview(valueLabel)
        return row
    }

    // MARK: - Text helpers

    // "1:02:10" / "42:10"
    private static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    // "2 h 16 min" / "47 min"
    private static func runtimeText(_ seconds: Double) -> String {
        let minutes = max(1, Int(seconds / 60 + 0.5))
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
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

    // By width: a 1920x800 scope film is still 1080p.
    private static func resolutionLabel(_ info: MediaFileInfo) -> String? {
        guard let w = info.videoWidth, w > 0 else { return info.videoHeight.map { "\($0)p" } }
        if w >= 3800 { return "4K" }
        if w >= 1900 { return "1080p" }
        if w >= 1260 { return "720p" }
        if let h = info.videoHeight, h > 0 { return "\(h)p" }
        return nil
    }

    private static func audioCodecLabel(_ raw: String) -> String {
        let known = [
            "aac": "AAC", "ac3": "AC3", "eac3": "E-AC3", "dts": "DTS", "truehd": "TrueHD",
            "flac": "FLAC", "alac": "ALAC", "mp3": "MP3", "opus": "Opus", "vorbis": "Vorbis"
        ]
        let key = raw.lowercased()
        if key.hasPrefix("pcm") { return "PCM" }
        return known[key] ?? raw.uppercased()
    }

    private static func channelsLabel(_ n: Int) -> String {
        switch n {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(n) ch"
        }
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

    @objc private func playTapped() { play(startOver: false) }
    @objc private func playFromStartTapped() { play(startOver: true) }

    private func play(startOver: Bool) {
        if item.type == "Audio" {
            AudioQueue.shared.play(items: [item], startAt: 0)
            navigationController?.pushViewController(NowPlayingVC(), animated: true)
            return
        }
        navigationController?.pushViewController(
            VideoPlayerVC(item: item,
                          audioIndex: selectedAudioIndex,
                          subtitle: subtitleChoice,
                          forceTranscode: forceTranscode,
                          // The list's UserData covers a tap before getMediaInfo answers.
                          serverState: serverState,
                          startOver: startOver),
            animated: true
        )
    }

    @objc private func playNextTapped() { AudioQueue.shared.playNext(item) }
    @objc private func addToQueueTapped() { AudioQueue.shared.addToEnd(item) }

    // MARK: - Watched

    @objc private func watchedTapped() {
        guard playedPending == nil else { return }
        if isPlayed {
            setPlayed(false)
            return
        }
        // Jellyfin forgets the resume point of anything marked watched, so ask first.
        let resumeAt = resumePosition
        if resumeAt > 0 {
            confirmMarkWatched(resumeAt: resumeAt)
        } else {
            setPlayed(true)
        }
    }

    private func confirmMarkWatched(resumeAt: Double) {
        let message = "This clears your resume point at \(ItemDetailVC.clock(resumeAt))."
#if IOS6_TARGET
        let sheet = UIActionSheet(title: "Mark as watched? " + message, delegate: self,
                                  cancelButtonTitle: "Cancel", destructiveButtonTitle: "Mark as Watched")
        sheet.tag = 7
        activeActionSheet = sheet
        sheet.show(in: view)
#else
        let alert = UIAlertController(title: "Mark as Watched", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Mark as Watched", style: .destructive) { [weak self] _ in
            self?.setPlayed(true)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
#endif
    }

    // The toggle flips at once and stays disabled until the server answers; it keeps the
    // server's word, or flips back with a message if the request failed.
    private func setPlayed(_ played: Bool) {
        playedPending = played
        forceRebuild()
        let itemId = item.id
        JellyfinAPI.setPlayed(played, itemId: itemId) { [weak self] ok, state in
            // The server dropped the resume point either way. This device's goes too, or
            // ResumeStore would bring it back as a Resume button.
            if ok { ResumeStore.clear(itemId) }
            if let self = self {
                self.playedPending = nil
                if ok {
                    self.markedState = state ?? ServerPlayState(userData: ["Played": NSNumber(value: played)])
                } else if self.view.window != nil {
                    self.showMessage("Couldn't Reach the Server",
                                     "It wasn't marked as \(played ? "watched" : "unwatched"). Try again in a moment.")
                }
                self.forceRebuild()
            }
            // Home's Continue watching and Next up re-read on this, even with this page gone.
            if ok { NotificationCenter.default.post(name: PlaybackReporter.didStopNotification, object: self) }
        }
    }

    private func showMessage(_ title: String, _ message: String) {
#if IOS6_TARGET
        UIAlertView(title: title, message: message, delegate: nil, cancelButtonTitle: "OK").show()
#else
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
#endif
    }

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
        showMessage("No Chromecast found",
                    "Make sure a Chromecast is powered on and joined to the same Wi-Fi network as this device.")
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
        let qualities = availableCastQualities
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

        let start = CastController.shared.savedResumePosition(for: item, kind: kind, server: serverState)
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
            "DeviceId=jellyold-device-01",
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
            "DeviceId=jellyold-device-01",
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
            // Tapping it still offers to delete the copy.
            btn.setTitle("Downloaded \u{2713}", for: .normal)
            btn.backgroundColor = doneColor
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

    // "Original" is a remux: it can't switch to a non-default audio track or paint a
    // subtitle in. A download keeps a text subtitle as a file beside the video instead;
    // a Chromecast has no app to draw one, so a cast paints in any subtitle.
    private var availableDownloadQualities: [DownloadQuality] {
        return qualities(paintsSubtitle: burnedInSubtitleIndex != nil)
    }

    private var availableCastQualities: [DownloadQuality] {
        return qualities(paintsSubtitle: selectedSubtitleIndex != nil)
    }

    private func qualities(paintsSubtitle: Bool) -> [DownloadQuality] {
        let originalOK = !paintsSubtitle
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

    // A download's video: only an image subtitle is painted in, a text one is saved beside it.
    private func streamURL(quality: DownloadQuality) -> URL? {
        return ItemDetailVC.streamURL(itemId: item.id, quality: quality, audioIndex: selectedAudioIndex,
                                      subtitleIndex: burnedInSubtitleIndex, startTime: 0)
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
            "DeviceId=jellyold-device-01",
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
        var textSubtitle: Int?
        if case .drawn(let index)? = subtitleChoice { textSubtitle = index }
        DownloadManager.startDownload(item, url: url.absoluteString, subtitleIndex: textSubtitle)
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
        case 7:
            setPlayed(true)
        default:
            break
        }
    }
}
#endif
