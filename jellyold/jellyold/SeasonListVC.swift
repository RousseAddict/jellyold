import UIKit

class SeasonListVC: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    private let series: MediaItem
    private var seasons: [MediaItem] = []
    private var collectionView: UICollectionView!
    private var spinner: UIActivityIndicatorView!
    private let bgColor = UIColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1.0)

    // Two-flag approach: the skip can only fire once BOTH data is ready AND view has appeared
    private var pendingSingleSeason: MediaItem?
    private var viewHasAppeared = false

    init(series: MediaItem) {
        self.series = series
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = series.name
        view.backgroundColor = bgColor
        setupCollectionView()
        setupSpinner()
        fetchSeasons()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        viewHasAppeared = true
        trySkipIfSingleSeason()  // fires if data arrived before viewDidAppear
    }

    // Called from both the fetch callback and viewDidAppear — safe to call multiple times
    private func trySkipIfSingleSeason() {
        guard viewHasAppeared, let season = pendingSingleSeason else { return }
        pendingSingleSeason = nil
        guard let nav = navigationController else { return }
        var stack = nav.viewControllers
        stack[stack.count - 1] = EpisodeListVC(series: series, season: season)
        nav.setViewControllers(stack, animated: false)
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

    private func fetchSeasons() {
        guard let serverURL = JellyfinServer.serverURL,
              let userId = JellyfinServer.userId else { return }
        spinner.startAnimating()
        let url = "\(serverURL)/Users/\(userId)/Items?ParentId=\(series.id)&Fields=Overview,IndexNumber"
        HTTPClient.get(url: url, headers: ["Authorization": JellyfinServer.authHeader()]) { [weak self] data, error in
            guard let self = self else { return }
            self.spinner.stopAnimating()
            if let error = error { self.showAlert(error.localizedDescription); return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["Items"] as? [[String: Any]] else {
                self.showAlert("Could not parse seasons."); return
            }
            self.seasons = items.compactMap { MediaItem(json: $0) }
            if self.seasons.count == 1 {
                self.pendingSingleSeason = self.seasons[0]
                self.trySkipIfSingleSeason()  // fires if viewDidAppear already ran
            } else {
                self.collectionView.reloadData()
            }
        }
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

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { seasons.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "PosterCell", for: indexPath) as! PosterCell
        let season = seasons[indexPath.item]
        cell.configure(name: season.name, imageURL: JellyfinServer.serverURL.map { "\($0)/Items/\(season.id)/Images/Primary?width=300" })
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let side = floor((collectionView.bounds.width - 30) / 2)
        return CGSize(width: side, height: side * 1.5)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        navigationController?.pushViewController(EpisodeListVC(series: series, season: seasons[indexPath.item]), animated: true)
    }
}
