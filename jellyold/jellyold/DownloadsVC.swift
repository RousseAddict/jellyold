import UIKit

// MARK: - DownloadsVC
// Lists locally downloaded videos. Tap to replay offline; swipe or Edit to delete.

class DownloadsVC: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private var items: [MediaItem] = []
    private var sizeText: [String: String] = [:]
    private var incomplete: Set<String> = []
    private var didSetupUI = false
    private var pollTimer: Timer?      // refreshes rows while a download is in flight
    private var wasDownloading = false // so we reload once more when the last download ends

    private let bgColor = UIColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1.0)

    private lazy var tableView: UITableView = {
        let tv = UITableView()
        tv.backgroundColor = bgColor
        tv.separatorColor = UIColor(white: 0.2, alpha: 1)
        tv.dataSource = self
        tv.delegate = self
        return tv
    }()

    private lazy var emptyLabel: UILabel = {
        let l = UILabel()
        l.backgroundColor = .clear
        l.textColor = UIColor(white: 0.5, alpha: 1)
        l.textAlignment = .center
        l.font = UIFont.systemFont(ofSize: 15)
        l.numberOfLines = 2
        l.text = "No downloads yet"
        return l
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Downloads"
        view.backgroundColor = bgColor
        navigationItem.rightBarButtonItem = editButtonItem
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didSetupUI {
            didSetupUI = true
            setupUI()
        }
        reload()
        startPollTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // Poll on .common so it fires during scroll tracking. Reloads only while a download is
    // in flight (and not editing), so a manager-owned download's % updates live.
    private func startPollTimer() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: 0.5, target: DownloadsPollProxy { [weak self] in
            guard let self = self, !self.tableView.isEditing else { return }
            let active = self.items.contains { DownloadManager.isDownloading($0.id) }
            if active || self.wasDownloading { self.reload() }
            self.wasDownloading = active
        }, selector: #selector(DownloadsPollProxy.fire), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func setupUI() {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        let navH: CGFloat = 64
        tableView.frame = CGRect(x: 0, y: 0, width: w, height: h - navH)
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(tableView)
        emptyLabel.frame = CGRect(x: 20, y: 80, width: w - 40, height: 60)
        emptyLabel.autoresizingMask = [.flexibleWidth]
        view.addSubview(emptyLabel)
    }

    private func reload() {
        items = DownloadManager.all()
        sizeText.removeAll()
        incomplete.removeAll()
        for item in items {
            sizeText[item.id] = DownloadManager.fileSizeText(for: item.id)
            if !DownloadManager.isComplete(item.id) { incomplete.insert(item.id) }
        }
        emptyLabel.isHidden = !items.isEmpty
        tableView.reloadData()
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView.setEditing(editing, animated: animated)
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let id = "DownloadCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: id)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: id)
        let item = items[indexPath.row]

        cell.backgroundColor = bgColor
        cell.textLabel?.backgroundColor = .clear
        cell.detailTextLabel?.backgroundColor = .clear
        cell.textLabel?.textColor = UIColor(white: 0.95, alpha: 1)
        cell.textLabel?.numberOfLines = 2
        cell.textLabel?.font = UIFont.systemFont(ofSize: 15)
        cell.detailTextLabel?.font = UIFont.systemFont(ofSize: 12)

        cell.textLabel?.text = item.name
        let isDownloading = DownloadManager.isDownloading(item.id)
        let isPartial = incomplete.contains(item.id)
        let sz = sizeText[item.id] ?? ""
        let status: String
        if isDownloading {
            // Percentage relies on the server reporting a Content-Length, which it won't
            // for a chunked transcode/remux response — fall back to showing bytes-so-far
            // (still updates live) so an unknown-length transfer doesn't look frozen.
            let pct = Int(DownloadManager.progress(for: item.id) * 100)
            status = pct > 0 ? "Downloading \(pct)%" : "Downloading\u{2026}" + (sz.isEmpty ? "" : " \(sz)")
        } else if isPartial {
            status = "Incomplete" + (sz.isEmpty ? "" : " (\(sz))")
        } else {
            status = sz
        }
        cell.detailTextLabel?.textColor = (isDownloading || isPartial)
            ? UIColor(red: 0.95, green: 0.6, blue: 0.2, alpha: 1)   // amber for in-progress / partial
            : UIColor(white: 0.55, alpha: 1)
        cell.detailTextLabel?.text = [item.episodeLabel ?? item.type, status]
            .filter { !$0.isEmpty }.joined(separator: " \u{2022} ")

        let selView = UIView()
        selView.backgroundColor = UIColor(white: 0.15, alpha: 1)
        cell.selectedBackgroundView = selView
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 60
    }

    // MARK: - Delete

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        let item = items[indexPath.row]
        DownloadManager.remove(item.id)
        items.remove(at: indexPath.row)
        sizeText[item.id] = nil
        tableView.deleteRows(at: [indexPath], with: .automatic)
        emptyLabel.isHidden = !items.isEmpty
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = items[indexPath.row]
        guard DownloadManager.isDownloaded(item.id) else { return }
        navigationController?.pushViewController(VideoPlayerVC(item: item), animated: true)
    }
}

// MARK: - Timer helper (avoids retain cycles with the poll timer on iOS 6)

private class DownloadsPollProxy: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}
