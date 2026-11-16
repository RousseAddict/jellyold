import UIKit

// MARK: - Shelf model
//
// One of Home's rows ("shelves"): a title, an optional "See all", and cards that scroll
// sideways. The card sizes leave part of the next card showing at the right edge of a
// 320pt screen, which is what tells you the row scrolls.

enum ShelfStyle {
    case poster      // 2:3 — movies, shows
    case landscape   // 16:9 — libraries, Continue watching, Next up
    case square      // 1:1 — albums, photos, home videos

    var imageSize: CGSize {
        switch self {
        case .poster:    return CGSize(width: 88, height: 132)
        case .landscape: return CGSize(width: 192, height: 108)
        case .square:    return CGSize(width: 112, height: 112)
        }
    }
}

struct ShelfCard {
    let title: String
    let subtitle: String?
    let imageURL: String?
    let progress: Double?      // 0...1, drawn along the image's bottom edge
}

// MARK: - ShelfCell (one row)

final class ShelfCell: UITableViewCell, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    private static let headerHeight: CGFloat = 34
    private static let bottomGap: CGFloat = 12
    private static let sideInset: CGFloat = 12
    private static let cardGap: CGFloat = 8

    static func height(style: ShelfStyle, hasSubtitles: Bool) -> CGFloat {
        return headerHeight + cardHeight(style, hasSubtitles) + bottomGap
    }

    private static func cardHeight(_ style: ShelfStyle, _ hasSubtitles: Bool) -> CGFloat {
        return ShelfCardCell.height(imageHeight: style.imageSize.height, hasSubtitle: hasSubtitles)
    }

    var onSelect: ((Int) -> Void)?
    var onSeeAll: (() -> Void)?
    // Every horizontal scroll, so the page can put the row back where it was when this
    // cell is reused for it later.
    var onScroll: ((CGPoint) -> Void)?

    private let titleLabel = UILabel()
    private let seeAllButton = UIButton(type: .custom)
    private let collectionView: UICollectionView
    private var cards: [ShelfCard] = []
    private var cardStyle: ShelfStyle = .poster
    private var hasSubtitles = false
    private var shelfId: String?
    // Applied once the collection view has its frame, clamped to the new content.
    private var pendingOffset: CGPoint?

    override init(style cellStyle: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = ShelfCell.cardGap      // between columns, when horizontal
        layout.minimumInteritemSpacing = 1000              // one card per column
        layout.sectionInset = UIEdgeInsets(top: 0, left: ShelfCell.sideInset,
                                           bottom: 0, right: ShelfCell.sideInset)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(style: cellStyle, reuseIdentifier: reuseIdentifier)

        let bg = UIColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1.0)
        backgroundColor = bg
        contentView.backgroundColor = bg
        selectionStyle = .none

        titleLabel.backgroundColor = .clear
        titleLabel.textColor = .white
        titleLabel.font = UIFont.boldSystemFont(ofSize: 17)
        contentView.addSubview(titleLabel)

        seeAllButton.setTitle("See all \u{203A}", for: .normal)
        seeAllButton.setTitleColor(EmptyStateView.accent, for: .normal)
        seeAllButton.setTitleColor(UIColor(white: 1, alpha: 0.5), for: .highlighted)
        seeAllButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        seeAllButton.addTarget(self, action: #selector(seeAllTapped), for: .touchUpInside)
        contentView.addSubview(seeAllButton)

        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = true
        // Only the page should answer a status-bar tap; with several scroll views
        // claiming it, iOS scrolls none of them.
        collectionView.scrollsToTop = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(ShelfCardCell.self, forCellWithReuseIdentifier: "Card")
        contentView.addSubview(collectionView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(id: String, title: String, style: ShelfStyle, cards: [ShelfCard],
                   showsSeeAll: Bool, offset: CGPoint) {
        // Rebuilding the page reconfigures the cell already showing this row: leave its
        // scroll position alone then, or a row being swiped would jump back.
        if id != shelfId { pendingOffset = offset }
        shelfId = id
        titleLabel.text = title
        seeAllButton.isHidden = !showsSeeAll
        cardStyle = style
        self.cards = cards
        hasSubtitles = cards.contains { $0.subtitle != nil }
        collectionView.collectionViewLayout.invalidateLayout()
        collectionView.reloadData()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = contentView.bounds.width
        let inset = ShelfCell.sideInset
        let headerH = ShelfCell.headerHeight
        var titleW = w - inset * 2
        if !seeAllButton.isHidden {
            let bw = ceil(seeAllButton.sizeThatFits(CGSize(width: 200, height: headerH)).width) + 12
            seeAllButton.frame = CGRect(x: w - inset - bw + 6, y: 0, width: bw, height: headerH)
            titleW -= bw
        }
        titleLabel.frame = CGRect(x: inset, y: 0, width: titleW, height: headerH)
        collectionView.frame = CGRect(x: 0, y: headerH, width: w,
                                      height: ShelfCell.cardHeight(cardStyle, hasSubtitles))
        if let p = pendingOffset {
            pendingOffset = nil
            let n = CGFloat(cards.count)
            let contentW = inset * 2 + n * cardStyle.imageSize.width + max(0, n - 1) * ShelfCell.cardGap
            let maxX = max(0, contentW - collectionView.bounds.width)
            collectionView.contentOffset = CGPoint(x: min(max(0, p.x), maxX), y: 0)
        }
    }

    @objc private func seeAllTapped() { onSeeAll?() }

    // MARK: Cards

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return cards.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "Card", for: indexPath) as! ShelfCardCell
        cell.configure(cards[indexPath.item], imageHeight: cardStyle.imageSize.height)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        return CGSize(width: cardStyle.imageSize.width, height: ShelfCell.cardHeight(cardStyle, hasSubtitles))
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onSelect?(indexPath.item)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // A reload while reused for another row scrolls before its own offset is applied.
        guard pendingOffset == nil else { return }
        onScroll?(scrollView.contentOffset)
    }
}

// MARK: - ShelfCardCell (one card)
//
// Picture on top, title and an optional second line underneath. Until the picture
// arrives (or when the server has none) the title shows inside the grey box, so a card
// is never just an empty rectangle. Also the card of the library grids (CardGrid).

final class ShelfCardCell: UICollectionViewCell {

    private static let titleGap: CGFloat = 4
    private static let titleHeight: CGFloat = 16
    private static let subtitleHeight: CGFloat = 14

    // Picture plus the text under it; the second line's room is kept for every card of
    // a row or grid once any of them has one, so the cards line up.
    static func height(imageHeight: CGFloat, hasSubtitle: Bool) -> CGFloat {
        return imageHeight + titleGap + titleHeight + (hasSubtitle ? subtitleHeight : 0)
    }

    private let imageBox = UIView()
    private let placeholder = UILabel()
    private let imageView = AsyncImageView()
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private var imageHeight: CGFloat = 0
    private var progress: Double?

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageBox.backgroundColor = UIColor(white: 0.15, alpha: 1)
        imageBox.layer.cornerRadius = 4
        imageBox.clipsToBounds = true
        contentView.addSubview(imageBox)

        placeholder.backgroundColor = .clear
        placeholder.textColor = UIColor(white: 0.5, alpha: 1)
        placeholder.font = UIFont.systemFont(ofSize: 12)
        placeholder.textAlignment = .center
        placeholder.numberOfLines = 3
        imageBox.addSubview(placeholder)

        imageView.backgroundColor = .clear
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageBox.addSubview(imageView)

        progressTrack.backgroundColor = UIColor(white: 0, alpha: 0.6)
        progressFill.backgroundColor = EmptyStateView.accent
        progressTrack.addSubview(progressFill)
        imageBox.addSubview(progressTrack)

        titleLabel.backgroundColor = .clear
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 12)
        contentView.addSubview(titleLabel)

        subtitleLabel.backgroundColor = .clear
        subtitleLabel.textColor = UIColor(white: 0.55, alpha: 1)
        subtitleLabel.font = UIFont.systemFont(ofSize: 11)
        contentView.addSubview(subtitleLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(_ card: ShelfCard, imageHeight: CGFloat) {
        self.imageHeight = imageHeight
        titleLabel.text = card.title
        subtitleLabel.text = card.subtitle
        placeholder.text = card.title
        progress = card.progress
        progressTrack.isHidden = (card.progress ?? 0) <= 0
        if let url = card.imageURL { imageView.load(url: url) } else { imageView.image = nil }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = contentView.bounds.width
        imageBox.frame = CGRect(x: 0, y: 0, width: w, height: imageHeight)
        imageView.frame = imageBox.bounds
        placeholder.frame = imageBox.bounds.insetBy(dx: 6, dy: 6)
        let barH: CGFloat = 3
        progressTrack.frame = CGRect(x: 0, y: imageHeight - barH, width: w, height: barH)
        progressFill.frame = CGRect(x: 0, y: 0, width: floor(w * CGFloat(min(1, max(0, progress ?? 0)))), height: barH)
        let titleY = imageHeight + ShelfCardCell.titleGap
        titleLabel.frame = CGRect(x: 0, y: titleY, width: w, height: ShelfCardCell.titleHeight)
        subtitleLabel.frame = CGRect(x: 0, y: titleY + ShelfCardCell.titleHeight,
                                     width: w, height: ShelfCardCell.subtitleHeight)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.cancel()
        imageView.image = nil
        titleLabel.text = nil
        subtitleLabel.text = nil
        placeholder.text = nil
    }
}
