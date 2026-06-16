import Foundation

struct Library {
    let id: String
    let name: String
    let collectionType: String

    // For JSON parsing (from API)
    init?(json: [String: Any]) {
        guard let id = json["Id"] as? String,
              let name = json["Name"] as? String else { return nil }
        self.id = id
        self.name = name
        self.collectionType = json["CollectionType"] as? String ?? ""
    }

    // For constructing child libraries (music albums, playlist contents)
    init(id: String, name: String, collectionType: String) {
        self.id = id
        self.name = name
        self.collectionType = collectionType
    }
}
