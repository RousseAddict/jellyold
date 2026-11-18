import Foundation

class JellyfinAPI {

    // MARK: - Auth

    // `serverURL` is the address ServerAddress found. Completion on the main thread, with
    // a message fit for the user when it fails.
    static func login(serverURL: String, username: String, password: String, completion: @escaping (Bool, String?) -> Void) {
        let url = "\(serverURL)/Users/AuthenticateByName"
        let body = (try? JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password],
                                                options: [])) ?? Data()
        let headers = ["Authorization": JellyfinServer.signInHeader(),
                       "Content-Type": "application/json"]
        CurlFetcher.reply(url: url, headers: headers, body: body) { reply in
            if reply.curlCode != 0 {
                DebugLog.shared.log("LOGIN", "sign-in failed: \(reply.curlMessage)")
                completion(false, "The server stopped answering during the sign-in (\(reply.curlMessage)). Try again.")
                return
            }
            if reply.status == 401 {
                DebugLog.shared.log("LOGIN", "sign-in refused: wrong username or password (HTTP 401)")
                completion(false, "Wrong username or password.")
                return
            }
            guard reply.status >= 200, reply.status < 300 else {
                DebugLog.shared.log("LOGIN", "sign-in refused: HTTP \(reply.status)")
                completion(false, "The server refused the sign-in (HTTP \(reply.status)).")
                return
            }
            guard let json = (try? JSONSerialization.jsonObject(with: reply.body, options: [])) as? [String: Any],
                  let token = json["AccessToken"] as? String,
                  let userInfo = json["User"] as? [String: Any],
                  let userId = userInfo["Id"] as? String else {
                DebugLog.shared.log("LOGIN", "sign-in reply unreadable (\(reply.body.count) bytes)")
                completion(false, "The server's reply to the sign-in couldn't be read.")
                return
            }
            JellyfinServer.serverURL = serverURL
            JellyfinServer.accessToken = token
            JellyfinServer.userId = userId
            DebugLog.shared.log("LOGIN", "signed in to \(serverURL) as device \(JellyfinServer.deviceId)")
            completion(true, nil)
        }
    }

    // Ends this install's session on the server, so its token stops working and the
    // device leaves the server's list. Sent in the background: the app signs out
    // locally whatever the answer. Call before JellyfinServer.clear().
    static func logout() {
        guard let serverURL = JellyfinServer.serverURL, JellyfinServer.accessToken != nil else { return }
        CurlFetcher.postReport(url: "\(serverURL)/Sessions/Logout",
                               headers: ["Authorization": JellyfinServer.authHeader()],
                               body: Data()) { ok in
            DebugLog.shared.log("LOGIN", ok ? "server session ended" : "server session not ended (no answer)")
        }
    }

    // MARK: - Libraries + Home rows
    //
    // Completions run on the main thread with either a list or a message fit for
    // EmptyStateView.loadFailed — never both.

    private static let notSignedIn = "This device isn't signed in to a server."
    private static let unreadable = "The server's reply couldn't be read."

    // What a card needs, and only the image types it picks from (ItemImages): without
    // EnableImageTypes every list carries every image tag and parent link, a lot of
    // extra JSON for an A5 to parse. Overview is for the detail page a card opens.
    // UserData (resume point, watched) comes by default on these user-scoped calls.
    private static let cardParams = "Fields=Overview,PrimaryImageAspectRatio,SeriesPrimaryImage"
        + "&EnableImageTypes=Primary,Backdrop,Thumb&ImageTypeLimit=1"

    static func getLibraries(completion: @escaping ([Library]?, String?) -> Void) {
        guard let serverURL = JellyfinServer.serverURL,
              let userId = JellyfinServer.userId else { completion(nil, notSignedIn); return }
        fetchList(url: "\(serverURL)/Users/\(userId)/Views") { rows, error in
            completion(rows?.compactMap { Library(json: $0) }, error)
        }
    }

    // Videos with a resume point, most recently watched first.
    static func getResume(limit: Int, completion: @escaping ([MediaItem]?, String?) -> Void) {
        guard let serverURL = JellyfinServer.serverURL,
              let userId = JellyfinServer.userId else { completion(nil, notSignedIn); return }
        let url = "\(serverURL)/Users/\(userId)/Items/Resume?Limit=\(limit)&MediaTypes=Video"
            + "&EnableTotalRecordCount=false&\(cardParams)"
        fetchItems(url: url, completion: completion)
    }

    // The next unwatched episode of each show in progress. EnableResumable=false leaves
    // out episodes already in Continue watching, so one never shows in both rows.
    static func getNextUp(limit: Int, completion: @escaping ([MediaItem]?, String?) -> Void) {
        guard let serverURL = JellyfinServer.serverURL,
              let userId = JellyfinServer.userId else { completion(nil, notSignedIn); return }
        let url = "\(serverURL)/Shows/NextUp?UserId=\(userId)&Limit=\(limit)&EnableResumable=false"
            + "&EnableTotalRecordCount=false&\(cardParams)"
        fetchItems(url: url, completion: completion)
    }

    // Newest additions to one library. GroupItems folds a batch of new episodes into
    // their series (and tracks into their album), as Jellyfin's own home page does.
    static func getLatest(in library: Library, limit: Int,
                          completion: @escaping ([MediaItem]?, String?) -> Void) {
        guard let serverURL = JellyfinServer.serverURL,
              let userId = JellyfinServer.userId else { completion(nil, notSignedIn); return }
        let url = "\(serverURL)/Users/\(userId)/Items/Latest?ParentId=\(library.id)&Limit=\(limit)"
            + "&GroupItems=true&\(cardParams)"
        fetchItems(url: url, completion: completion)
    }

    private static func fetchItems(url: String, completion: @escaping ([MediaItem]?, String?) -> Void) {
        fetchList(url: url) { rows, error in
            completion(rows?.compactMap { MediaItem(json: $0) }, error)
        }
    }

    // Most list endpoints wrap their rows as {"Items": [...]}, but Items/Latest returns
    // a bare array — accept either shape.
    private static func fetchList(url: String, completion: @escaping ([[String: Any]]?, String?) -> Void) {
        HTTPClient.get(url: url, headers: ["Authorization": JellyfinServer.authHeader()]) { data, error in
            if let error = error { completion(nil, error.localizedDescription); return }
            guard let data = data, let obj = try? JSONSerialization.jsonObject(with: data) else {
                completion(nil, unreadable); return
            }
            if let rows = obj as? [[String: Any]] {
                completion(rows, nil)
            } else if let rows = (obj as? [String: Any])?["Items"] as? [[String: Any]] {
                completion(rows, nil)
            } else {
                completion(nil, unreadable)
            }
        }
    }

    // MARK: - Media Info (streams + file metadata)

    // Single round trip to /Users/{userId}/Items/{itemId}, which carries everything the
    // detail page shows beyond the list item: the full item (overview, every image), the
    // details only this call returns (genres, rating, people), the track pickers'
    // MediaStreams, the file facts and the server's resume point (UserData).
    static func getMediaInfo(itemId: String, completion: @escaping ([MediaStream], MediaFileInfo) -> Void) {
        guard let serverURL = JellyfinServer.serverURL,
              let userId = JellyfinServer.userId else { completion([], MediaFileInfo()); return }
        let url = "\(serverURL)/Users/\(userId)/Items/\(itemId)"
        HTTPClient.get(url: url, headers: ["Authorization": JellyfinServer.authHeader()]) { data, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion([], MediaFileInfo()); return
            }
            let sources = json["MediaSources"] as? [[String: Any]]
            let first = sources?.first
            let streamsJSON = first?["MediaStreams"] as? [[String: Any]] ?? []
            let streams = streamsJSON.compactMap { MediaStream(json: $0) }
            completion(streams, MediaFileInfo(json: json, source: first, streams: streamsJSON))
        }
    }

    // MARK: - Played state

    // Marks an item watched (POST) or unwatched (DELETE), like the check button in
    // Jellyfin's own apps. Either way the server also drops the item's resume point. The
    // reply is the item's new UserData, handed back when it's readable; `ok` is false when
    // the server couldn't be reached or refused.
    static func setPlayed(_ played: Bool, itemId: String,
                          completion: @escaping (_ ok: Bool, _ state: ServerPlayState?) -> Void) {
        guard let serverURL = JellyfinServer.serverURL,
              let userId = JellyfinServer.userId else { completion(false, nil); return }
        let url = "\(serverURL)/Users/\(userId)/PlayedItems/\(itemId)"
        CurlFetcher.sendData(method: played ? "POST" : "DELETE", url: url,
                             headers: ["Authorization": JellyfinServer.authHeader()]) { data in
            guard let data = data else { completion(false, nil); return }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            // Without a Played key ServerPlayState would read "not played" either way.
            completion(true, json?["Played"] != nil ? ServerPlayState(userData: json) : nil)
        }
    }

    // Jellyfin emits e.g. "2023-05-01T12:34:56.7890000Z" (7-digit fractional seconds, not a
    // standard format DateFormatter can parse directly) — truncate to whole seconds, which is
    // plenty of precision for a "date added" display or a last-played comparison.
    static func parseServerDate(_ s: String) -> Date? {
        let datePart = s.components(separatedBy: ".").first ?? s
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: datePart)
    }
}

// MARK: - MediaFileInfo
//
// Every field optional or empty: a failed fetch leaves the detail page with what the
// list item had.

struct MediaFileInfo {
    var item: MediaItem? = nil          // the full item, as the server has it now
    var sizeBytes: Int64? = nil
    var dateCreated: Date? = nil
    var container: String? = nil
    var videoCodec: String? = nil
    var videoWidth: Int? = nil
    var videoHeight: Int? = nil
    var audioCodec: String? = nil       // the default audio track's
    var audioChannels: Int? = nil
    var playState: ServerPlayState? = nil
    var genres: [String] = []
    var officialRating: String? = nil   // "PG-13", "TV-14"
    var communityRating: Double? = nil  // 0...10
    var directors: [String] = []
    var cast: [String] = []             // actors, then an episode's guest stars
}

extension MediaFileInfo {
    // `source` is the first MediaSource, `streams` its MediaStreams.
    // NSNumber path throughout: numeric/Bool `as?` silently fails on the iOS 6 5.1.5 runtime.
    init(json: [String: Any], source: [String: Any]?, streams: [[String: Any]]) {
        item = MediaItem(json: json)
        sizeBytes = (source?["Size"] as? NSNumber)?.int64Value
        container = (source?["Container"] as? String)?.components(separatedBy: ",").first
        dateCreated = (json["DateCreated"] as? String).flatMap(JellyfinAPI.parseServerDate)
        playState = ServerPlayState(userData: json["UserData"] as? [String: Any])

        let video = streams.first { ($0["Type"] as? String) == "Video" }
        videoCodec = video?["Codec"] as? String
        videoWidth = (video?["Width"] as? NSNumber)?.intValue
        videoHeight = (video?["Height"] as? NSNumber)?.intValue
        let audios = streams.filter { ($0["Type"] as? String) == "Audio" }
        let audio = audios.first { ($0["IsDefault"] as? NSNumber)?.boolValue == true } ?? audios.first
        audioCodec = audio?["Codec"] as? String
        audioChannels = (audio?["Channels"] as? NSNumber)?.intValue

        genres = json["Genres"] as? [String] ?? []
        officialRating = json["OfficialRating"] as? String
        communityRating = (json["CommunityRating"] as? NSNumber)?.doubleValue
        let people = json["People"] as? [[String: Any]] ?? []
        directors = people.filter { ($0["Type"] as? String) == "Director" }.compactMap { $0["Name"] as? String }
        cast = people.filter { ($0["Type"] as? String) == "Actor" }.compactMap { $0["Name"] as? String }
            + people.filter { ($0["Type"] as? String) == "GuestStar" }.compactMap { $0["Name"] as? String }
    }
}
