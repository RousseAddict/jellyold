import UIKit

// MARK: - SubtitleChoice
//
// How the player shows the subtitle picked on the detail page. A text track (SRT, ASS, VTT,
// mov_text…) is fetched as a file and drawn over the video by the app, so the video can
// stream untouched. An image track (PGS, VobSub) can't become text: the server paints it
// into the picture, which means converting the video.

enum SubtitleChoice {
    case drawn(Int)
    case burnedIn(Int)

    var index: Int {
        switch self {
        case .drawn(let index), .burnedIn(let index): return index
        }
    }
}

// MARK: - SubtitleTrack

struct SubtitleCue {
    let start: Double
    let end: Double
    let text: String
}

final class SubtitleTrack {
    let cues: [SubtitleCue]

    init(cues: [SubtitleCue]) {
        self.cues = cues.sorted { $0.start < $1.start }
    }

    // The text on screen at `time`, nil for none. Cues can overlap (two people talking);
    // those show together, the earlier one on top.
    func text(at time: Double) -> String? {
        // The last cue starting at or before `time`.
        var low = 0, high = cues.count - 1, last = -1
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].start <= time { last = mid; low = mid + 1 } else { high = mid - 1 }
        }
        guard last >= 0 else { return nil }
        var lines: [String] = []
        // An overlapping cue started shortly before; a few back is plenty.
        for i in max(0, last - 8)...last where cues[i].end > time {
            lines.append(cues[i].text)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: Loading

    private static let parseQueue = DispatchQueue(label: "com.jellyold.subtitles")

    // The whole track as SRT, which Jellyfin converts any text track to. The 0 is the start
    // position: cue times count from the start of the file, like the player's clock.
    static func remoteURL(itemId: String, index: Int) -> String? {
        guard let serverURL = JellyfinServer.serverURL else { return nil }
        return "\(serverURL)/Videos/\(itemId)/\(itemId)/Subtitles/\(index)/0/Stream.srt"
    }

    // From the copy saved with a download when there is one, else from the server.
    // Completion on the main thread, nil when it couldn't be fetched or read.
    static func load(itemId: String, index: Int, completion: @escaping (SubtitleTrack?) -> Void) {
        let began = CFAbsoluteTimeGetCurrent()
        // Runs on parseQueue.
        let finish: (Data?, String) -> Void = { data, source in
            let track = data.flatMap(parse)
            let ms = Int((CFAbsoluteTimeGetCurrent() - began) * 1000)
            if let track = track {
                DebugLog.shared.log("Subtitles", "track \(index) from \(source): \(track.cues.count) cues in \(ms) ms")
            } else {
                DebugLog.shared.log("Subtitles", "track \(index) from \(source) FAILED (\(data?.count ?? 0) bytes) after \(ms) ms")
            }
            DispatchQueue.main.async { completion(track) }
        }
        if DownloadManager.subtitleIndex(for: itemId) == index {
            let path = DownloadManager.subtitlePath(for: itemId)
            parseQueue.async { finish(FileManager.default.contents(atPath: path), "download") }
            return
        }
        guard let url = remoteURL(itemId: itemId, index: index) else { completion(nil); return }
        CurlFetcher.fetchData(url: url, headers: ["Authorization": JellyfinServer.authHeader()]) { data in
            parseQueue.async { finish(data, "server") }
        }
    }

    // MARK: Parsing
    //
    // NSString calls only: stepping through a Swift String is far too slow on the A5 with
    // the 5.1.5 runtime.

    // Markup the label can't show: HTML-style tags (<i>, <font size="20"> from mov_text)
    // and ASS override blocks ({\an8}).
    private static let markup = try? NSRegularExpression(pattern: "<[^>]*>|\\{\\\\[^}]*\\}", options: [])
    private static let timeSeparators = CharacterSet(charactersIn: ":,.")
    private static let nonDigits = CharacterSet.decimalDigits.inverted

    static func parse(_ data: Data) -> SubtitleTrack? {
        guard let raw = NSString(data: data, encoding: String.Encoding.utf8.rawValue)
                ?? NSString(data: data, encoding: String.Encoding.isoLatin1.rawValue) else { return nil }
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        text = (text as NSString).replacingOccurrences(of: "\r", with: "\n")
        if let markup = markup {
            text = markup.stringByReplacingMatches(in: text, options: [],
                                                   range: NSRange(location: 0, length: (text as NSString).length),
                                                   withTemplate: "")
        }
        // After the tags, so an escaped "<" can't become one.
        for (from, to) in [("\\N", "\n"), ("\\n", "\n"), ("\\h", " "),
                           ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&amp;", "&")] {
            text = (text as NSString).replacingOccurrences(of: from, with: to)
        }

        // A timing line opens a cue, its text runs to the next blank line. The counter line
        // before a timing line is skipped, even with the blank line before it missing.
        var cues: [SubtitleCue] = []
        var open: OpenCue?
        func close() {
            if let cue = open, !cue.lines.isEmpty {
                cues.append(SubtitleCue(start: cue.start, end: cue.end, text: cue.lines.joined(separator: "\n")))
            }
            open = nil
        }
        for line in (text as NSString).components(separatedBy: "\n") {
            let trimmed = (line as NSString).trimmingCharacters(in: .whitespaces)
            if (trimmed as NSString).range(of: "-->").location != NSNotFound,
               let times = timing(trimmed) {
                if let last = open?.lines.last,
                   (last as NSString).rangeOfCharacter(from: nonDigits).location == NSNotFound {
                    open?.lines.removeLast()
                }
                close()
                open = OpenCue(start: times.start, end: times.end, lines: [])
            } else if trimmed.isEmpty {
                close()
            } else {
                open?.lines.append(trimmed)
            }
        }
        close()
        return cues.isEmpty ? nil : SubtitleTrack(cues: cues)
    }

    private struct OpenCue {
        let start: Double
        let end: Double
        var lines: [String]
    }

    // "00:28:06,123 --> 00:28:08,456", position hints after the end time ignored.
    private static func timing(_ line: String) -> (start: Double, end: Double)? {
        let sides = (line as NSString).components(separatedBy: "-->")
        guard sides.count == 2, let start = seconds(sides[0]), let end = seconds(sides[1]),
              end > start else { return nil }
        return (start, end)
    }

    // "01:02:03,456" or "01:02:03.456"; the hours may be missing.
    private static func seconds(_ field: String) -> Double? {
        let trimmed = (field as NSString).trimmingCharacters(in: .whitespaces)
        let time = (trimmed as NSString).components(separatedBy: " ")[0]
        let parts = (time as NSString).components(separatedBy: timeSeparators)
        guard parts.count == 3 || parts.count == 4 else { return nil }
        let values = parts.map { Double(($0 as NSString).integerValue) }
        // "5" is 500 ms, "05" is 50 ms.
        let digits = (parts[parts.count - 1] as NSString).length
        let fraction = values[values.count - 1] / pow(10, Double(digits))
        let hours = parts.count == 4 ? values[0] : 0
        let minutes = values[values.count - 3]
        return hours * 3600 + minutes * 60 + values[values.count - 2] + fraction
    }
}

// MARK: - SubtitleOverlayView
//
// The current cue near the bottom of the picture, white with a dark outline. It fills its
// host and ignores touches, so taps still reach the player's controls under it. While the
// player's own controls show, it sits just above them.

final class SubtitleOverlayView: UIView {
    private let label = UILabel()
    private var fontSize: CGFloat = 0

    var text: String? {
        didSet { if text != oldValue { render() } }
    }

    // Top of the player's bottom controls in this view, nil while they're faded out.
    private var controlsTop: CGFloat? {
        didSet {
            guard !label.isHidden else { return }      // placed when the next cue renders
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseOut],
                           animations: { self.place() }, completion: nil)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.numberOfLines = 0
        label.backgroundColor = .clear
        label.isHidden = true
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Follows the width: about 19 pt on a phone in landscape, 31–34 pt on an iPad.
        let size = max(15, min(34, (bounds.width * 0.04).rounded()))
        if size != fontSize {
            fontSize = size
            render()
        } else {
            place()
        }
    }

    private func render() {
        guard let text = text, !text.isEmpty, fontSize > 0 else {
            label.attributedText = nil
            label.isHidden = true
            return
        }
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black
        shadow.shadowOffset = CGSize(width: 0, height: 1)
        shadow.shadowBlurRadius = 3
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.boldSystemFont(ofSize: fontSize),
            .foregroundColor: UIColor.white,
            // Negative: outlined and filled, so it reads over a bright scene too.
            .strokeColor: UIColor.black,
            .strokeWidth: -3.0,
            .shadow: shadow,
            .paragraphStyle: paragraph
        ])
        label.isHidden = false
        place()
    }

    private func place() {
        guard !label.isHidden else { return }
        let width = bounds.width * 0.9
        let height = label.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
        var bottom = bounds.height - max(10, bounds.height * 0.06)
        if let top = controlsTop { bottom = min(bottom, top - 8) }
        label.frame = CGRect(x: (bounds.width - width) / 2, y: bottom - height,
                             width: width, height: height)
    }

    // MARK: Keeping clear of the player's controls
    //
    // Neither MPMoviePlayerController nor AVPlayerViewController says when its controls show,
    // so look for them: buttons and sliders inside `playerView` that are on screen in the
    // lower half, each widened to the largest box around it still wholly in that half (the
    // bar behind the buttons). Public view properties only; finding nothing leaves the
    // subtitle where it always sits.

    func keepClear(of playerView: UIView) {
        var found: (top: CGFloat, box: UIView)?
        findControls(in: playerView, root: playerView, found: &found)
        let top = found.map { $0.top.rounded() }
        // A bar sliding in reports a new top every tick; small steps aren't worth a move.
        if let a = top, let b = controlsTop, abs(a - b) < 4 { return }
        if top == nil && controlsTop == nil { return }
        if let f = found {
            DebugLog.shared.log("Subtitles", "controls showing, top \(Int(f.top)) of \(Int(bounds.height)) (\(NSStringFromClass(type(of: f.box))))")
        } else {
            DebugLog.shared.log("Subtitles", "controls hidden")
        }
        controlsTop = top
    }

    private func findControls(in view: UIView, root: UIView, found: inout (top: CGFloat, box: UIView)?) {
        if view === self || view.isHidden || view.alpha < 0.01 { return }
        guard view is UIControl else {
            for sub in view.subviews { findControls(in: sub, root: root, found: &found) }
            return
        }
        let half = bounds.height * 0.5
        var rect = view.convert(view.bounds, to: self)
        guard rect.width > 0, rect.height > 0, rect.intersects(bounds), rect.midY > half else { return }
        var box: UIView = view
        var parent = view.superview
        while let p = parent, p !== root {
            let r = p.convert(p.bounds, to: self)
            if r.minY <= half { break }
            if r.height > 0 { rect = r; box = p }
            parent = p.superview
        }
        if let f = found, f.top <= rect.minY { return }
        found = (rect.minY, box)
    }
}

// MARK: - SubtitleTicker
//
// The timer target that moves the cues along. Timer retains its target, so this stands
// between the timer and the player screen rather than the screen itself.

final class SubtitleTicker: NSObject {
    private let tick: () -> Void
    init(_ tick: @escaping () -> Void) { self.tick = tick }
    @objc func fire() { tick() }
}
