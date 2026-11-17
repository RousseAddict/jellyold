import Foundation
import Darwin

// Local loopback HTTP server that fronts Jellyfin playback (HLS video and
// direct audio streams alike) so MPMoviePlayerController/AVPlayer never talk
// TLS directly.
//
// Neither player backend can be pointed at libcurl: MPMoviePlayerController
// has no networking delegate hook at all, and AVPlayer's resource-loader
// delegate only intercepts custom URL schemes, not plain http(s). Routing
// playback through a local plain-HTTP server sidesteps both — the player
// only ever talks unencrypted HTTP to 127.0.0.1, while every real fetch to
// the Jellyfin server goes through libcurl + embedded OpenSSL, which — unlike
// iOS 6/7 Secure Transport — negotiates GCM-only TLS cipher suites correctly.
//
// Segments and direct audio streams are relayed as bytes arrive from curl's
// write callback straight to the client socket (true streaming — nothing
// buffered to RAM/disk; the blocking send() gives natural backpressure).
// Master/variant playlists are the one exception: they're fetched whole via
// CurlFetcher, scanned for URIs the player can't resolve through the proxy by
// itself, rewritten where needed, then sent.
//
// A playlist is served under a directory of its own, /<id>/<file name>, so
// the player resolves its relative URIs (all of Jellyfin's) to
// /<id>/<same relative path>; mirroredRoute() maps those back against the
// playlist's remote URL. Only absolute, rooted or "../" URIs get a route each.
//
// Each accepted connection runs on its own raw NSThread (not a GCD queue) —
// a connection blocks synchronously inside curl_easy_perform for the whole
// transfer, which can be many seconds for a video segment; a limited-width
// concurrent GCD queue would stall once the player opens several connections
// at once.
final class LocalStreamProxy: NSObject {
    private var listenSocket: Int32 = -1
    private var port: UInt16 = 0
    private var started = false

    private let lock = NSLock()
    private var routes: [String: URL] = [:]
    // A playlist's id -> its remote URL, for the URIs the player resolves under /<id>/.
    private var bases: [String: URL] = [:]
    private var nextID = 0
    private var currentGen: UInt64 = 0

    // Starts the server (if not already running) and registers `remoteURL`
    // as a route. Returns the local URL to hand to the player, or nil if the
    // loopback socket couldn't be created — the caller should fall back to
    // the direct remote URL in that case. Bumps the generation counter so
    // any connections still serving a previous stream get cancelled.
    //
    // `extHint` supplies the extension to advertise when the remote URL has
    // none of its own. The default for that case is "ts", which is right for
    // HLS segments but an actively wrong type hint for anything else — e.g.
    // Jellyfin's audio endpoint (/Audio/{id}/universal) has no extension, and
    // serving an mp3 from /1.ts stops the player dead.
    func start(remoteURL: URL, extHint: String? = nil) -> URL? {
        lock.lock()
        currentGen += 1
        let gen = currentGen
        lock.unlock()
        guard ensureStarted() else {
            DebugLog.shared.log("Proxy", "start FAILED (socket unavailable) — caller will use the direct URL, TLS unprotected")
            return nil
        }
        let path = registerPath(for: remoteURL, isPlaylist: LocalStreamProxy.isPlaylistURL(remoteURL),
                                gen: gen, extHint: extHint)
        DebugLog.shared.log("Proxy", "start gen=\(gen) \(path) -> \(DebugLog.redact(remoteURL.absoluteString))")
        return URL(string: "http://127.0.0.1:\(port)\(path)")
    }

    func stop() {
        lock.lock()
        guard started else { lock.unlock(); return }
        DebugLog.shared.log("Proxy", "stop (gen \(currentGen) -> \(currentGen + 1)), \(routes.count) route(s) dropped")
        started = false
        currentGen += 1
        let fd = listenSocket
        listenSocket = -1
        routes.removeAll()
        bases.removeAll()
        lock.unlock()
        if fd >= 0 { close(fd) }
    }

    fileprivate func isSuperseded(_ gen: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gen < currentGen
    }

    // MARK: - Socket setup

    private func ensureStarted() -> Bool {
        lock.lock()
        if started { lock.unlock(); return true }
        lock.unlock()

        CurlFetcher.ensureGlobalInit()
        signal(SIGPIPE, SIG_IGN) // a send() to a socket the player already closed must not kill the process

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0 // let the OS assign an ephemeral port

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            DebugLog.shared.log("Proxy", "failed to bind/listen on loopback socket")
            close(fd)
            return false
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }

        lock.lock()
        listenSocket = fd
        port = UInt16(bigEndian: boundAddr.sin_port)
        started = true
        lock.unlock()

        DebugLog.shared.log("Proxy", "listening on 127.0.0.1:\(port)")

        let accept = Thread(target: self, selector: #selector(acceptLoopEntry(_:)), object: NSNumber(value: fd))
        accept.stackSize = 256 * 1024
        accept.start()
        return true
    }

    @objc private func acceptLoopEntry(_ arg: Any) {
        guard let fd = (arg as? NSNumber)?.int32Value else { return }
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { break }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let t = Thread(target: self, selector: #selector(handleConnectionEntry(_:)), object: NSNumber(value: client))
            t.stackSize = 256 * 1024
            t.start()
        }
    }

    @objc private func handleConnectionEntry(_ arg: Any) {
        guard let fd = (arg as? NSNumber)?.int32Value else { return }
        handle(connection: fd)
    }

    // MARK: - Path <-> remote URL mapping

    private func registerPath(for remoteURL: URL, isPlaylist: Bool, gen: UInt64,
                              extHint: String? = nil) -> String {
        lock.lock(); defer { lock.unlock() }
        nextID += 1
        if isPlaylist {
            // The file name only makes the log readable; a name that would need escaping in
            // a URL path gets a stand-in.
            let name = remoteURL.lastPathComponent as NSString
            let plain = name.length > 5 && name.hasSuffix(".m3u8")
                && name.rangeOfCharacter(from: LocalStreamProxy.plainNameChars.inverted).location == NSNotFound
            let path = "/\(nextID)/" + (plain ? name as String : "index.m3u8")
            routes[path] = remoteURL
            bases[String(nextID)] = remoteURL
            return path
        }
        let urlExt = LocalStreamProxy.fileExtension(of: remoteURL)
        let ext = isPlaylist ? "m3u8" : (urlExt.isEmpty ? (extHint ?? "ts") : urlExt)
        let path = "/\(nextID).\(ext)"
        routes[path] = remoteURL
        return path
    }

    private static let plainNameChars =
        CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    // "/<id>/<relative URI>": a URI the player resolved against a playlist served at
    // /<id>/…, resolved again against that playlist's remote URL.
    private func mirroredRoute(for target: String) -> URL? {
        let t = target as NSString
        guard t.length > 3, t.hasPrefix("/") else { return nil }
        let slash = t.range(of: "/", options: [], range: NSRange(location: 1, length: t.length - 1))
        guard slash.location != NSNotFound else { return nil }
        let id = t.substring(with: NSRange(location: 1, length: slash.location - 1))
        lock.lock()
        let base = bases[id]
        lock.unlock()
        guard let playlistURL = base else { return nil }
        return URL(string: t.substring(from: slash.location + 1), relativeTo: playlistURL)?.absoluteURL
    }

    // "/<id>/…", as opposed to the flat "/<id>.<ext>" of a stream registered on its own.
    private static func isMirrored(_ path: String) -> Bool {
        let s = path as NSString
        return s.length > 1
            && s.range(of: "/", options: [], range: NSRange(location: 1, length: s.length - 1)).location != NSNotFound
    }

    static func isPlaylistURL(_ url: URL) -> Bool {
        return fileExtension(of: url) == "m3u8"
    }

    static func fileExtension(of url: URL) -> String {
        // Fast path: NSURL computes this in C. It must stay the common case —
        // this runs once per line of a playlist that can hold 1000+ segments,
        // and the fallback below is orders of magnitude more expensive
        // (absoluteString hands back a bridged NSString, and walking one of
        // those from Swift is brutally slow on an A4/A5).
        let ext = url.pathExtension
        if !ext.isEmpty { return ext.lowercased() }
        // Empty means either genuinely no extension, or a non-hierarchical
        // URL — which is what a server address stored without a scheme
        // produces ("host:8096/..." parses as scheme "host", leaving path and
        // pathExtension empty). Slice the raw string with NSString's C path
        // helpers rather than Swift character indexing.
        var s = url.absoluteString as NSString
        let hash = s.range(of: "#")
        if hash.location != NSNotFound { s = s.substring(to: hash.location) as NSString }
        let q = s.range(of: "?")
        if q.location != NSNotFound { s = s.substring(to: q.location) as NSString }
        return s.pathExtension.lowercased()
    }

    private func route(for path: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return routes[path]
    }

    private var generation: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return currentGen
    }

    // MARK: - Connection handling

    private func handle(connection fd: Int32) {
        defer { close(fd) }
        let gen = generation
        guard let head = readRequestHead(fd), let (path, target, rangeHeader) = parseRequest(head) else {
            DebugLog.shared.log("Proxy", "REQ unparseable request head — answering 400")
            sendStatusOnly(fd, "400 Bad Request")
            return
        }
        guard let remote = route(for: path) ?? mirroredRoute(for: target) else {
            DebugLog.shared.log("Proxy", "REQ \(path) -> 404 (no such route; \(routeCount) registered)")
            sendStatusOnly(fd, "404 Not Found")
            return
        }
        DebugLog.shared.log("Proxy", "REQ \(path)\(rangeHeader.map { " [\($0)]" } ?? "") -> \(DebugLog.redact(remote.absoluteString))")
        if path.hasSuffix(".m3u8") {
            servePlaylist(remote: remote, gen: gen, path: path, clientFd: fd)
        } else {
            streamRemote(remote, gen: gen, path: path, rangeHeader: rangeHeader, clientFd: fd)
        }
    }

    private var routeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return routes.count
    }

    // Reads until the blank line that ends an HTTP request head. Bounded so a
    // misbehaving client can't make this spin forever. No request body is
    // ever expected (GET only), so nothing past the head needs reading.
    private func readRequestHead(_ fd: Int32) -> String? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 2048)
        let terminator = Data("\r\n\r\n".utf8)
        while data.range(of: terminator) == nil {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { return data.isEmpty ? nil : String(data: data, encoding: .isoLatin1) }
            data.append(buf, count: n)
            if data.count > 16 * 1024 { break }
        }
        return String(data: data, encoding: .isoLatin1)
    }

    // The path without its query (routes are keyed by it) and the full request target
    // (a mirrored URI needs its query).
    private func parseRequest(_ head: String) -> (path: String, target: String, rangeHeader: String?)? {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let target = String(parts[1])
        var path = target
        let q = (target as NSString).range(of: "?")
        if q.location != NSNotFound { path = (target as NSString).substring(to: q.location) }
        var rangeHeader: String?
        for line in lines.dropFirst() where line.lowercased().hasPrefix("range:") {
            rangeHeader = line
        }
        return (path, target, rangeHeader)
    }

    private func sendStatusOnly(_ fd: Int32, _ status: String) {
        let head = "HTTP/1.1 \(status)\r\nConnection: close\r\n\r\n"
        LocalStreamProxy.sendAll(fd, Array(head.utf8))
    }

    // MARK: - Playlists (buffered — small text, needs full parsing to rewrite URIs)

    private func servePlaylist(remote: URL, gen: UInt64, path: String, clientFd: Int32) {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let data = CurlFetcher.fetchSyncData(url: remote.absoluteString) else {
            // fetchSyncData returns nil for a transport error OR a non-2xx
            // status — a TLS handshake failure lands here.
            DebugLog.shared.log("Proxy", "PLAYLIST \(path) FETCH FAILED after \(ms(since: t0))ms (transport error or non-2xx) \(DebugLog.redact(remote.absoluteString))")
            sendStatusOnly(clientFd, "502 Bad Gateway")
            return
        }
        DebugLog.shared.log("Proxy", "PLAYLIST \(path) fetched \(data.count)B in \(ms(since: t0))ms")
        let body = rewritePlaylist(data, baseURL: remote, gen: gen, path: path)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        guard LocalStreamProxy.sendAll(clientFd, Array(head.utf8)) else { return }
        body.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                _ = LocalStreamProxy.sendAll(clientFd, base.assumingMemoryBound(to: UInt8.self), body.count)
            }
        }
    }

    private func ms(since t0: CFAbsoluteTime) -> Int {
        return Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    // Gives a local route to each URI line the player couldn't resolve through the proxy
    // by itself, and leaves the rest of the bytes as they are. Served under /<id>/, a
    // playlist keeps its plain relative URIs; served flat (a stream that turned out to be
    // a playlist), every URI is routed.
    //
    // A VOD playlist can carry 2000+ segments, and parsing then registering each one cost
    // ~1.3 ms on an A5 (3 s before playback could start), so this works on the raw bytes:
    // memchr to each line end, a look at its first bytes. The variant/codec declarations
    // are logged in this same pass — they're what to compare between a device that plays
    // the item and one that doesn't.
    private func rewritePlaylist(_ data: Data, baseURL: URL, gen: UInt64, path: String) -> Data {
        let t0 = CFAbsoluteTimeGetCurrent()
        let keepRelative = LocalStreamProxy.isMirrored(path)
        var uriCount = 0
        var routed: [(start: Int, end: Int, path: String)] = []
        var tags: [String] = []
        let isPlaylist: Bool = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let start0 = raw.baseAddress else { return false }
            let p = start0.assumingMemoryBound(to: UInt8.self)
            let n = raw.count
            var start = 0
            while start < n {
                var end = n
                if let nl = memchr(p + start, 0x0A, n - start) {
                    end = start0.distance(to: UnsafeRawPointer(nl))
                }
                var s = start, e = end
                while s < e, p[s] == 0x20 || p[s] == 0x09 { s += 1 }
                while e > s, p[e - 1] == 0x0D || p[e - 1] == 0x20 || p[e - 1] == 0x09 { e -= 1 }
                if s < e {
                    if p[s] == 0x23 {
                        // "#EXT-X-…" only: "#EXTINF" comes once per segment and isn't logged.
                        if e - s > 7 && p[s + 1] == 0x45 && p[s + 4] == 0x2D {
                            let tag = String(decoding: UnsafeBufferPointer(start: p + s, count: e - s), as: UTF8.self)
                            if tag.hasPrefix("#EXT-X-STREAM-INF") || tag.hasPrefix("#EXT-X-MEDIA")
                                || tag.hasPrefix("#EXT-X-TARGETDURATION") || tag.hasPrefix("#EXT-X-PLAYLIST-TYPE")
                                || tag.hasPrefix("#EXT-X-VERSION") {
                                tags.append(tag)
                            }
                        }
                    } else {
                        uriCount += 1
                        if !(keepRelative && LocalStreamProxy.isPlainRelative(p + s, e - s)) {
                            let uri = String(decoding: UnsafeBufferPointer(start: p + s, count: e - s), as: UTF8.self)
                            if let resolved = URL(string: uri, relativeTo: baseURL)?.absoluteURL {
                                routed.append((s, e, registerPath(for: resolved,
                                                                  isPlaylist: LocalStreamProxy.isPlaylistURL(resolved),
                                                                  gen: gen)))
                            }
                        }
                    }
                }
                start = end + 1
            }
            // "#EXTM3U"
            return n >= 7 && p[0] == 0x23 && p[1] == 0x45 && p[2] == 0x58 && p[3] == 0x54
                && p[4] == 0x4D && p[5] == 0x33 && p[6] == 0x55
        }
        if !isPlaylist {
            DebugLog.shared.log("Proxy", "PLAYLIST \(path) body doesn't start with #EXTM3U — probably not a playlist at all")
        }
        for tag in tags { DebugLog.shared.log("Proxy", "PLAYLIST \(path) | \(tag)") }
        var body = data
        if !routed.isEmpty {
            let out = NSMutableData(capacity: data.count + routed.count * 16) ?? NSMutableData()
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let p = raw.baseAddress else { return }
                var at = 0
                for r in routed {
                    out.append(p + at, length: r.start - at)
                    let local = Array(r.path.utf8)
                    out.append(local, length: local.count)
                    at = r.end
                }
                out.append(p + at, length: raw.count - at)
            }
            body = out as Data
        }
        DebugLog.shared.log("Proxy", "PLAYLIST \(path) \(uriCount) URI(s), \(routed.count) routed, in \(ms(since: t0))ms")
        return body
    }

    // A URI the player resolves under /<id>/ to a path mirroredRoute() maps back: not
    // rooted ("/…"), not starting with a dot segment, no scheme (a ':' before the first
    // '/', '?' or '#').
    private static func isPlainRelative(_ p: UnsafePointer<UInt8>, _ count: Int) -> Bool {
        if p[0] == 0x2F || p[0] == 0x2E { return false }
        var i = 0
        while i < count {
            let c = p[i]
            if c == 0x3A { return false }
            if c == 0x2F || c == 0x3F || c == 0x23 { return true }
            i += 1
        }
        return true
    }

    // MARK: - Segments / direct streams (true streaming — relayed as they arrive)

    private func streamRemote(_ remote: URL, gen: UInt64, path: String, rangeHeader: String?, clientFd: Int32) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let conn = ProxyConn(clientFd: clientFd, gen: gen, proxy: self)
        let connPtr = Unmanaged.passUnretained(conn).toOpaque()

        let h = curl_bridge_init()
        defer { curl_bridge_cleanup(h) }

        remote.absoluteString.withCString { curl_bridge_set_url(h, $0) }
        curl_bridge_set_ssl_noverify(h)
        curl_bridge_set_follow_redirects(h)
        curl_bridge_set_timeout(h, 0) // segments/direct streams can run far longer than a normal API call

        var headerList: UnsafeMutableRawPointer?
        if let r = rangeHeader {
            r.withCString { headerList = curl_bridge_headers_append(headerList, $0) }
        }
        if headerList != nil { curl_bridge_set_headers(h, headerList) }
        defer { if headerList != nil { curl_bridge_headers_free(headerList) } }

        curl_bridge_set_header_fn(h, proxyHeaderCallback, connPtr)
        curl_bridge_set_write_fn(h, proxyBodyCallback, connPtr)
        curl_bridge_set_progress_fn(h, proxyProgressCallback, connPtr)

        let rc = curl_bridge_perform(h)
        let httpCode = curl_bridge_response_code(h)
        let elapsed = ms(since: t0)

        // Upstream said this is a playlist even though the route wasn't
        // registered as one. Relaying it verbatim would leave its relative
        // URIs pointing at paths the proxy has never heard of, so refetch it
        // through the playlist path instead (small text, cheap to redo).
        if conn.needsPlaylistRetry {
            DebugLog.shared.log("Proxy", "STREAM \(path) upstream Content-Type is a playlist — re-serving as one")
            servePlaylist(remote: remote, gen: gen, path: path, clientFd: clientFd)
            return
        }

        if rc != 0 && !conn.aborted {
            // rc 35 = SSL connect error — the GCM-cipher handshake smoking gun.
            // rc 28 = timeout, 7 = couldn't connect, 6 = couldn't resolve host.
            let reason = String(cString: curl_bridge_strerror(rc))
            DebugLog.shared.log("Proxy", "STREAM \(path) FAILED rc=\(rc) (\(reason)) http=\(httpCode) sent=\(conn.bytesRelayed)B in \(elapsed)ms")
        } else if conn.aborted {
            // Normal when the player seeks or closes the screen mid-segment.
            DebugLog.shared.log("Proxy", "STREAM \(path) aborted (client gone or superseded) http=\(httpCode) sent=\(conn.bytesRelayed)B in \(elapsed)ms")
        } else {
            DebugLog.shared.log("Proxy", "STREAM \(path) ok http=\(httpCode) sent=\(conn.bytesRelayed)B in \(elapsed)ms\(conn.upstreamStatus.isEmpty ? "" : " upstream=\(conn.upstreamStatus)")")
            if conn.bytesRelayed == 0 {
                DebugLog.shared.log("Proxy", "STREAM \(path) WARNING upstream returned an empty body")
            }
        }
        // If curl failed before the body callback ever ran, the client is
        // still waiting on a response head.
        if !conn.headersSent && !conn.aborted {
            sendStatusOnly(clientFd, "502 Bad Gateway")
        }
    }

    // MARK: - Raw socket send helpers

    @discardableResult
    static func sendAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBufferPointer { buf -> Bool in
            guard let base = buf.baseAddress else { return true }
            return sendAll(fd, base, buf.count)
        }
    }

    @discardableResult
    static func sendAll(_ fd: Int32, _ ptr: UnsafePointer<UInt8>, _ count: Int) -> Bool {
        guard count > 0 else { return true }
        var sent = 0
        while sent < count {
            let n = send(fd, ptr + sent, count - sent, 0)
            if n > 0 { sent += n; continue }
            if n < 0 && errno == EINTR { continue }
            return false
        }
        return true
    }
}

// MARK: - Per-connection state for the C write/header/progress callbacks
//
// Must live at file scope (not nested in LocalStreamProxy): the callbacks
// below are file-scope @convention(c) closures (C function pointers can't
// capture anything), so they reach state only via Unmanaged<ProxyConn>, and
// a file-scope closure is not an extension of LocalStreamProxy — it can't
// see that class's `private` members, only `fileprivate` ones.
private final class ProxyConn {
    let clientFd: Int32
    let gen: UInt64
    let proxy: LocalStreamProxy
    var pendingHead = ""
    var headersSent = false
    var aborted = false
    var bytesRelayed = 0
    var upstreamStatus = ""   // upstream's status line, for the log
    var upstreamIsPlaylist = false
    var needsPlaylistRetry = false

    init(clientFd: Int32, gen: UInt64, proxy: LocalStreamProxy) {
        self.clientFd = clientFd
        self.gen = gen
        self.proxy = proxy
    }
}

// Captures the upstream response's status line and headers, dropping the
// hop-by-hop ones we don't want forwarded (we always answer with our own
// Connection: close and no chunked transfer-encoding).
private let proxyHeaderCallback: @convention(c) (UnsafeRawPointer?, Int, Int, UnsafeMutableRawPointer?) -> Int = { ptr, size, nmemb, userdata in
    let bytes = size * nmemb
    guard let ptr = ptr, let userdata = userdata else { return bytes }
    let conn = Unmanaged<ProxyConn>.fromOpaque(userdata).takeUnretainedValue()
    guard let line = String(bytes: Data(bytes: ptr, count: bytes), encoding: .isoLatin1) else { return bytes }
    let lower = line.lowercased()
    if lower.hasPrefix("http/") {
        conn.pendingHead = line // a redirect restarts the head — keep only the final one
        conn.upstreamStatus = line.trimmingCharacters(in: .whitespacesAndNewlines)
    } else if lower.hasPrefix("transfer-encoding:") || lower.hasPrefix("connection:") {
        // dropped — we set these ourselves
    } else if lower.hasPrefix("content-type:") {
        // application/vnd.apple.mpegurl or application/x-mpegURL
        if lower.range(of: "mpegurl") != nil { conn.upstreamIsPlaylist = true }
        conn.pendingHead += line
    } else if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        conn.pendingHead += line
    }
    return bytes
}

// Relays body bytes to the client as they arrive. Sends the buffered
// response head (built by proxyHeaderCallback) exactly once, right before
// the first body byte.
private let proxyBodyCallback: @convention(c) (UnsafeRawPointer?, Int, Int, UnsafeMutableRawPointer?) -> Int = { ptr, size, nmemb, userdata in
    let bytes = size * nmemb
    guard let ptr = ptr, let userdata = userdata else { return 0 }
    let conn = Unmanaged<ProxyConn>.fromOpaque(userdata).takeUnretainedValue()
    if conn.aborted { return 0 }
    // Nothing has been written to the client yet, so the whole response can
    // still be redone as a playlist — abort here and let streamRemote retry.
    if conn.upstreamIsPlaylist && !conn.headersSent {
        conn.needsPlaylistRetry = true
        conn.aborted = true
        return 0
    }
    if !conn.headersSent {
        let head = (conn.pendingHead.isEmpty ? "HTTP/1.1 200 OK\r\n" : conn.pendingHead) + "Connection: close\r\n\r\n"
        if !LocalStreamProxy.sendAll(conn.clientFd, Array(head.utf8)) {
            conn.aborted = true
            return 0
        }
        conn.headersSent = true
    }
    guard LocalStreamProxy.sendAll(conn.clientFd, ptr.assumingMemoryBound(to: UInt8.self), bytes) else {
        conn.aborted = true
        return 0
    }
    conn.bytesRelayed += bytes
    return bytes
}

// Fires periodically during the whole transfer, including the connect/TLS
// handshake phase — returning non-zero aborts curl immediately. Used to kill
// a connection as soon as a newer playback request supersedes it, so a
// stuck/superseded transfer can't leak a blocked thread indefinitely.
private let proxyProgressCallback: @convention(c) (UnsafeMutableRawPointer?, Int64, Int64, Int64, Int64) -> Int32 = { clientp, _, _, _, _ in
    guard let clientp = clientp else { return 0 }
    let conn = Unmanaged<ProxyConn>.fromOpaque(clientp).takeUnretainedValue()
    if conn.aborted { return 1 }
    if conn.proxy.isSuperseded(conn.gen) {
        conn.aborted = true
        return 1
    }
    return 0
}
