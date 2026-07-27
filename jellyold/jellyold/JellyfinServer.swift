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

    static func authHeader() -> String {
        let token = accessToken ?? ""
        return "MediaBrowser Token=\"\(token)\", Client=\"JellyOld\", Device=\"iPhone\", DeviceId=\"jellyold-device-01\", Version=\"1.0\""
    }
}
