import UIKit

// MARK: - HomeVC
//
// The first screen: rows of cards that scroll sideways (ShelfCell), one table row each —
// Libraries, Continue watching, Next up, then "Recently added in <library>" for every
// library ItemListVC can browse (Library.hasRecentlyAdded).
//
// A UITableViewController because iOS 6 only supports UIRefreshControl there.
//
// Loading: the library list first, since it decides which rows exist; then every row's
// request at once. They run one after another on CurlFetcher's serial queue, so rows fill
// in top-down, in display order. A row with nothing in it isn't shown, and a row whose
// request fails keeps what it had (nothing, on first load) — one bad library shouldn't
// blank the page. Only a failed library list gets the full-page retry screen.

final class HomeVC: UITableViewController {

    private enum Kind {
        case libraries
        case resume
        case nextUp
        case latest(Library)
    }

    private struct Shelf {
        let id: String
        let kind: Kind
        let title: String
        let style: ShelfStyle
        var items: [MediaItem]
        var libraries: [Library]
    }

    // A shelf with something in it, and its cards (built once per reload, not per layout).
    private struct Row {
        let shelf: Int
        let cards: [ShelfCard]
    }

    private static let rowLimit = 16
    private let bgColor = UIColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1.0)

    private var shelves: [Shelf] = []
    private var rows: [Row] = []
    // Each row's sideways scroll position, by shelf id, so a reused cell can put it back.
    private var offsets: [String: CGPoint] = [:]
    // Bumped by every full load; responses from an older one are dropped.
    private var loadGen = 0
    // Requests of the current full load still out; the refresh control spins until 0.
    private var pending = 0
    private var hasAppeared = false

    private var spinner: UIActivityIndicatorView!
    private lazy var emptyView = EmptyStateView(mark: .folder, title: "No libraries",
                                                body: "This account can't see any libraries yet. A Jellyfin admin can share them with it.")
    private lazy var failedView = EmptyStateView.loadFailed { [weak self] in self?.reload() }

#if IOS6_TARGET
    private var activeActionSheet: UIActionSheet?
#endif

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Home"
        tableView.backgroundColor = bgColor
        tableView.separatorStyle = .none
        tableView.tableFooterView = UIView()
        // Room for MiniPlayerBar, which floats over the nav controller's view.
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: MiniPlayerBar.barHeight, right: 0)
        tableView.scrollIndicatorInsets = tableView.contentInset

        // The spinner sits in the background view so it stays put rather than scrolling.
        let background = UIView(frame: tableView.bounds)
        background.backgroundColor = bgColor
        spinner = UIActivityIndicatorView(style: .whiteLarge)
        spinner.center = CGPoint(x: background.bounds.midX, y: background.bounds.midY)
        spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        spinner.hidesWhenStopped = true
        background.addSubview(spinner)
        tableView.backgroundView = background

        // Inside the table, like the other pages, so iOS 7+'s top inset keeps them under the bar.
        for v in [emptyView, failedView] {
            v.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: tableView.bounds.height)
            tableView.addSubview(v)
        }

        let refresh = UIRefreshControl()
        refresh.tintColor = UIColor(white: 0.6, alpha: 1)
        refresh.addTarget(self, action: #selector(reload), for: .valueChanged)
        refreshControl = refresh

        // Phosphor download-simple and sign-out, white so iOS 6 draws them as-is.
        let downloads = UIBarButtonItem(
            image: UIImage(named: "downloads"), style: .plain, target: self, action: #selector(downloadsTapped)
        )
        downloads.accessibilityLabel = "Downloads"
        navigationItem.leftBarButtonItem = downloads
        let logout = UIBarButtonItem(
            image: UIImage(named: "logout"), style: .plain, target: self, action: #selector(logoutTapped)
        )
        logout.accessibilityLabel = "Log out"
        navigationItem.rightBarButtonItem = logout

        NotificationCenter.default.addObserver(self, selector: #selector(playbackReported),
                                               name: PlaybackReporter.didStopNotification, object: nil)
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Back from the player or a detail page: what's in progress may have changed.
        if hasAppeared { refreshProgressRows() }
        hasAppeared = true
    }

    // MARK: - Loading

    @objc private func reload() {
        loadGen += 1
        let gen = loadGen
        emptyView.isHidden = true
        failedView.isHidden = true
        if shelves.isEmpty { spinner.startAnimating() }
        pending = 1
        JellyfinAPI.getLibraries { [weak self] libraries, error in
            guard let self = self, gen == self.loadGen else { return }
            self.spinner.stopAnimating()
            guard let libraries = libraries else {
                self.finishRequest()
                // A failed pull-to-refresh keeps the page it had; only a blank one gets the retry screen.
                if self.shelves.isEmpty {
                    self.failedView.setText(title: "Couldn't load your libraries",
                                            body: error ?? "The server's reply couldn't be read.")
                    self.failedView.isHidden = false
                }
                return
            }
            self.buildShelves(libraries)
            self.emptyView.isHidden = !libraries.isEmpty
            if !libraries.isEmpty { self.fetchRows(gen: gen) }
            self.finishRequest()
        }
    }

    // Rows already on screen keep their cards until their new ones arrive, so a refresh
    // doesn't flash the page empty.
    private func buildShelves(_ libraries: [Library]) {
        var old: [String: Shelf] = [:]
        for s in shelves { old[s.id] = s }
        var next = [
            Shelf(id: "libraries", kind: .libraries, title: "Libraries", style: .landscape,
                  items: [], libraries: libraries),
            Shelf(id: "resume", kind: .resume, title: "Continue watching", style: .landscape,
                  items: [], libraries: []),
            Shelf(id: "nextup", kind: .nextUp, title: "Next up", style: .landscape,
                  items: [], libraries: [])
        ]
        for lib in libraries where lib.hasRecentlyAdded {
            next.append(Shelf(id: "latest_\(lib.id)", kind: .latest(lib), title: "Recently added in \(lib.name)",
                              style: HomeVC.latestStyle(lib), items: [], libraries: []))
        }
        for i in 1..<next.count {
            if let previous = old[next[i].id] { next[i].items = previous.items }
        }
        shelves = next
        reloadTable()
    }

    private func fetchRows(gen: Int) {
        let limit = HomeVC.rowLimit
        for shelf in shelves {
            let id = shelf.id
            let done: ([MediaItem]?, String?) -> Void = { [weak self] items, error in
                self?.fill(id, items: items, error: error, gen: gen, counted: true)
            }
            switch shelf.kind {
            case .libraries:
                continue
            case .resume:
                pending += 1
                JellyfinAPI.getResume(limit: limit, completion: done)
            case .nextUp:
                pending += 1
                JellyfinAPI.getNextUp(limit: limit, completion: done)
            case .latest(let lib):
                pending += 1
                JellyfinAPI.getLatest(in: lib, limit: limit, completion: done)
            }
        }
    }

    // Continue watching and Next up only: what a playback changes.
    private func refreshProgressRows() {
        guard !shelves.isEmpty else { return }
        let gen = loadGen
        JellyfinAPI.getResume(limit: HomeVC.rowLimit) { [weak self] items, error in
            self?.fill("resume", items: items, error: error, gen: gen, counted: false)
        }
        JellyfinAPI.getNextUp(limit: HomeVC.rowLimit) { [weak self] items, error in
            self?.fill("nextup", items: items, error: error, gen: gen, counted: false)
        }
    }

    @objc private func playbackReported() {
        guard isViewLoaded, view.window != nil else { return }   // viewWillAppear will
        refreshProgressRows()
    }

    private func fill(_ id: String, items: [MediaItem]?, error: String?, gen: Int, counted: Bool) {
        guard gen == loadGen else { return }
        if counted { finishRequest() }
        guard let i = shelves.firstIndex(where: { $0.id == id }) else { return }
        guard let items = items else {
            DebugLog.shared.log("Home", "row \(id) failed: \(error ?? "no reason")")
            return
        }
        shelves[i].items = items
        reloadTable()
    }

    private func finishRequest() {
        pending = max(0, pending - 1)
        if pending == 0 { refreshControl?.endRefreshing() }
    }

    private func reloadTable() {
        var next: [Row] = []
        for i in 0..<shelves.count {
            let cards = makeCards(shelves[i])
            if !cards.isEmpty { next.append(Row(shelf: i, cards: cards)) }
        }
        rows = next
        tableView.reloadData()
    }

    // MARK: - Cards

    private static func latestStyle(_ lib: Library) -> ShelfStyle {
        switch lib.collectionType {
        case "music", "homevideos", "photos": return .square
        default: return .poster   // movies, tvshows, mixed
        }
    }

    private func makeCards(_ shelf: Shelf) -> [ShelfCard] {
        let px = Int(shelf.style.imageSize.width * UIScreen.main.scale)
        switch shelf.kind {
        case .libraries:
            return shelf.libraries.map {
                ShelfCard(title: $0.name, subtitle: nil,
                          imageURL: MediaItem.imageURL(itemId: $0.id, type: "Primary", maxWidth: px),
                          progress: nil)
            }
        case .resume:
            return shelf.items.map { item in
                let isEpisode = item.type == "Episode"
                return ShelfCard(title: isEpisode ? (item.seriesName ?? item.name) : item.name,
                                 subtitle: isEpisode ? HomeVC.episodeLine(item)
                                                     : (HomeVC.timeLeft(item) ?? HomeVC.yearText(item)),
                                 imageURL: item.landscapeImageURL(maxWidth: px),
                                 progress: item.progressFraction)
            }
        case .nextUp:
            return shelf.items.map { item in
                ShelfCard(title: item.seriesName ?? item.name, subtitle: HomeVC.episodeLine(item),
                          imageURL: item.landscapeImageURL(maxWidth: px), progress: nil)
            }
        case .latest:
            return shelf.items.map { item in
                let url = shelf.style == .landscape ? item.landscapeImageURL(maxWidth: px)
                                                    : item.posterImageURL(maxWidth: px)
                switch item.type {
                case "Episode":
                    return ShelfCard(title: item.seriesName ?? item.name, subtitle: item.episodeLabel,
                                     imageURL: url, progress: nil)
                case "MusicAlbum", "Audio":
                    return ShelfCard(title: item.name, subtitle: item.artistText, imageURL: url, progress: nil)
                default:
                    return ShelfCard(title: item.name, subtitle: HomeVC.yearText(item), imageURL: url, progress: nil)
                }
            }
        }
    }

    // "S01E02 · Pilot"
    private static func episodeLine(_ item: MediaItem) -> String {
        guard let label = item.episodeLabel else { return item.name }
        return "\(label) \u{00B7} \(item.name)"
    }

    private static func yearText(_ item: MediaItem) -> String? {
        return item.year.map { String($0) }
    }

    // "42 min left" / "1 h 12 min left"
    private static func timeLeft(_ item: MediaItem) -> String? {
        guard let duration = item.durationSeconds,
              let position = item.playState?.positionSeconds, position > 0, duration > position else { return nil }
        let minutes = Int((duration - position) / 60 + 0.5)
        guard minutes > 0 else { return nil }
        return minutes < 60 ? "\(minutes) min left" : "\(minutes / 60) h \(minutes % 60) min left"
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { return 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let row = rows[indexPath.row]
        return ShelfCell.height(style: shelves[row.shelf].style,
                                hasSubtitles: row.cards.contains { $0.subtitle != nil })
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Shelf") as? ShelfCell
            ?? ShelfCell(style: .default, reuseIdentifier: "Shelf")
        let row = rows[indexPath.row]
        let shelf = shelves[row.shelf]
        let id = shelf.id
        // Looked up by id when tapped, not by index: the rows may have been rebuilt since.
        cell.onSelect = { [weak self] i in self?.open(shelfId: id, index: i) }
        cell.onSeeAll = { [weak self] in self?.seeAll(shelfId: id) }
        cell.onScroll = { [weak self] offset in self?.offsets[id] = offset }
        cell.configure(id: id, title: shelf.title, style: shelf.style, cards: row.cards,
                       showsSeeAll: HomeVC.hasSeeAll(shelf), offset: offsets[id] ?? .zero)
        return cell
    }

    // MARK: - Navigation

    private static func hasSeeAll(_ shelf: Shelf) -> Bool {
        switch shelf.kind {
        case .libraries, .latest: return true
        case .resume, .nextUp:    return false
        }
    }

    private func open(shelfId: String, index: Int) {
        guard let shelf = shelves.first(where: { $0.id == shelfId }) else { return }
        switch shelf.kind {
        case .libraries:
            guard index < shelf.libraries.count else { return }
            navigationController?.pushViewController(ItemListVC(library: shelf.libraries[index]), animated: true)
        case .resume, .nextUp, .latest:
            ItemRouter.open(shelf.items, at: index, from: navigationController)
        }
    }

    private func seeAll(shelfId: String) {
        guard let shelf = shelves.first(where: { $0.id == shelfId }) else { return }
        switch shelf.kind {
        case .libraries:
            navigationController?.pushViewController(LibraryListVC(), animated: true)
        case .latest(let lib):
            // Newest first, as the row was — without overwriting the sort saved for the library.
            navigationController?.pushViewController(ItemListVC(library: lib, sortByDateAdded: true), animated: true)
        case .resume, .nextUp:
            break
        }
    }

    @objc private func downloadsTapped() {
        navigationController?.pushViewController(DownloadsVC(), animated: true)
    }

    // Asks first: the icon is easier to hit by accident than the old "Logout" text, and
    // logging out forgets the server address too, not just the session.
    @objc private func logoutTapped() {
        let message = "You'll need the server address and your password to sign back in."
#if IOS6_TARGET
        let sheet = UIActionSheet(title: "Log out? " + message, delegate: self,
                                  cancelButtonTitle: "Cancel", destructiveButtonTitle: "Log Out")
        activeActionSheet = sheet
        sheet.show(in: view)
#else
        let alert = UIAlertController(title: "Log Out", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Log Out", style: .destructive) { [weak self] _ in
            self?.logout()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
#endif
    }

    private func logout() {
        JellyfinServer.clear()
        navigationController?.setViewControllers([ServerSetupVC()], animated: true)
    }
}

// MARK: - UIActionSheetDelegate (iOS 6/7 only)

#if IOS6_TARGET
extension HomeVC: UIActionSheetDelegate {
    func actionSheet(_ actionSheet: UIActionSheet, clickedButtonAt buttonIndex: Int) {
        defer { activeActionSheet = nil }
        guard buttonIndex == actionSheet.destructiveButtonIndex else { return }
        logout()
    }
}
#endif
