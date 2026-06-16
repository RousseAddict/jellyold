import UIKit

class ItemDetailVC: UIViewController {

    private let item: MediaItem
    private let bgColor = UIColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1.0)
    private let accentColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1.0)
    private var scrollView: UIScrollView!
    private var lastBuiltWidth: CGFloat = 0

    init(item: MediaItem) {
        self.item = item
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = item.name
        view.backgroundColor = bgColor
        scrollView = UIScrollView(frame: view.bounds)
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.backgroundColor = bgColor
        view.addSubview(scrollView)
    }

    // Fires on every layout pass including first appearance in any orientation
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let w = view.bounds.width
        guard w > 0, w != lastBuiltWidth else { return }
        lastBuiltWidth = w
        scrollView.subviews.forEach { $0.removeFromSuperview() }
        buildContent(width: w)
    }

    private func buildContent(width w: CGFloat) {
        let posterW: CGFloat = min(w - 80, 220)
        let posterH: CGFloat = posterW * 1.5
        let posterX = (w - posterW) / 2
        var y: CGFloat = 24

        let poster = AsyncImageView(frame: CGRect(x: posterX, y: y, width: posterW, height: posterH))
        poster.contentMode = .scaleAspectFill
        poster.clipsToBounds = true
        poster.layer.cornerRadius = 8
        poster.backgroundColor = UIColor(white: 0.15, alpha: 1.0)
        if let serverURL = JellyfinServer.serverURL {
            poster.load(url: "\(serverURL)/Items/\(item.id)/Images/Primary?width=400")
        }
        scrollView.addSubview(poster)
        y += posterH + 20

        let titleLabel = UILabel(frame: CGRect(x: 16, y: y, width: w - 32, height: 0))
        titleLabel.text = item.name
        titleLabel.textColor = .white
        titleLabel.backgroundColor = .clear
        titleLabel.font = UIFont.boldSystemFont(ofSize: 22)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.sizeToFit()
        titleLabel.frame = CGRect(x: 16, y: y, width: w - 32, height: titleLabel.frame.height)
        scrollView.addSubview(titleLabel)
        y += titleLabel.frame.height + 6

        if let year = item.year {
            let yearLabel = UILabel(frame: CGRect(x: 16, y: y, width: w - 32, height: 20))
            yearLabel.text = "\(year)  ·  \(item.type)"
            yearLabel.textColor = UIColor.lightGray
            yearLabel.backgroundColor = .clear
            yearLabel.font = UIFont.systemFont(ofSize: 14)
            yearLabel.textAlignment = .center
            scrollView.addSubview(yearLabel)
            y += 28
        }

        if let overview = item.overview, !overview.isEmpty {
            let overviewLabel = UILabel(frame: CGRect(x: 16, y: y, width: w - 32, height: 0))
            overviewLabel.text = overview
            overviewLabel.textColor = UIColor(white: 0.8, alpha: 1.0)
            overviewLabel.backgroundColor = .clear
            overviewLabel.font = UIFont.systemFont(ofSize: 14)
            overviewLabel.numberOfLines = 0
            overviewLabel.sizeToFit()
            overviewLabel.frame = CGRect(x: 16, y: y, width: w - 32, height: overviewLabel.frame.height)
            scrollView.addSubview(overviewLabel)
            y += overviewLabel.frame.height + 24
        } else {
            y += 8
        }

        let playBtn = UIButton(type: .custom)
        playBtn.frame = CGRect(x: 16, y: y, width: w - 32, height: 50)
        playBtn.setTitle("Play", for: .normal)
        playBtn.setTitleColor(.white, for: .normal)
        playBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 18)
        playBtn.backgroundColor = accentColor
        playBtn.layer.cornerRadius = 10
        playBtn.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        scrollView.addSubview(playBtn)
        y += 50 + 30

        scrollView.contentSize = CGSize(width: w, height: y)
    }

    @objc private func playTapped() {
        navigationController?.pushViewController(VideoPlayerVC(item: item), animated: true)
    }
}
