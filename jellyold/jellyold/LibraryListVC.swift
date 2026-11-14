import UIKit

class LibraryListVC: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    private var collectionView: UICollectionView!
    private var spinner: UIActivityIndicatorView!
    private var libraries: [Library] = []
    private let bgColor = UIColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1.0)

    private lazy var emptyView = EmptyStateView(mark: .folder, title: "No libraries",
                                                body: "This account can't see any libraries yet. A Jellyfin admin can share them with it.")
    private lazy var failedView = EmptyStateView.loadFailed { [weak self] in self?.fetchLibraries() }

    // Every library as a grid — HomeVC's "Libraries — See all". Downloads and Log out
    // live on Home, so this page keeps the back button.
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Libraries"
        view.backgroundColor = bgColor
        setupCollectionView()
        setupSpinner()
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
        emptyView.isHidden = true
        failedView.isHidden = true
        spinner.startAnimating()
        JellyfinAPI.getLibraries { [weak self] libraries, error in
            guard let self = self else { return }
            self.spinner.stopAnimating()
            guard let libraries = libraries else {
                self.showFailed(error ?? "The server's reply couldn't be read."); return
            }
            self.libraries = libraries
            self.emptyView.isHidden = !self.libraries.isEmpty
            self.collectionView.reloadData()
        }
    }

    // In place of an alert over an empty page, so there's always a way to retry.
    private func showFailed(_ message: String) {
        failedView.setText(title: "Couldn't load libraries", body: message)
        failedView.isHidden = false
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
