import Foundation

struct JellyfinServer {
    private static let defaults = UserDefaults.standard

    static var serverURL: String? {
        get {
            guard let raw = defaults.string(forKey: "serverURL") else { return nil }
            return normalize(raw)
        }
        set {
            if let v = newValue {
                defaults.set(normalize(v), forKey: "serverURL")
            } else {
                defaults.removeObject(forKey: "serverURL")
            }
        }
    }

    // A host typed without a scheme ("192.168.1.120:8096") builds a URL that
    // NSURL treats as non-hierarchical — `path` and `pathExtension` both come
    // back empty, which silently breaks anything inspecting them (notably the
    // stream proxy's playlist detection). curl itself tolerates it, so the
    // failure only shows up downstream. Normalizing on both read and write
    // also repairs values already stored by an older build.
    private static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        let lower = s.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            s = "http://" + s
        }
        return s
    }
    static var accessToken: String? {
        get { return defaults.string(forKey: "accessToken") }
        set { defaults.set(newValue, forKey: "accessToken") }
    }
    static var userId: String? {
        get { return defaults.string(forKey: "userId") }
        set { defaults.set(newValue, forKey: "userId") }
    }

    static var isConfigured: Bool {
        return serverURL != nil && accessToken != nil && userId != nil
    }

    static func clear() {
        defaults.removeObject(forKey: "serverURL")
        defaults.removeObject(forKey: "accessToken")
        defaults.removeObject(forKey: "userId")
    }

    // One stable identifier per installation, shared by login, streams and
    // progress reports. A single hard-coded ID merges different clients' sessions.
    private static let installationDeviceId = loadDeviceId(from: defaults)

    static func loadDeviceId(from store: UserDefaults) -> String {
        if let saved = store.string(forKey: "jellyoldDeviceId"), !saved.isEmpty { return saved }
        let value = "jellyold-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        store.set(value, forKey: "jellyoldDeviceId")
        return value
    }

    static var deviceId: String { installationDeviceId }

    static func clientHeader() -> String {
        "MediaBrowser Client=\"JellyOld\", Device=\"iOS\", DeviceId=\"\(deviceId)\", Version=\"1.0\""
    }

    static func authHeader() -> String {
        clientHeader() + ", Token=\"\(accessToken ?? "")\""
    }

    // HLS playlists may contain absolute CDN URLs. Never forward the account
    // token to a different origin; normalize default ports and host case.
    static func sameOrigin(_ url: URL, _ server: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              scheme == server.scheme?.lowercased(),
              let host = url.host?.lowercased(), host == server.host?.lowercased() else { return false }
        let defaultPort = scheme == "https" ? 443 : 80
        return (url.port ?? defaultPort) == (server.port ?? defaultPort)
    }
}
