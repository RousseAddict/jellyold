import UIKit

class LibraryListVC: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    private var collectionView: UICollectionView!
    private var spinner: UIActivityIndicatorView!
    private var libraries: [Library] = []
    private let bgColor = UIColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1.0)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Libraries"
        view.backgroundColor = bgColor
        setupCollectionView()
        setupSpinner()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Logout", style: .plain, target: self, action: #selector(logoutTapped)
        )
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
        view.addSubview(collectionView)
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
        spinner.startAnimating()
        let url = "\(serverURL)/Users/\(userId)/Views"
        HTTPClient.get(url: url, headers: ["Authorization": JellyfinServer.authHeader()]) { [weak self] data, error in
            guard let self = self else { return }
            self.spinner.stopAnimating()
            if let error = error { self.showAlert(error.localizedDescription); return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["Items"] as? [[String: Any]] else {
                self.showAlert("Could not parse library list."); return
            }
            self.libraries = items.compactMap { Library(json: $0) }
            self.collectionView.reloadData()
        }
    }

    @objc private func logoutTapped() {
        JellyfinServer.clear()
        navigationController?.setViewControllers([ServerSetupVC()], animated: true)
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
