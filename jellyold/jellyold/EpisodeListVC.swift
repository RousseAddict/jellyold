import UIKit

// MARK: - EpisodeCell

class EpisodeCell: UICollectionViewCell {
    let thumbView = AsyncImageView()
    let numberLabel = UILabel()
    let titleLabel = UILabel()
    let overviewLabel = UILabel()

    override init(frame: CGRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        backgroundColor = UIColor(white: 1.0, alpha: 0.05)
        layer.cornerRadius = 6
        clipsToBounds = true
        thumbView.contentMode = .scaleAspectFill
        thumbView.clipsToBounds = true
        thumbView.backgroundColor = UIColor(white: 0.15, alpha: 1.0)
        contentView.addSubview(thumbView)
        numberLabel.textColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1.0)
        numberLabel.font = UIFont.boldSystemFont(ofSize: 11)
        numberLabel.backgroundColor = .clear
        contentView.addSubview(numberLabel)
        titleLabel.textColor = .white
        titleLabel.font = UIFont.boldSystemFont(ofSize: 13)
        titleLabel.numberOfLines = 1
        titleLabel.backgroundColor = .clear
        contentView.addSubview(titleLabel)
        overviewLabel.textColor = UIColor(white: 0.55, alpha: 1.0)
        overviewLabel.font = UIFont.systemFont(ofSize: 11)
        overviewLabel.numberOfLines = 2
        overviewLabel.backgroundColor = .clear
        contentView.addSubview(overviewLabel)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let thumbW = floor(bounds.height * (16.0 / 9.0))
        let pad: CGFloat = 10
        thumbView.frame = CGRect(x: 0, y: 0, width: thumbW, height: bounds.height)
        let textX = thumbW + pad
        let textW = bounds.width - textX - pad
        numberLabel.frame   = CGRect(x: textX, y: 8,  width: textW, height: 14)
        titleLabel.frame    = CGRect(x: textX, y: 24, width: textW, height: 16)
        overviewLabel.frame = CGRect(x: textX, y: 43, width: textW, height: 30)
    }

    func configure(episode: MediaItem, seasonNumber: Int) {
        let ep = episode.indexNumber.map { "S\(String(format: "%02d", seasonNumber))E\(String(format: "%02d", $0))" } ?? ""
        numberLabel.text = ep
        titleLabel.text = episode.name
        overviewLabel.text = episode.overview
        if let url = JellyfinServer.serverURL.map({ "\($0)/Items/\(episode.id)/Images/Primary?width=320" }) {
            thumbView.load(url: url)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbView.cancel(); thumbView.image = nil
        titleLabel.text = nil; numberLabel.text = nil; overviewLabel.text = nil
    }
}

// MARK: - EpisodeListVC

class EpisodeListVC: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    private let series: MediaItem
    private let season: MediaItem?   // nil = all episodes across all seasons
    private var episodes: [MediaItem] = []
    private var collectionView: UICollectionView!
    private var spinner: UIActivityIndicatorView!
    private let bgColor = UIColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1.0)

    // All episodes for a series (flat, sorted by season then episode)
    init(series: MediaItem) {
        self.series = series
        self.season = nil
        super.init(nibName: nil, bundle: nil)
    }

    // Episodes for a specific season
    init(series: MediaItem, season: MediaItem) {
        self.series = series
        self.season = season
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = season?.name ?? series.name
        view.backgroundColor = bgColor
        setupCollectionView()
        setupSpinner()
        fetchEpisodes()
    }

    private func setupCollectionView() {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = bgColor
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(EpisodeCell.self, forCellWithReuseIdentifier: "EpisodeCell")
        view.addSubview(collectionView)
    }

    private func setupSpinner() {
        spinner = UIActivityIndicatorView(style: .whiteLarge)
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)
    }

    private func fetchEpisodes() {
        guard let serverURL = JellyfinServer.serverURL,
              let userId = JellyfinServer.userId else { return }
        spinner.startAnimating()
        let url: String
        if let season = season {
            // Specific season: fetch direct children of the season
            url = "\(serverURL)/Users/\(userId)/Items?ParentId=\(season.id)&Fields=Overview,IndexNumber,ParentIndexNumber"
        } else {
            // All episodes: use the dedicated Shows endpoint which returns all episodes
            // sorted by season and episode number
            url = "\(serverURL)/Shows/\(series.id)/Episodes?UserId=\(userId)&Fields=Overview,IndexNumber,ParentIndexNumber&Limit=500"
        }
        HTTPClient.get(url: url, headers: ["Authorization": JellyfinServer.authHeader()]) { [weak self] data, error in
            guard let self = self else { return }
            self.spinner.stopAnimating()
            if let error = error { self.showAlert(error.localizedDescription); return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let its = json["Items"] as? [[String: Any]] else {
                self.showAlert("Could not load episodes."); return
            }
            self.episodes = its.compactMap { MediaItem(json: $0) }
            self.collectionView.reloadData()
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

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { episodes.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "EpisodeCell", for: indexPath) as! EpisodeCell
        let ep = episodes[indexPath.item]
        // Use parentIndexNumber (season number) from each episode when showing all seasons
        let seasonNum = season?.indexNumber ?? ep.parentIndexNumber ?? 1
        cell.configure(episode: ep, seasonNumber: seasonNum)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        return CGSize(width: collectionView.bounds.width - 16, height: 90)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        navigationController?.pushViewController(ItemDetailVC(item: episodes[indexPath.item]), animated: true)
    }
}
