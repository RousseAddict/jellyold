import UIKit

// Server shelves refresh when returning from playback and on foreground.
// The original library browser retains downloads and account controls.
class HomeVC: UITableViewController {
    private var shelves: [[MediaItem]] = [[], []]
    private var messages = ["Loading…", "Loading…"]
    private var failures = [false, false]
    private var generation = 0
    private let bgColor = UIColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Home"
        tableView.backgroundColor = bgColor
        tableView.separatorColor = UIColor(white: 0.22, alpha: 1)
        tableView.rowHeight = 116
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Libraries", style: .plain,
                                                           target: self, action: #selector(libraries))
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .refresh,
                                                          target: self, action: #selector(refreshShelves))
        NotificationCenter.default.addObserver(self, selector: #selector(refreshShelves),
             name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshShelves()
    }

    @objc private func libraries() {
        navigationController?.pushViewController(LibraryListVC(), animated: true)
    }

    @objc private func refreshShelves() {
        guard let server = JellyfinServer.serverURL, let user = JellyfinServer.userId else { return }
        generation += 1
        let requestGeneration = generation
        let paths = ["/Users/\(user)/Items/Resume?Limit=20&MediaTypes=Video&Fields=Overview,RunTimeTicks&EnableUserData=true",
                     "/Shows/NextUp?UserId=\(user)&Limit=20&Fields=Overview,RunTimeTicks&EnableUserData=true"]
        for section in 0..<2 {
            HTTPClient.get(url: server + paths[section], headers: ["Authorization": JellyfinServer.authHeader()]) { [weak self] data, error in
                guard let self = self, self.generation == requestGeneration else { return }
                if error == nil, let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let items = json["Items"] as? [[String: Any]] {
                    self.shelves[section] = items.compactMap { MediaItem(json: $0) }
                    self.messages[section] = section == 0 ? "Nothing to continue watching" : "No next episodes"
                    self.failures[section] = false
                } else {
                    // Keep previously loaded items, but make a failed refresh visible.
                    self.messages[section] = "Couldn’t load. Use Refresh to retry."
                    self.failures[section] = true
                }
                self.tableView.reloadData()
            }
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(1, shelves[section].count)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "Continue Watching" : "Next Up"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        failures[section] && !shelves[section].isEmpty ? messages[section] : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard !shelves[indexPath.section].isEmpty else {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.backgroundColor = bgColor
            cell.textLabel?.backgroundColor = .clear
            cell.textLabel?.textColor = .white
            cell.textLabel?.font = UIFont.systemFont(ofSize: 16)
            cell.textLabel?.text = messages[indexPath.section]
            cell.textLabel?.numberOfLines = 2
            return cell
        }
        let cell = (tableView.dequeueReusableCell(withIdentifier: "HomeItem") as? HomeItemCell)
            ?? HomeItemCell(style: .default, reuseIdentifier: "HomeItem")
        cell.backgroundColor = bgColor
        cell.configure(item: shelves[indexPath.section][indexPath.row])
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !shelves[indexPath.section].isEmpty else { refreshShelves(); return }
        navigationController?.pushViewController(ItemDetailVC(item: shelves[indexPath.section][indexPath.row]), animated: true)
    }
}

private final class HomeItemCell: UITableViewCell {
    private let poster = AsyncImageView()
    private let nameLabel = UILabel()
    private let positionLabel = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        accessoryType = .disclosureIndicator
        poster.contentMode = .scaleAspectFill
        poster.clipsToBounds = true
        nameLabel.font = UIFont.boldSystemFont(ofSize: 17)
        nameLabel.numberOfLines = 2
        nameLabel.textColor = .white
        nameLabel.backgroundColor = .clear
        positionLabel.font = UIFont.systemFont(ofSize: 14)
        positionLabel.textColor = .lightGray
        positionLabel.backgroundColor = .clear
        progress.accessibilityLabel = "Playback progress"
        for view in [poster, nameLabel, positionLabel, progress] as [UIView] { contentView.addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(0, contentView.bounds.width - 104)
        poster.frame = CGRect(x: 12, y: 8, width: 66, height: 96)
        nameLabel.frame = CGRect(x: 92, y: 12, width: width, height: 46)
        positionLabel.frame = CGRect(x: 92, y: 63, width: width, height: 20)
        progress.frame = CGRect(x: 92, y: 94, width: width, height: 9)
    }

    func configure(item: MediaItem) {
        poster.cancel()
        poster.image = nil
        if let server = JellyfinServer.serverURL { poster.load(url: "\(server)/Items/\(item.id)/Images/Primary?width=150") }
        nameLabel.text = [item.seriesName, item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
        let seconds = PlaybackPosition.seconds(ticks: item.playbackPositionTicks ?? 0)
        let duration = item.durationSeconds ?? 0
        positionLabel.text = seconds > 0
            ? "\(Int(seconds / 60)) min" + (duration > 0 ? " of \(Int(duration / 60)) min" : " watched")
            : "Start watching"
        progress.progress = duration > 0 ? Float(min(1, seconds / duration)) : 0
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        poster.cancel()
        poster.image = nil
        nameLabel.text = nil
        positionLabel.text = nil
        progress.progress = 0
    }
}
