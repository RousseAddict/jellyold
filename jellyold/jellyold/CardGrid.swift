import UIKit

// MARK: - CardGrid
//
// Sizing for the library grids (Libraries, a library's contents, a show's seasons).
// Cards keep roughly the same size on every screen and the column count follows the
// width — 3 posters across a portrait iPhone, 5 in landscape, 7 on a landscape iPad —
// instead of a fixed column count whose cards grow to fill wide screens.
// The cards are Home's ShelfCardCell: picture, then title and year underneath.

struct CardGrid {
    let style: ShelfStyle
    let inset: CGFloat
    let gap: CGFloat
    // A row's cards are never wider than this; a column is added before they would be.
    let maxCardWidth: CGFloat

    // `large`: bigger posters for short lists (a show's seasons): still 2 across a
    // portrait iPhone, as that page always was.
    init(style: ShelfStyle, large: Bool = false) {
        self.style = style
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        inset = pad ? 16 : 8
        gap = pad ? 12 : 8
        switch style {
        case .landscape:
            maxCardWidth = pad ? 260 : 180
        case .poster, .square:
            maxCardWidth = large ? (pad ? 180 : 150) : (pad ? 150 : 120)
        }
    }

    func apply(to layout: UICollectionViewFlowLayout) {
        layout.minimumInteritemSpacing = gap
        // A little more between rows than between columns: each row ends in text.
        layout.minimumLineSpacing = gap + 6
        layout.sectionInset = UIEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
    }

    func cardWidth(in width: CGFloat) -> CGFloat {
        let usable = width - inset * 2
        let columns = max(1, Int(ceil((usable + gap) / (maxCardWidth + gap))))
        return floor((usable - CGFloat(columns - 1) * gap) / CGFloat(columns))
    }

    func imageHeight(in width: CGFloat) -> CGFloat {
        return floor(cardWidth(in: width) * style.imageSize.height / style.imageSize.width)
    }

    func cardSize(in width: CGFloat, hasSubtitle: Bool) -> CGSize {
        return CGSize(width: cardWidth(in: width),
                      height: ShelfCardCell.height(imageHeight: imageHeight(in: width), hasSubtitle: hasSubtitle))
    }

    // Pixels to ask the server for: the widest a card gets on this device, so rotating
    // (which changes the column count and card width) keeps hitting the image cache.
    var imagePixelWidth: Int {
        return Int(maxCardWidth * UIScreen.main.scale)
    }

    // A full-width row (track and playlist lists) inside the same margins.
    func rowWidth(in width: CGFloat) -> CGFloat {
        return width - inset * 2
    }

    // Call from viewWillLayoutSubviews. When the width changed (a rotation), rebuilds the
    // grid for the new column count and puts the card that was at the top of the screen
    // back at the top, instead of leaving the old offset pointing somewhere else.
    // reloadData, not invalidateLayout: a card's picture height is set when it's
    // configured, so the cards already on screen must be configured again.
    func relayout(_ cv: UICollectionView, width: CGFloat, lastWidth: inout CGFloat) {
        guard width != lastWidth else { return }
        let wasLaidOut = lastWidth > 0
        lastWidth = width
        let visibleTop = cv.contentOffset.y + cv.contentInset.top
        // Cells' own frames: the layout itself may already have been invalidated for the
        // new width by the bounds change.
        let anchor = (wasLaidOut && visibleTop > 1)
            ? cv.visibleCells.filter { $0.frame.maxY > visibleTop }.compactMap { cv.indexPath(for: $0) }.min()
            : nil
        cv.reloadData()
        guard let ip = anchor else { return }
        cv.layoutIfNeeded()
        guard let attrs = cv.collectionViewLayout.layoutAttributesForItem(at: ip) else { return }
        let minY = -cv.contentInset.top
        let maxY = max(minY, cv.collectionViewLayout.collectionViewContentSize.height
                                + cv.contentInset.bottom - cv.bounds.height)
        let y = attrs.frame.minY - inset - cv.contentInset.top
        cv.contentOffset = CGPoint(x: 0, y: min(max(minY, y), maxY))
    }
}
