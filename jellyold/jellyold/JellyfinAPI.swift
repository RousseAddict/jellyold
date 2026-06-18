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

    // MARK: - Media Streams

    static func getMediaStreams(itemId: String, completion: @escaping ([MediaStream]) -> Void) {
        guard let serverURL = JellyfinServer.serverURL,
              let userId = JellyfinServer.userId else { completion([]); return }
        let url = "\(serverURL)/Users/\(userId)/Items/\(itemId)"
        HTTPClient.get(url: url, headers: ["Authorization": JellyfinServer.authHeader()]) { data, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sources = json["MediaSources"] as? [[String: Any]],
                  let first = sources.first,
                  let streams = first["MediaStreams"] as? [[String: Any]] else {
                completion([]); return
            }
            completion(streams.compactMap { MediaStream(json: $0) })
        }
    }
}
