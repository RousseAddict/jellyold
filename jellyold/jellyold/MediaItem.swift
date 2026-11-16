import Foundation

struct MediaItem {
    let id: String
    let name: String
    let type: String
    let year: Int?
    let overview: String?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let artists: [String]?
    let album: String?
    let runTimeTicks: Int64?
    // Series context, for an episode shown outside its season (Home's rows).
    let seriesId: String?
    let seriesName: String?
    // The server's UserData as of when this list loaded: resume point, watched state.
    let playState: ServerPlayState?
    let images: ItemImages

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
        self.artists = json["Artists"] as? [String]
        self.album = json["Album"] as? String
        // NSNumber path: a bare numeric `as? Int64` silently fails on the 5.1.5 runtime.
        self.runTimeTicks = (json["RunTimeTicks"] as? NSNumber)?.int64Value
        self.seriesId = json["SeriesId"] as? String
        self.seriesName = json["SeriesName"] as? String
        self.playState = ServerPlayState(userData: json["UserData"] as? [String: Any])
        self.images = ItemImages(json: json)
    }

    // "S01E02" for episodes, nil otherwise — used by DownloadsVC's row subtitle.
    var episodeLabel: String? {
        guard type == "Episode", let season = parentIndexNumber, let ep = indexNumber else { return nil }
        return String(format: "S%02dE%02d", season, ep)
    }

    // Jellyfin reports durations in 100-nanosecond ticks. This is the only
    // duration the audio player can trust: a FLAC/Opus source is transcoded
    // into a chunked response with no Content-Length, leaving
    // AVPlayerItem.duration indefinite (CMTimeGetSeconds -> NaN).
    var durationSeconds: Double? {
        guard let ticks = runTimeTicks, ticks > 0 else { return nil }
        return Double(ticks) / 10_000_000
    }

    var artistText: String? {
        guard let artists = artists, !artists.isEmpty else { return nil }
        return artists.joined(separator: ", ")
    }

    // 0...1, how far into it the server says this user got — a card's progress bar.
    // Not started, or finished (Jellyfin clears the position), gives 0 or nil: no bar.
    var progressFraction: Double? {
        if let f = playState?.playedFraction { return f }
        guard let duration = durationSeconds, duration > 0,
              let position = playState?.positionSeconds else { return nil }
        return min(1, position / duration)
    }

    // MARK: - Card images
    //
    // Sized for a card (maxWidth in pixels), and only of a picture the server says exists
    // (ItemImages), so a card never asks for a 404.

    static func imageURL(itemId: String, type: String, maxWidth: Int) -> String? {
        guard let serverURL = JellyfinServer.serverURL else { return nil }
        return "\(serverURL)/Items/\(itemId)/Images/\(type)?maxWidth=\(maxWidth)&quality=90"
    }

    // Portrait card. Latest can hand back a lone new episode in place of its series, and
    // an episode's own Primary is a 16:9 still — so it gets the series poster.
    func posterImageURL(maxWidth: Int) -> String? {
        if type == "Episode", let sid = seriesId, images.seriesPrimary {
            return MediaItem.imageURL(itemId: sid, type: "Primary", maxWidth: maxWidth)
        }
        return MediaItem.imageURL(itemId: id, type: "Primary", maxWidth: maxWidth)
    }

    // 16:9 card (Continue watching, Next up). An episode leads with its own still, which is
    // already 16:9, then its series' wide art; anything else with its thumb or backdrop.
    // The poster is the last resort — it gets cropped, but it's never blank.
    func landscapeImageURL(maxWidth: Int) -> String? {
        if type == "Episode" {
            if images.primary { return MediaItem.imageURL(itemId: id, type: "Primary", maxWidth: maxWidth) }
            if let sid = seriesId, images.seriesThumb {
                return MediaItem.imageURL(itemId: sid, type: "Thumb", maxWidth: maxWidth)
            }
            if let pid = images.parentBackdropItemId {
                return MediaItem.imageURL(itemId: pid, type: "Backdrop", maxWidth: maxWidth)
            }
        } else {
            if images.thumb { return MediaItem.imageURL(itemId: id, type: "Thumb", maxWidth: maxWidth) }
            if images.backdrop { return MediaItem.imageURL(itemId: id, type: "Backdrop", maxWidth: maxWidth) }
            if let pid = images.parentThumbItemId {
                return MediaItem.imageURL(itemId: pid, type: "Thumb", maxWidth: maxWidth)
            }
        }
        return posterImageURL(maxWidth: maxWidth)
    }

    // Wide art for a page background: the item's own backdrop, else its parent's (an
    // episode's show). nil when there's neither, and the page keeps its plain background.
    func backdropImageURL(maxWidth: Int) -> String? {
        if images.backdrop { return MediaItem.imageURL(itemId: id, type: "Backdrop", maxWidth: maxWidth) }
        if let pid = images.parentBackdropItemId {
            return MediaItem.imageURL(itemId: pid, type: "Backdrop", maxWidth: maxWidth)
        }
        return nil
    }

    // MARK: - Persistence (DownloadManager's offline registry + the audio queue)
    //
    // Both stores share this round-trip, so every field has to stay
    // optional-with-nil: entries written by an older build (no artists/album/
    // runTimeTicks keys) must still decode. Series, UserData and image fields are
    // deliberately not stored: they are only read from fresh server lists.

    func toDict() -> [String: Any] {
        var d: [String: Any] = ["id": id, "name": name, "type": type]
        if let year = year { d["year"] = year }
        if let idx = indexNumber { d["indexNumber"] = idx }
        if let pIdx = parentIndexNumber { d["parentIndexNumber"] = pIdx }
        if let artists = artists, !artists.isEmpty { d["artists"] = artists }
        if let album = album { d["album"] = album }
        if let ticks = runTimeTicks { d["runTimeTicks"] = NSNumber(value: ticks) }
        return d
    }

    static func from(dict: [String: Any]) -> MediaItem? {
        guard let id = dict["id"] as? String, let name = dict["name"] as? String else { return nil }
        var json: [String: Any] = ["Id": id, "Name": name, "Type": (dict["type"] as? String) ?? ""]
        // NSNumber path: numeric `as? Int` silently fails on the iOS 6 5.1.5 runtime.
        if let year = (dict["year"] as? NSNumber)?.intValue { json["ProductionYear"] = year }
        if let idx = (dict["indexNumber"] as? NSNumber)?.intValue { json["IndexNumber"] = idx }
        if let pIdx = (dict["parentIndexNumber"] as? NSNumber)?.intValue { json["ParentIndexNumber"] = pIdx }
        if let artists = dict["artists"] as? [String] { json["Artists"] = artists }
        if let album = dict["album"] as? String { json["Album"] = album }
        if let ticks = (dict["runTimeTicks"] as? NSNumber)?.int64Value {
            json["RunTimeTicks"] = NSNumber(value: ticks)
        }
        return MediaItem(json: json)
    }
}

// MARK: - ItemImages
//
// Which pictures the server has for an item and its parents. Jellyfin only lists the image
// types a request enables, so this is complete only for lists fetched with
// JellyfinAPI's card parameters (Primary, Backdrop, Thumb); elsewhere it is just sparse.
// Tags are read as String: a null in the JSON arrives as NSNull, which `!= nil` would count.

struct ItemImages {
    let primary: Bool
    let thumb: Bool
    let backdrop: Bool
    let seriesPrimary: Bool
    let seriesThumb: Bool
    let parentThumbItemId: String?
    let parentBackdropItemId: String?
    // width / height of the Primary image, when the server knows it.
    let primaryAspect: Double?

    init(json: [String: Any]) {
        let tags = json["ImageTags"] as? [String: Any] ?? [:]
        primary = tags["Primary"] as? String != nil
        thumb = tags["Thumb"] as? String != nil
        backdrop = !((json["BackdropImageTags"] as? [String])?.isEmpty ?? true)
        seriesPrimary = json["SeriesPrimaryImageTag"] as? String != nil
        seriesThumb = json["SeriesThumbImageTag"] as? String != nil
        parentThumbItemId = json["ParentThumbImageTag"] as? String != nil
            ? json["ParentThumbItemId"] as? String : nil
        let parentBackdrops = json["ParentBackdropImageTags"] as? [String] ?? []
        parentBackdropItemId = parentBackdrops.isEmpty ? nil : json["ParentBackdropItemId"] as? String
        primaryAspect = (json["PrimaryImageAspectRatio"] as? NSNumber)?.doubleValue
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
