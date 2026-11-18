import UIKit

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

    // MARK: - This install, as Jellyfin sees it
    //
    // Jellyfin keeps one session per user and device ID: signing in revokes the token
    // of any earlier sign-in with the same ID. Every build before this one sent the same
    // ID, so signing in on the iPad signed the iPhone out. Each install now takes its own
    // at its first sign-in and keeps it across logouts, with its model ("iPad") as the
    // device name. An install still signed in from before keeps the old ID and name,
    // which its token belongs to, until it signs in again.

    private static let sharedDeviceId = "jellyold-device-01"

    static var deviceId: String {
        return defaults.string(forKey: "deviceId") ?? sharedDeviceId
    }

    private static var deviceName: String {
        return defaults.string(forKey: "deviceName") ?? "iPhone"
    }

    // The header for a sign-in, which is when this install takes its own ID and name.
    // Main thread (UIDevice).
    static func signInHeader() -> String {
        if defaults.string(forKey: "deviceId") == nil {
            defaults.set("jellyold-" + NSUUID().uuidString.lowercased(), forKey: "deviceId")
        }
        defaults.set(UIDevice.current.model, forKey: "deviceName")
        return clientHeader(token: nil)
    }

    static func authHeader() -> String {
        return clientHeader(token: accessToken ?? "")
    }

    private static func clientHeader(token: String?) -> String {
        let tokenField = token.map { "Token=\"\($0)\", " } ?? ""
        return "MediaBrowser \(tokenField)Client=\"JellyOld\", Device=\"\(deviceName)\", "
            + "DeviceId=\"\(deviceId)\", Version=\"1.0\""
    }
}
