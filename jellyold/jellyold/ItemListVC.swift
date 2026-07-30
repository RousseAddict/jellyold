import UIKit

// MARK: - Sort option

private struct SortOption {
    let title: String
    let sortBy: String
    let sortOrder: String
}

private let sortOptions: [SortOption] = [
    SortOption(title: "Date Added", sortBy: "DateCreated",     sortOrder: "Descending"),
    SortOption(title: "Name",       sortBy: "SortName",        sortOrder: "Ascending"),
    SortOption(title: "Year",       sortBy: "ProductionYear",  sortOrder: "Descending"),
]

#if IOS6_TARGET
private enum SheetKind { case sort, audio }
#endif

// MARK: - ItemListVC

class ItemListVC: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    private let library: Library
    private var collectionView: UICollectionView!
    private var spinner: UIActivityIndicatorView!
    private var emptyLabel: UILabel!
    private var items: [MediaItem] = []
    private let bgColor = UIColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1.0)

    private var currentSortIndex: Int = 0
    private var sortKey: String { "sortIndex_\(library.collectionType.isEmpty ? "default" : library.collectionType)" }

#if IOS6_TARGET
    // UIActionSheet has one delegate callback for every sheet this screen shows,
    // so remember which one is up before decoding its button index.
    private var pendingSheetKind: SheetKind = .sort
    private var pendingAudioIndex: Int = -1
    private var activeActionSheet: UIActionSheet?
#endif

    private var useListDisplay: Bool {
        switch library.collectionType {
        case "musicAlbum", "playlistContent": return true
        default: return false
        }
    }

    private var isSortable: Bool {
        switch library.collectionType {
        case "movies", "tvshows", "music", "": return true
        default: return false
        }
    }

    init(library: Library) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = library.name
        view.backgroundColor = bgColor
        currentSortIndex = UserDefaults.standard.integer(forKey: sortKey)
        if currentSortIndex >= sortOptions.count { currentSortIndex = 0 }
        setupCollectionView()
        setupSpinner()
        setupEmptyLabel()
        if isSortable {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "Sort", style: .plain, target: self, action: #selector(sortTapped)
            )
        }
        fetchItems()
    }

    private func setupCollectionView() {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = bgColor
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(PosterCell.self,  forCellWithReuseIdentifier: "PosterCell")
        collectionView.register(EpisodeCell.self, forCellWithReuseIdentifier: "EpisodeCell")
        // Room for MiniPlayerBar, which floats over the nav controller's view.
        collectionView.contentInset = UIEdgeInsets(top: 0, left: 0,
                                                  bottom: MiniPlayerBar.barHeight, right: 0)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed))
        collectionView.addGestureRecognizer(longPress)
        view.addSubview(collectionView)
    }

    private func setupSpinner() {
        spinner = UIActivityIndicatorView(style: .whiteLarge)
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)
    }

    private func setupEmptyLabel() {
        emptyLabel = UILabel()
        emptyLabel.frame = CGRect(x: 20, y: 0, width: view.bounds.width - 40, height: 60)
        emptyLabel.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        emptyLabel.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        emptyLabel.textColor = UIColor(white: 0.5, alpha: 1.0)
        emptyLabel.textAlignment = .center
        emptyLabel.font = UIFont.systemFont(ofSize: 16)
        emptyLabel.text = "No items found"
        emptyLabel.isHidden = true
        emptyLabel.backgroundColor = .clear
        view.addSubview(emptyLabel)
    }

    // MARK: - Sorting

    @objc private func sortTapped() {
#if IOS6_TARGET
        let sheet = UIActionSheet(
            title: "Sort by",
            delegate: self,
            cancelButtonTitle: "Cancel",
            destructiveButtonTitle: nil
        )
        // Cancel is at index 0; options are added starting at index 1
        for opt in sortOptions { sheet.addButton(withTitle: opt.title) }
        pendingSheetKind = .sort
        activeActionSheet = sheet
        sheet.show(in: view)
#else
        let alert = UIAlertController(title: "Sort by", message: nil, preferredStyle: .actionSheet)
        for (i, opt) in sortOptions.enumerated() {
            alert.addAction(UIAlertAction(title: opt.title, style: .default) { [weak self] _ in
                self?.applySortIndex(i)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
#endif
    }

    func applySortIndex(_ index: Int) {
        currentSortIndex = index
        UserDefaults.standard.set(index, forKey: sortKey)
        fetchItems()
    }

    // MARK: - Fetch

    private func fetchItems() {
        guard let serverURL = JellyfinServer.serverURL,
              let userId = JellyfinServer.userId else { return }

        spinner.startAnimating()
        emptyLabel.isHidden = true

        // Playlist content uses a different API endpoint
        if library.collectionType == "playlistContent" {
            let url = "\(serverURL)/Playlists/\(library.id)/Items?UserId=\(userId)&Fields=Overview,ProductionYear,IndexNumber,Artists,Album&Limit=300"
            HTTPClient.get(url: url, headers: ["Authorization": JellyfinServer.authHeader()]) { [weak self] data, error in
                self?.handleItemsResponse(data: data, error: error)
            }
            return
        }

        var typeFilter = ""
        var recursive = "false"

        switch library.collectionType {
        case "movies":
            typeFilter = "&IncludeItemTypes=Movie"; recursive = "true"
        case "tvshows":
            // No type filter: custom/unmapped content may not be type "Series".
            // Recursive=false shows the top-level items (Series, Folder, or Video)
            // whatever structure Jellyfin built from the files.
            typeFilter = ""; recursive = "false"
        case "music":
            typeFilter = ""
        case "musicArtist":
            typeFilter = "&IncludeItemTypes=MusicAlbum"
        case "musicAlbum":
            typeFilter = "&IncludeItemTypes=Audio"
        case "playlists":
            typeFilter = "&IncludeItemTypes=Playlist"
        case "folder":
            // Generic folder drill-down (e.g. from a tvshows library subfolder)
            typeFilter = ""; recursive = "false"
        default:
            typeFilter = "&IncludeItemTypes=Movie,Series"; recursive = "true"
        }

        let sort = sortOptions[currentSortIndex]
        var sortParams = ""
        if isSortable {
            sortParams = "&SortBy=\(sort.sortBy)&SortOrder=\(sort.sortOrder)"
        } else if library.collectionType == "musicAlbum" {
            sortParams = "&SortBy=IndexNumber&SortOrder=Ascending"
        } else if library.collectionType == "musicArtist" {
            sortParams = "&SortBy=ProductionYear&SortOrder=Descending"
        }

        let url = "\(serverURL)/Users/\(userId)/Items?ParentId=\(library.id)&Recursive=\(recursive)\(typeFilter)\(sortParams)&Fields=Overview,ProductionYear,IndexNumber,Artists,Album&Limit=300"
        HTTPClient.get(url: url, headers: ["Authorization": JellyfinServer.authHeader()]) { [weak self] data, error in
            self?.handleItemsResponse(data: data, error: error)
        }
    }

    private func handleItemsResponse(data: Data?, error: Error?) {
        spinner.stopAnimating()
        if let error = error { showAlert(error.localizedDescription); return }
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let its = json["Items"] as? [[String: Any]] else {
            showAlert("Could not load items."); return
        }
        items = its.compactMap { MediaItem(json: $0) }
        emptyLabel.isHidden = !items.isEmpty
        collectionView.reloadData()
    }

    private func showAlert(_ msg: String) {
#if IOS6_TARGET
        let a = UIAlertView(); a.title = "JellyOld"; a.message = msg; a.addButton(withTitle: "OK"); a.show()
#else
        let alert = UIAlertController(title: "JellyOld", message: msg, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
#endif
    }

    // MARK: - DataSource

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let item = items[indexPath.item]
        if useListDisplay {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "EpisodeCell", for: indexPath) as! EpisodeCell
            configureListCell(cell, item: item)
            return cell
        } else {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "PosterCell", for: indexPath) as! PosterCell
            let imageURL = JellyfinServer.serverURL.map { "\($0)/Items/\(item.id)/Images/Primary?width=300" }
            cell.configure(name: item.name, imageURL: imageURL)
            return cell
        }
    }

    private func configureListCell(_ cell: EpisodeCell, item: MediaItem) {
        switch library.collectionType {
        case "musicAlbum":
            cell.numberLabel.text = item.indexNumber.map { String(format: "%02d", $0) } ?? ""
        case "playlistContent":
            cell.numberLabel.text = item.type
        default:
            cell.numberLabel.text = ""
        }
        cell.titleLabel.text = item.name
        cell.overviewLabel.text = item.overview ?? item.year.map { String($0) } ?? ""
        let imageURL = JellyfinServer.serverURL.map { "\($0)/Items/\(item.id)/Images/Primary?width=320" }
        if let url = imageURL { cell.thumbView.load(url: url) }
    }

    // MARK: - Layout

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        if useListDisplay {
            return CGSize(width: collectionView.bounds.width - 16, height: 90)
        }
        let side = floor((collectionView.bounds.width - 32) / 3)
        return CGSize(width: side, height: side * 1.5)
    }

    // MARK: - Selection

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let item = items[indexPath.item]
        switch item.type {
        case "Series":
            navigationController?.pushViewController(SeasonListVC(series: item), animated: true)
        case "Folder", "CollectionFolder":
            // Drill into generic folders (e.g. custom TV content not parsed as Series)
            let child = Library(id: item.id, name: item.name, collectionType: "folder")
            navigationController?.pushViewController(ItemListVC(library: child), animated: true)
        case "MusicArtist":
            let child = Library(id: item.id, name: item.name, collectionType: "musicArtist")
            navigationController?.pushViewController(ItemListVC(library: child), animated: true)
        case "MusicAlbum":
            let child = Library(id: item.id, name: item.name, collectionType: "musicAlbum")
            navigationController?.pushViewController(ItemListVC(library: child), animated: true)
        case "Playlist":
            let child = Library(id: item.id, name: item.name, collectionType: "playlistContent")
            navigationController?.pushViewController(ItemListVC(library: child), animated: true)
        case "Audio":
            playAudio(at: indexPath.item)
        default:
            navigationController?.pushViewController(ItemDetailVC(item: item), animated: true)
        }
    }

    // MARK: - Audio

    // Queues every Audio item in the loaded page (a playlist can hold videos
    // too, so the queue is built from an Audio-only projection and the tapped
    // row is remapped into it) and starts at the tapped track.
    private func playAudio(at index: Int) {
        var audioItems: [MediaItem] = []
        var start = 0
        for i in 0..<items.count where items[i].type == "Audio" {
            if i == index { start = audioItems.count }
            audioItems.append(items[i])
        }
        guard !audioItems.isEmpty else { return }
        AudioQueue.shared.play(items: audioItems, startAt: start)
        navigationController?.pushViewController(NowPlayingVC(), animated: true)
    }

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began,
              let ip = collectionView.indexPathForItem(at: g.location(in: collectionView)),
              ip.item < items.count,
              items[ip.item].type == "Audio" else { return }
        showAudioSheet(at: ip.item)
    }

    private func showAudioSheet(at index: Int) {
        let item = items[index]
#if IOS6_TARGET
        let sheet = UIActionSheet(title: item.name, delegate: self,
                                  cancelButtonTitle: "Cancel", destructiveButtonTitle: nil)
        // Cancel is at index 0; these are 1...4
        for title in ["Play", "Play Next", "Add to Queue", "Details"] {
            sheet.addButton(withTitle: title)
        }
        pendingSheetKind = .audio
        pendingAudioIndex = index
        activeActionSheet = sheet
        sheet.show(in: view)
#else
        let alert = UIAlertController(title: item.name, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Play", style: .default) { [weak self] _ in
            self?.playAudio(at: index)
        })
        alert.addAction(UIAlertAction(title: "Play Next", style: .default) { _ in
            AudioQueue.shared.playNext(item)
        })
        alert.addAction(UIAlertAction(title: "Add to Queue", style: .default) { _ in
            AudioQueue.shared.addToEnd(item)
        })
        alert.addAction(UIAlertAction(title: "Details", style: .default) { [weak self] _ in
            self?.navigationController?.pushViewController(ItemDetailVC(item: item), animated: true)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
#endif
    }
}

// MARK: - UIActionSheetDelegate (iOS 6/7 only)

#if IOS6_TARGET
extension ItemListVC: UIActionSheetDelegate {
    func actionSheet(_ actionSheet: UIActionSheet, clickedButtonAt buttonIndex: Int) {
        let kind = pendingSheetKind
        activeActionSheet = nil
        guard buttonIndex != actionSheet.cancelButtonIndex else { return }
        let optionIndex = buttonIndex - 1  // cancel occupies index 0
        guard optionIndex >= 0 else { return }
        switch kind {
        case .sort:
            guard optionIndex < sortOptions.count else { return }
            applySortIndex(optionIndex)
        case .audio:
            let index = pendingAudioIndex
            guard index >= 0, index < items.count else { return }
            let item = items[index]
            switch optionIndex {
            case 0: playAudio(at: index)
            case 1: AudioQueue.shared.playNext(item)
            case 2: AudioQueue.shared.addToEnd(item)
            case 3: navigationController?.pushViewController(ItemDetailVC(item: item), animated: true)
            default: break
            }
        }
    }
}
#endif
