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

    // Gets a "Recently added" row on Home. Explicit, like everything keyed on
    // collectionType here: only the kinds ItemListVC can actually browse, so the row's
    // "See all" never lands on an empty page. Playlists and collections have nothing
    // "added"; books, music videos and live TV have no browser in this app.
    var hasRecentlyAdded: Bool {
        switch collectionType {
        case "movies", "tvshows", "music", "homevideos", "photos", "": return true
        default: return false
        }
    }
}
