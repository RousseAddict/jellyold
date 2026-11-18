import Foundation

// MARK: - Finding the server from what was typed
//
// The sign-in screen takes the server the way people have it: "192.168.1.10",
// "jellyfin.example.com", "host:8096", or the whole address of a Jellyfin web page copied
// from a browser. Every full address it could mean is asked for Jellyfin's public info
// (no sign-in needed) at once, and the one that answers as Jellyfin is kept, at the
// address it finally answered from, after any redirect (a proxy sending http to https).

enum ServerAddress {

    static let jellyfinHTTPPort = 8096
    static let jellyfinHTTPSPort = 8920

    struct Server {
        let baseURL: String
        let name: String
        let version: String
    }

    // The full addresses `input` could mean, most likely first; empty if it can't be
    // a server address.
    //   host                 http://host:8096, https://host, http://host, https://host:8920
    //   scheme://host        that, then the scheme's Jellyfin port (8096 / 8920)
    //   host:port            http and https on that port
    //   scheme://host:port   only that
    // A path is kept (a server behind a proxy at /jellyfin), except a page of the web
    // app (/web/...), a query and a fragment.
    static func candidates(from input: String) -> [String] {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        for mark in ["#", "?"] {
            let r = s.range(of: mark)
            if r.location != NSNotFound { s = s.substring(to: r.location) as NSString }
        }

        var scheme: String?
        for prefix in ["http://", "https://"] where s.lowercased.hasPrefix(prefix) {
            scheme = prefix == "http://" ? "http" : "https"
            s = s.substring(from: (prefix as NSString).length) as NSString
        }
        guard s.range(of: "://").location == NSNotFound else { return [] }

        let slash = s.range(of: "/")
        let hostPort = slash.location == NSNotFound ? s as String : s.substring(to: slash.location)
        var path = slash.location == NSNotFound ? "" : s.substring(from: slash.location)
        let lowerPath = path.lowercased() as NSString
        let web = lowerPath.range(of: "/web/")
        if web.location != NSNotFound {
            path = (path as NSString).substring(to: web.location)
        } else if lowerPath.hasSuffix("/web") {
            path = (path as NSString).substring(to: lowerPath.length - 4)
        }
        while path.hasSuffix("/") { path = String(path.dropLast()) }
        guard path.range(of: " ") == nil else { return [] }

        var host = hostPort
        var port: Int?
        if hostPort.hasPrefix("[") {
            // An IPv6 address: [fe80::1] or [fe80::1]:8096.
            guard let close = hostPort.range(of: "]") else { return [] }
            host = String(hostPort[..<close.upperBound])
            let rest = hostPort[close.upperBound...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":"), let p = Int(rest.dropFirst()) else { return [] }
                port = p
            }
        } else {
            if let colon = hostPort.range(of: ":") {
                host = String(hostPort[..<colon.lowerBound])
                guard let p = Int(hostPort[colon.upperBound...]) else { return [] }
                port = p
            }
            guard isHostName(host) else { return [] }
        }
        guard host.count > 0 else { return [] }
        if let p = port, p < 1 || p > 65535 { return [] }

        host = host.lowercased()
        func address(_ scheme: String, _ port: Int?) -> String {
            return "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "") + path
        }
        switch (scheme, port) {
        case let (scheme?, port?):
            return [address(scheme, port)]
        case let (scheme?, nil):
            return [address(scheme, nil),
                    address(scheme, scheme == "https" ? jellyfinHTTPSPort : jellyfinHTTPPort)]
        case let (nil, port?):
            return [address("http", port), address("https", port)]
        case (nil, nil):
            return [address("http", jellyfinHTTPPort), address("https", nil),
                    address("http", nil), address("https", jellyfinHTTPSPort)]
        }
    }

    // Letters, digits, dots, hyphens and underscores: a name or an IPv4 address.
    private static func isHostName(_ host: String) -> Bool {
        for c in host.utf8 {
            let ok = (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57)
                || c == 46 || c == 45 || c == 95
            if !ok { return false }
        }
        return true
    }

    // Looks for the server `input` names. Completion on the main thread, with the server
    // or with a message saying what was tried.
    static func find(_ input: String, completion: @escaping (Server?, String?) -> Void) {
        let candidates = self.candidates(from: input)
        guard !candidates.isEmpty else {
            DebugLog.shared.log("LOGIN", "not a server address: \"\(input)\"")
            completion(nil, "\"\(input)\" isn't a server address. Try something like 192.168.1.10 or jellyfin.example.com.")
            return
        }
        Search(candidates: candidates, completion: completion).start()
    }

    // MARK: - Asking one address

    private enum Answer {
        case jellyfin(Server)
        case other(String)      // what happened instead, for the log and the message
    }

    private static let infoPath = "/System/Info/Public"
    // Every address is asked at once; curlQueue would ask them one after another.
    private static let probeQueue = DispatchQueue(label: "com.jellyold.curl.probe", attributes: .concurrent)

    // Off the main thread. Only Jellyfin's own reply counts: JSON with its Version and Id,
    // not just any web server answering on that port.
    private static func ask(_ candidate: String) -> Answer {
        let reply = CurlFetcher.syncReply(url: candidate + infoPath, connectTimeout: 4, timeout: 6)
        guard reply.curlCode == 0 else { return .other(reason(forCurlCode: reply.curlCode)) }
        guard reply.status >= 200, reply.status < 300 else {
            return .other("not Jellyfin (HTTP \(reply.status))")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: reply.body, options: [])) as? [String: Any],
              let version = json["Version"] as? String,
              json["Id"] is String else { return .other("not Jellyfin") }
        return .jellyfin(Server(baseURL: baseURL(answering: reply.finalURL, asked: candidate),
                                name: json["ServerName"] as? String ?? "",
                                version: version))
    }

    // The address that answered, without the info path (or a query a redirect added).
    private static func baseURL(answering finalURL: String, asked: String) -> String {
        var s = finalURL as NSString
        let query = s.range(of: "?")
        if query.location != NSNotFound { s = s.substring(to: query.location) as NSString }
        guard s.lowercased.hasSuffix(infoPath.lowercased()) else { return asked }
        return s.substring(to: s.length - (infoPath as NSString).length)
    }

    private static func reason(forCurlCode code: Int32) -> String {
        switch code {
        case 6: return "address not found"
        case 7: return "refused"
        case 28: return "no answer"
        case 35: return "secure connection failed"
        case 52: return "empty reply"
        default: return "failed (\(String(cString: curl_bridge_strerror(code))))"
        }
    }

    // MARK: - Asking them all

    // The first address to answer as Jellyfin wins, except that https is preferred: an
    // http answer waits up to a second for https addresses still being asked.
    private final class Search {
        private let candidates: [String]
        private let completion: (Server?, String?) -> Void
        private var outcomes: [String?]     // per address; nil while it is still being asked
        private var best: Server?
        private var finished = false
        private var waitingForHTTPS = false
        private let started = CFAbsoluteTimeGetCurrent()

        init(candidates: [String], completion: @escaping (Server?, String?) -> Void) {
            self.candidates = candidates
            self.completion = completion
            outcomes = [String?](repeating: nil, count: candidates.count)
        }

        // The search keeps itself alive through the probes' closures until all are back.
        func start() {
            DebugLog.shared.log("LOGIN", "looking for the server at \(candidates.joined(separator: ", "))")
            for (i, candidate) in candidates.enumerated() {
                ServerAddress.probeQueue.async {
                    let answer = ServerAddress.ask(candidate)
                    DispatchQueue.main.async { self.received(answer, from: i) }
                }
            }
        }

        private var elapsedMs: Int { return Int((CFAbsoluteTimeGetCurrent() - started) * 1000) }

        private func received(_ answer: Answer, from i: Int) {
            switch answer {
            case .jellyfin(let server):
                outcomes[i] = "Jellyfin"
                DebugLog.shared.log("LOGIN", "\(candidates[i]): Jellyfin \(server.version) \"\(server.name)\" "
                    + "at \(server.baseURL), \(elapsedMs) ms")
                // An earlier answer stays, unless this one is https and it wasn't.
                let takesOver = best.map { !isHTTPS($0.baseURL) && isHTTPS(server.baseURL) } ?? true
                if takesOver { best = server }
            case .other(let reason):
                outcomes[i] = reason
                DebugLog.shared.log("LOGIN", "\(candidates[i]): \(reason), \(elapsedMs) ms")
            }
            decide()
        }

        private func decide() {
            guard !finished else { return }
            if let best = best {
                let httpsPending = candidates.indices.contains { outcomes[$0] == nil && isHTTPS(candidates[$0]) }
                if isHTTPS(best.baseURL) || !httpsPending {
                    finish(best)
                } else if !waitingForHTTPS {
                    waitingForHTTPS = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        if let best = self.best { self.finish(best) }
                    }
                }
            } else if !outcomes.contains(where: { $0 == nil }) {
                finished = true
                DebugLog.shared.log("LOGIN", "no Jellyfin server found, \(elapsedMs) ms")
                let tried = candidates.indices.map { "\(candidates[$0]): \(outcomes[$0] ?? "")" }
                completion(nil, "No Jellyfin server answered.\n\n" + tried.joined(separator: "\n"))
            }
        }

        private func finish(_ server: Server) {
            guard !finished else { return }
            finished = true
            DebugLog.shared.log("LOGIN", "using \(server.baseURL), \(elapsedMs) ms")
            completion(server, nil)
        }

        private func isHTTPS(_ address: String) -> Bool {
            return address.hasPrefix("https://")
        }
    }
}
