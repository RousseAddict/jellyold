import Foundation

struct MediaItem {
    let id: String
    let name: String
    let type: String
    let year: Int?
    let overview: String?
    let indexNumber: Int?
    let parentIndexNumber: Int?

    init?(json: [String: Any]) {
        guard let id = json["Id"] as? String,
              let name = json["Name"] as? String else { return nil }
        self.id = id
        self.name = name
        self.type = json["Type"] as? String ?? ""
        self.year = json["ProductionYear"] as? Int
        self.overview = json["Overview"] as? String
        self.indexNumber = json["IndexNumber"] as? Int
        self.parentIndexNumber = json["ParentIndexNumber"] as? Int
    }

    // "S01E02" for episodes, nil otherwise — used by DownloadsVC's row subtitle.
    var episodeLabel: String? {
        guard type == "Episode", let season = parentIndexNumber, let ep = indexNumber else { return nil }
        return String(format: "S%02dE%02d", season, ep)
    }

    // MARK: - Persistence (DownloadManager's offline registry)

    func toDict() -> [String: Any] {
        var d: [String: Any] = ["id": id, "name": name, "type": type]
        if let year = year { d["year"] = year }
        if let idx = indexNumber { d["indexNumber"] = idx }
        if let pIdx = parentIndexNumber { d["parentIndexNumber"] = pIdx }
        return d
    }

    static func from(dict: [String: Any]) -> MediaItem? {
        guard let id = dict["id"] as? String, let name = dict["name"] as? String else { return nil }
        var json: [String: Any] = ["Id": id, "Name": name, "Type": (dict["type"] as? String) ?? ""]
        // NSNumber path: numeric `as? Int` silently fails on the iOS 6 5.1.5 runtime.
        if let year = (dict["year"] as? NSNumber)?.intValue { json["ProductionYear"] = year }
        if let idx = (dict["indexNumber"] as? NSNumber)?.intValue { json["IndexNumber"] = idx }
        if let pIdx = (dict["parentIndexNumber"] as? NSNumber)?.intValue { json["ParentIndexNumber"] = pIdx }
        return MediaItem(json: json)
    }
}

// MARK: - MediaStream

struct MediaStream {
    let index: Int
    let type: String        // "Audio" or "Subtitle"
    let language: String?
    let displayTitle: String
    let isDefault: Bool
    let isExternal: Bool

    var isAudio: Bool    { type == "Audio" }
    var isSubtitle: Bool { type == "Subtitle" }

    init?(json: [String: Any]) {
        guard let index = json["Index"] as? Int,
              let type = json["Type"] as? String,
              (type == "Audio" || type == "Subtitle") else { return nil }
        self.index = index
        self.type = type
        self.language = json["Language"] as? String
        self.displayTitle = json["DisplayTitle"] as? String
            ?? json["Language"] as? String
            ?? "Track \(index)"
        self.isDefault  = json["IsDefault"]  as? Bool ?? false
        self.isExternal = json["IsExternal"] as? Bool ?? false
    }
}
