import UIKit

// MARK: - EmptyStateView
// A page with nothing to show: a glyph on a faint disc, a title, a line of explanation and an
// optional button — the same screen as oldpipe's, in jellyold's purple. Added full-size to its
// page's table or collection view, so on iOS 7+ the scroll view's own top inset keeps it clear
// of the nav bar; it centres its content in the space above the mini player bar. Starts hidden.
//   .download — Downloads with nothing downloaded
//   .playlist — an empty playlist, or an empty audio queue
//   .folder   — a library, folder or show with nothing in it
//   .offline  — the page's request failed (see loadFailed, which adds Try again)

final class EmptyStateView: UIView {
    enum Mark { case download, playlist, folder, offline }

    static let accent = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)

    private let mark: EmptyStateMarkView
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private var button: UIButton?
    var onButton: (() -> Void)?

    private static let buttonSize = CGSize(width: 200, height: 44)

    init(mark kind: Mark, title: String, body: String, buttonTitle: String? = nil) {
        mark = EmptyStateMarkView(kind)
        super.init(frame: .zero)
        backgroundColor = .clear
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        isHidden = true
        addSubview(mark)

        titleLabel.backgroundColor = .clear
        titleLabel.textColor = UIColor(white: 0.95, alpha: 1)
        titleLabel.font = UIFont.boldSystemFont(ofSize: 20)
        titleLabel.textAlignment = .center
        addSubview(titleLabel)

        bodyLabel.backgroundColor = .clear
        bodyLabel.textColor = UIColor(white: 0.55, alpha: 1)
        bodyLabel.font = UIFont.systemFont(ofSize: 15)
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0
        addSubview(bodyLabel)
        setText(title: title, body: body)

        if let t = buttonTitle {
            let b = UIButton(type: .custom)
            b.layer.cornerRadius = 6   // no clipsToBounds: the layer's own background rounds
            b.backgroundColor = EmptyStateView.accent
            b.setTitle(t, for: .normal)
            b.setTitleColor(.white, for: .normal)
            b.setTitleColor(UIColor(white: 1, alpha: 0.6), for: .highlighted)
            b.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
            b.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
            addSubview(b)
            button = b
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // The screen every page that fetches from the server shows when the fetch fails, so there is
    // always a way to retry short of relaunching the app. The page sets the text per failure.
    static func loadFailed(onRetry: @escaping () -> Void) -> EmptyStateView {
        let v = EmptyStateView(mark: .offline, title: "", body: "", buttonTitle: "Try again")
        v.onButton = onRetry
        return v
    }

    func setText(title: String, body: String) {
        titleLabel.text = title
        bodyLabel.text = body
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        let textW = min(w - 64, 280)
        let markS: CGFloat = 88
        let markGap: CGFloat = 20
        let titleH = ceil(titleLabel.font.lineHeight)
        let bodyH = ceil(bodyLabel.sizeThatFits(CGSize(width: textW, height: .greatestFiniteMagnitude)).height)
        let btn = EmptyStateView.buttonSize
        var total = markS + markGap + titleH + 6 + bodyH
        if button != nil { total += 28 + btn.height }

        // Centred above the mini player bar, then lifted a little: dead centre reads low.
        let avail = bounds.height - MiniPlayerBar.barHeight
        var y = max(16, floor((avail - total) / 2) - 16)
        mark.frame = CGRect(x: floor((w - markS) / 2), y: y, width: markS, height: markS)
        y += markS + markGap
        titleLabel.frame = CGRect(x: floor((w - textW) / 2), y: y, width: textW, height: titleH)
        y += titleH + 6
        bodyLabel.frame = CGRect(x: floor((w - textW) / 2), y: y, width: textW, height: bodyH)
        y += bodyH + 28
        button?.frame = CGRect(x: floor((w - btn.width) / 2), y: y, width: btn.width, height: btn.height)
    }

    @objc private func buttonTapped() { onButton?() }
}

// The glyph in the accent colour on a faint disc, drawn rather than loaded so it needs no image
// asset and stays sharp at any size.
private final class EmptyStateMarkView: UIView {
    private let kind: EmptyStateView.Mark

    init(_ kind: EmptyStateView.Mark) {
        self.kind = kind
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func draw(_ rect: CGRect) {
        let s = min(bounds.width, bounds.height)
        UIColor(white: 1, alpha: 0.06).setFill()
        UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: s, height: s)).fill()
        EmptyStateView.accent.setFill()
        EmptyStateView.accent.setStroke()
        drawGlyph(s)
    }

    // Each mark is a Phosphor icon traced from its 256-unit artboard (the centre lines of the
    // bold weight, stroked 24 wide with round ends and corners), set in the middle half of the
    // disc. The same family as the bundled bar icons.
    private func drawGlyph(_ s: CGFloat) {
        let k = s * 0.5 / 256
        let o = s * 0.25
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { return CGPoint(x: o + x * k, y: o + y * k) }
        let path = UIBezierPath()
        path.lineWidth = 24 * k
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        func line(_ pts: [(CGFloat, CGFloat)]) {
            path.move(to: p(pts[0].0, pts[0].1))
            for q in pts.dropFirst() { path.addLine(to: p(q.0, q.1)) }
        }
        // Degrees, clockwise on screen unless `cw` is false. Each arc is appended as its own
        // subpath, so it is not joined to the previous stroke by a line. Never find the start
        // point with cos and sin of the same angle: the compiler fuses the pair into
        // __sincosf_stret, which iOS 6 lacks, and the app then fails to load at all.
        func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ from: CGFloat, _ to: CGFloat, cw: Bool = true) {
            path.append(UIBezierPath(arcCenter: p(cx, cy), radius: r * k, startAngle: from * .pi / 180,
                                     endAngle: to * .pi / 180, clockwise: cw))
        }
        switch kind {
        case .download:        // download-simple
            line([(128, 144), (128, 32)])
            line([(168, 104), (128, 144), (88, 104)])
            line([(216, 144), (216, 208), (40, 208), (40, 144)])
        case .playlist:        // queue
            line([(40, 64), (216, 64)])
            line([(40, 128), (136, 128)])
            line([(40, 192), (136, 192)])
            line([(240, 160), (176, 200), (176, 120)])
            path.close()
        case .folder:          // folder-simple
            line([(32, 56), (96, 56), (128, 80), (224, 80), (224, 208), (32, 208)])
            path.close()
        case .offline:         // wifi-slash: three rings round (128, 220), cut by the slash
            line([(48, 40), (208, 216)])
            arc(128, 220, 164, -110, -129, cw: false)
            arc(128, 220, 164, -51, -94, cw: false)
            arc(128, 220, 116, -100, -128, cw: false)
            arc(128, 220, 116, -52, -71, cw: false)
            arc(128, 220, 68, -67, -126, cw: false)
            UIBezierPath(ovalIn: CGRect(x: o + 112 * k, y: o + 188 * k, width: 32 * k, height: 32 * k)).fill()
        }
        path.stroke()
    }
}
