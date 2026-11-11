import UIKit

class LibraryListVC: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    private var collectionView: UICollectionView!
    private var spinner: UIActivityIndicatorView!
    private var libraries: [Library] = []
    private let bgColor = UIColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1.0)

    private lazy var emptyView = EmptyStateView(mark: .folder, title: "No libraries",
                                                body: "This account can't see any libraries yet. A Jellyfin admin can share them with it.")
    private lazy var failedView = EmptyStateView.loadFailed { [weak self] in self?.fetchLibraries() }

#if IOS6_TARGET
    private var activeActionSheet: UIActionSheet?
#endif

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Libraries"
        navigationItem.leftItemsSupplementBackButton = true
        view.backgroundColor = bgColor
        setupCollectionView()
        setupSpinner()
        // Phosphor sign-out and download-simple, white so iOS 6 draws them as-is.
        let logout = UIBarButtonItem(
            image: UIImage(named: "logout"), style: .plain, target: self, action: #selector(logoutTapped)
        )
        logout.accessibilityLabel = "Log out"
        navigationItem.rightBarButtonItem = logout
        let downloads = UIBarButtonItem(
            image: UIImage(named: "downloads"), style: .plain, target: self, action: #selector(downloadsTapped)
        )
        downloads.accessibilityLabel = "Downloads"
        navigationItem.leftBarButtonItem = downloads
        fetchLibraries()
    }

    private func setupCollectionView() {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        layout.sectionInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = bgColor
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(PosterCell.self, forCellWithReuseIdentifier: "PosterCell")
        // Room for MiniPlayerBar, which floats over the nav controller's view.
        collectionView.contentInset = UIEdgeInsets(top: 0, left: 0,
                                                  bottom: MiniPlayerBar.barHeight, right: 0)
        view.addSubview(collectionView)
        for v in [emptyView, failedView] {
            v.frame = CGRect(x: 0, y: 0, width: collectionView.bounds.width, height: collectionView.bounds.height)
            collectionView.addSubview(v)
        }
    }

    private func setupSpinner() {
        spinner = UIActivityIndicatorView(style: .whiteLarge)
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)
    }

    private func fetchLibraries() {
        guard let serverURL = JellyfinServer.serverURL,
              let userId = JellyfinServer.userId else { return }
        emptyView.isHidden = true
        failedView.isHidden = true
        spinner.startAnimating()
        let url = "\(serverURL)/Users/\(userId)/Views"
        HTTPClient.get(url: url, headers: ["Authorization": JellyfinServer.authHeader()]) { [weak self] data, error in
            guard let self = self else { return }
            self.spinner.stopAnimating()
            if let error = error { self.showFailed(error.localizedDescription); return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["Items"] as? [[String: Any]] else {
                self.showFailed("The server's reply couldn't be read."); return
            }
            self.libraries = items.compactMap { Library(json: $0) }
            self.emptyView.isHidden = !self.libraries.isEmpty
            self.collectionView.reloadData()
        }
    }

    // In place of an alert over an empty page: this is the first screen, and the
    // fetch only ran from viewDidLoad, so a server that was down at launch used to
    // leave nothing to do but relaunch.
    private func showFailed(_ message: String) {
        failedView.setText(title: "Couldn't load libraries", body: message)
        failedView.isHidden = false
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

    @objc private func downloadsTapped() {
        navigationController?.pushViewController(DownloadsVC(), animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { libraries.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "PosterCell", for: indexPath) as! PosterCell
        let lib = libraries[indexPath.item]
        cell.configure(name: lib.name, imageURL: JellyfinServer.serverURL.map { "\($0)/Items/\(lib.id)/Images/Primary?width=300" })
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let side = floor((collectionView.bounds.width - 30) / 2)
        return CGSize(width: side, height: side * 1.5)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        navigationController?.pushViewController(ItemListVC(library: libraries[indexPath.item]), animated: true)
    }
}

// MARK: - UIActionSheetDelegate (iOS 6/7 only)

#if IOS6_TARGET
extension LibraryListVC: UIActionSheetDelegate {
    func actionSheet(_ actionSheet: UIActionSheet, clickedButtonAt buttonIndex: Int) {
        defer { activeActionSheet = nil }
        guard buttonIndex == actionSheet.destructiveButtonIndex else { return }
        logout()
    }
}
#endif
