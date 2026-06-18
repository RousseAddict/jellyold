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
