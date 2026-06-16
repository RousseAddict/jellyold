import Foundation

struct MediaItem {
    let id: String
    let name: String
    let type: String
    let year: Int?
    let overview: String?
    let indexNumber: Int?       // episode number within season
    let parentIndexNumber: Int? // season number

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
