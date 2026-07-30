import UIKit

// The audio queue as an editable list. Reorder via the Edit button, swipe to
// delete, tap to jump.
//
// Poll-only, like MiniPlayerBar: AudioPlayer's callbacks are single-slot and
// belong to NowPlayingVC, which is the screen that pushed this one.
class QueueVC: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let bgColor = UIColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1.0)
    private let accentColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)

    private var pollTimer: Timer?
    private var lastCount = -1
    private var lastIndex = -1

    private lazy var tableView: UITableView = {
        let tv = UITableView()
        tv.backgroundColor = bgColor
        tv.separatorColor = UIColor(white: 0.2, alpha: 1)
        tv.dataSource = self
        tv.delegate = self
        return tv
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Queue"
        view.backgroundColor = bgColor
        navigationItem.rightBarButtonItem = editButtonItem
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // The mini bar is visible here (it only hides on NowPlayingVC/VideoPlayerVC).
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0,
                                             bottom: MiniPlayerBar.barHeight, right: 0)
        view.addSubview(tableView)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
        startPolling()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // Reloads only when the queue actually changed (a track finishing advances
    // the index under us), and never mid-edit.
    private func startPolling() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: 0.5, target: QueuePollProxy { [weak self] in
            guard let self = self, !self.tableView.isEditing else { return }
            let q = AudioQueue.shared
            if q.items.count != self.lastCount || q.index != self.lastIndex { self.reload() }
        }, selector: #selector(QueuePollProxy.fire), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func reload() {
        lastCount = AudioQueue.shared.items.count
        lastIndex = AudioQueue.shared.index
        tableView.reloadData()
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView.setEditing(editing, animated: animated)
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return AudioQueue.shared.items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let id = "QueueCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: id)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: id)
        let item = AudioQueue.shared.items[indexPath.row]
        let isCurrent = (indexPath.row == AudioQueue.shared.index)

        cell.backgroundColor = bgColor
        cell.textLabel?.backgroundColor = .clear
        cell.detailTextLabel?.backgroundColor = .clear
        cell.textLabel?.numberOfLines = 2
        cell.textLabel?.font = isCurrent ? UIFont.boldSystemFont(ofSize: 15)
                                         : UIFont.systemFont(ofSize: 15)
        cell.textLabel?.textColor = isCurrent ? accentColor : UIColor(white: 0.95, alpha: 1)
        cell.textLabel?.text = item.name
        cell.detailTextLabel?.font = UIFont.systemFont(ofSize: 12)
        cell.detailTextLabel?.textColor = UIColor(white: 0.55, alpha: 1)
        cell.detailTextLabel?.text = [item.artistText, item.album]
            .compactMap { $0 }.joined(separator: " \u{2022} ")

        let selView = UIView()
        selView.backgroundColor = UIColor(white: 0.15, alpha: 1)
        cell.selectedBackgroundView = selView
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 56
    }

    // MARK: - Reorder / delete

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        AudioQueue.shared.move(from: sourceIndexPath.row, to: destinationIndexPath.row)
        lastIndex = AudioQueue.shared.index
        // The table already shows the new order; only the bold "current" row may
        // be stale, and that repaints on the next reload.
    }

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        return .delete
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        // Removing the playing track makes AudioQueue start whatever slid into
        // its slot, so the bold row moves — reload rather than animate a delete.
        AudioQueue.shared.remove(at: indexPath.row)
        reload()
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        AudioQueue.shared.jump(to: indexPath.row)
        reload()
    }
}

// MARK: - Timer helper (avoids retain cycles with the poll timer on iOS 6)

private class QueuePollProxy: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}
