import Foundation

// MARK: - DownloadManager
// Persists downloaded videos to Documents/downloads/<id>.mp4 (and a text subtitle chosen
// with it to <id>.srt) and tracks metadata in UserDefaults so they can be replayed
// offline and managed in DownloadsVC.
// Playback resume position reuses VideoPlayerVC's existing "resume_<id>" key
// (UserDefaults), so no separate tracking is needed here.

class DownloadManager {

    private static let defaultsKey = "downloaded_items"

    // Documents/downloads — Documents is NOT auto-purged (unlike Caches), so offline
    // content survives. NSSearchPathForDirectoriesInDomains resolved once (static let).
    private static let dirPath: String = {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        let dir = (docs as NSString).appendingPathComponent("downloads")
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir,
                                                     withIntermediateDirectories: true, attributes: nil)
        }
        return dir
    }()

    static func filePath(for itemId: String) -> String {
        return (dirPath as NSString).appendingPathComponent("\(itemId).mp4")
    }

    // A text subtitle saved with the download, so it shows offline too. Its stream index is
    // kept in the registry entry.
    static func subtitlePath(for itemId: String) -> String {
        return (dirPath as NSString).appendingPathComponent("\(itemId).srt")
    }

    static func subtitleIndex(for itemId: String) -> Int? {
        guard let entry = rawList().first(where: { ($0["id"] as? String) == itemId }),
              let index = (entry["subtitleIndex"] as? NSNumber)?.intValue,
              FileManager.default.fileExists(atPath: subtitlePath(for: itemId)) else { return nil }
        return index
    }

    // The file is present on disk (may be a complete OR partial download).
    static func fileExists(_ itemId: String) -> Bool {
        return FileManager.default.fileExists(atPath: filePath(for: itemId))
    }

    // "Downloaded" = fully finished AND present. Partial downloads are NOT playable
    // offline, so they don't count here.
    static func isDownloaded(_ itemId: String) -> Bool {
        return fileExists(itemId) && isComplete(itemId)
    }

    // Whether the registered download finished. Legacy entries (no flag) = complete.
    static func isComplete(_ itemId: String) -> Bool {
        guard let entry = rawList().first(where: { ($0["id"] as? String) == itemId }) else { return false }
        if let n = entry["complete"] as? NSNumber { return n.boolValue }
        return true
    }

    // Register metadata after a successful download (most-recent first, de-duplicated).
    static func register(_ item: MediaItem) {
        store(item, complete: true)
    }

    // Register a started-but-unfinished download so it shows in DownloadsVC while in
    // progress (and remains visible, flagged incomplete, if it fails midway).
    static func registerPartial(_ item: MediaItem) {
        if isComplete(item.id) { return }   // don't downgrade an already-complete entry
        store(item, complete: false)
    }

    private static func store(_ item: MediaItem, complete: Bool) {
        var list = rawList()
        // Set by the subtitle fetch, which ends long before the video's.
        let subtitleIndex = list.first(where: { ($0["id"] as? String) == item.id })?["subtitleIndex"]
        list.removeAll { ($0["id"] as? String) == item.id }
        var dict = item.toDict()
        dict["complete"] = complete
        if let index = subtitleIndex { dict["subtitleIndex"] = index }
        list.insert(dict, at: 0)
        UserDefaults.standard.set(list, forKey: defaultsKey)
        UserDefaults.standard.synchronize()
    }

    private static func setSubtitleIndex(_ index: Int?, for itemId: String) {
        var list = rawList()
        guard let i = list.firstIndex(where: { ($0["id"] as? String) == itemId }) else { return }
        if let index = index {
            list[i]["subtitleIndex"] = NSNumber(value: index)
        } else {
            list[i].removeValue(forKey: "subtitleIndex")
        }
        UserDefaults.standard.set(list, forKey: defaultsKey)
        UserDefaults.standard.synchronize()
    }

    // Best effort: if it fails the video still downloads, only without its subtitle.
    private static func saveSubtitle(itemId: String, index: Int) {
        guard let url = SubtitleTrack.remoteURL(itemId: itemId, index: index) else { return }
        CurlFetcher.fetchData(url: url, headers: ["Authorization": JellyfinServer.authHeader()]) { data in
            // An error page isn't a subtitle: SRT always has timing arrows.
            guard let data = data, data.range(of: Data("-->".utf8)) != nil,
                  (try? data.write(to: URL(fileURLWithPath: subtitlePath(for: itemId)), options: .atomic)) != nil else {
                DebugLog.shared.log("Subtitles", "saving track \(index) with the download FAILED")
                return
            }
            setSubtitleIndex(index, for: itemId)
        }
    }

    static func remove(_ itemId: String) {
        try? FileManager.default.removeItem(atPath: filePath(for: itemId))
        try? FileManager.default.removeItem(atPath: subtitlePath(for: itemId))
        var list = rawList()
        list.removeAll { ($0["id"] as? String) == itemId }
        UserDefaults.standard.set(list, forKey: defaultsKey)
        UserDefaults.standard.synchronize()
    }

    // MARK: - Download lifecycle (manager-owned, so a transfer survives navigation)

    // id → latest progress 0..1 for an in-flight download. Touched only on the main thread
    // (CurlFetcher dispatches both its progress and completion callbacks to main), so no lock.
    private static var inFlight: [String: Float] = [:]

    static func isDownloading(_ itemId: String) -> Bool { return inFlight[itemId] != nil }
    static func progress(for itemId: String) -> Float { return inFlight[itemId] ?? 0 }

    // Owns the whole transfer + completion. Because the manager (not a VC) holds the
    // completion, the download still registers as complete after you navigate away.
    // No-op if this id is already downloading. `subtitleIndex` is a text track to save
    // beside the video.
    static func startDownload(_ item: MediaItem, url: String, subtitleIndex: Int? = nil) {
        if inFlight[item.id] != nil { return }
        let path = filePath(for: item.id)
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: subtitlePath(for: item.id))
        registerPartial(item)            // visible (flagged incomplete) while in progress
        setSubtitleIndex(nil, for: item.id)   // an earlier, failed attempt may have saved one
        if let index = subtitleIndex { saveSubtitle(itemId: item.id, index: index) }
        inFlight[item.id] = 0
        CurlFetcher.downloadToFile(url: url, outputPath: path, progress: { p in
            inFlight[item.id] = p
        }) { success in
            inFlight[item.id] = nil
            if success { register(item) } // on failure the partial entry remains (Incomplete)
        }
    }

    // All videos whose files still exist on disk (complete OR partial).
    static func all() -> [MediaItem] {
        return rawList().compactMap { MediaItem.from(dict: $0) }
            .filter { fileExists($0.id) }
    }

    // Human-readable file size, e.g. "1.4 GB". Shared with ItemDetailVC's metadata section
    // so the source file's size (before download) formats identically to a downloaded copy.
    static func formatBytes(_ bytes: Double) -> String {
        let gb = bytes / (1024.0 * 1024.0 * 1024.0)
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        let mb = bytes / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mb)
    }

    static func fileSizeText(for itemId: String) -> String {
        let path = filePath(for: itemId)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let bytes = (attrs[.size] as? NSNumber)?.doubleValue else { return "" }
        return formatBytes(bytes)
    }

    private static func rawList() -> [[String: Any]] {
        return (UserDefaults.standard.array(forKey: defaultsKey) as? [[String: Any]]) ?? []
    }
}
