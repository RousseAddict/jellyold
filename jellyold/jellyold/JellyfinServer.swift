import Foundation

struct JellyfinServer {
    private static let defaults = UserDefaults.standard

    static var serverURL: String? {
        get { return defaults.string(forKey: "serverURL") }
        set { defaults.set(newValue, forKey: "serverURL") }
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
