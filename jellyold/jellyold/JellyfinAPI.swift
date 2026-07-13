import Foundation

class JellyfinAPI {

    // MARK: - Auth

    static func login(serverURL: String, username: String, password: String, completion: @escaping (Bool, String?) -> Void) {
        let url = "\(serverURL)/Users/AuthenticateByName"
        let body: [String: Any] = ["Username": username, "Pw": password]
        let headers = [
            "Authorization": "MediaBrowser Client=\"JellyOld\", Device=\"iPhone\", DeviceId=\"jellyold-device-01\", Version=\"1.0\""
        ]
        HTTPClient.post(url: url, headers: headers, body: body) { data, error in
            if let error = error {
                completion(false, error.localizedDescription)
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["AccessToken"] as? String,
                  let userInfo = json["User"] as? [String: Any],
                  let userId = userInfo["Id"] as? String else {
                completion(false, "Invalid response from server. Check the URL and credentials.")
                return
            }
            JellyfinServer.serverURL = serverURL
            JellyfinServer.accessToken = token
            JellyfinServer.userId = userId
            completion(true, nil)
        }
    }

    // MARK: - Media Info (streams + file metadata)

    // Single round trip to /Users/{userId}/Items/{itemId}, used both for the audio/subtitle
    // track pickers (MediaStreams) and the detail page's file-metadata section (size/date/
    // container/codec) — the same response already carries all of it.
    static func getMediaInfo(itemId: String, completion: @escaping ([MediaStream], MediaFileInfo) -> Void) {
        let empty = MediaFileInfo(sizeBytes: nil, dateCreated: nil, container: nil, videoCodec: nil)
        guard let serverURL = JellyfinServer.serverURL,
              let userId = JellyfinServer.userId else { completion([], empty); return }
        let url = "\(serverURL)/Users/\(userId)/Items/\(itemId)"
        HTTPClient.get(url: url, headers: ["Authorization": JellyfinServer.authHeader()]) { data, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion([], empty); return
            }
            let sources = json["MediaSources"] as? [[String: Any]]
            let first = sources?.first
            let streamsJSON = first?["MediaStreams"] as? [[String: Any]] ?? []
            let streams = streamsJSON.compactMap { MediaStream(json: $0) }

            // NSNumber path: numeric `as? Int64` silently fails on the iOS 6 5.1.5 runtime.
            let sizeBytes = (first?["Size"] as? NSNumber)?.int64Value
            let container = (first?["Container"] as? String)?.components(separatedBy: ",").first
            let videoCodec = streamsJSON.first { ($0["Type"] as? String) == "Video" }?["Codec"] as? String
            let dateCreated = (json["DateCreated"] as? String).flatMap(parseServerDate)

            completion(streams, MediaFileInfo(sizeBytes: sizeBytes, dateCreated: dateCreated,
                                               container: container, videoCodec: videoCodec))
        }
    }

    // Jellyfin emits e.g. "2023-05-01T12:34:56.7890000Z" (7-digit fractional seconds, not a
    // standard format DateFormatter can parse directly) — truncate to whole seconds, which is
    // plenty of precision for a "date added" display.
    private static func parseServerDate(_ s: String) -> Date? {
        let datePart = s.components(separatedBy: ".").first ?? s
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: datePart)
    }
}

// MARK: - MediaFileInfo

struct MediaFileInfo {
    let sizeBytes: Int64?
    let dateCreated: Date?
    let container: String?
    let videoCodec: String?
}
