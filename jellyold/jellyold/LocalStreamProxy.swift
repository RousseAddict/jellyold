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
// Master/variant playlists are the one exception: they're small text and
// need to be fully parsed to rewrite URIs, so those are fetched whole via
// CurlFetcher, rewritten, then sent.
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
    private var nextID = 0
    private var currentGen: UInt64 = 0

    // Starts the server (if not already running) and registers `remoteURL`
    // as a route. Returns the local URL to hand to the player, or nil if the
    // loopback socket couldn't be created — the caller should fall back to
    // the direct remote URL in that case. Bumps the generation counter so
    // any connections still serving a previous stream get cancelled.
    func start(remoteURL: URL) -> URL? {
        lock.lock()
        currentGen += 1
        let gen = currentGen
        lock.unlock()
        guard ensureStarted() else { return nil }
        let isPlaylist = remoteURL.pathExtension.lowercased() == "m3u8"
        let path = registerPath(for: remoteURL, isPlaylist: isPlaylist, gen: gen)
        return URL(string: "http://127.0.0.1:\(port)\(path)")
    }

    func stop() {
        lock.lock()
        guard started else { lock.unlock(); return }
        started = false
        currentGen += 1
        let fd = listenSocket
        listenSocket = -1
        routes.removeAll()
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

    private func registerPath(for remoteURL: URL, isPlaylist: Bool, gen: UInt64) -> String {
        lock.lock(); defer { lock.unlock() }
        nextID += 1
        let ext = isPlaylist ? "m3u8" : (remoteURL.pathExtension.isEmpty ? "ts" : remoteURL.pathExtension)
        let path = "/\(nextID).\(ext)"
        routes[path] = remoteURL
        return path
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
        guard let head = readRequestHead(fd), let (path, rangeHeader) = parseRequest(head) else {
            sendStatusOnly(fd, "400 Bad Request")
            return
        }
        guard let remote = route(for: path) else {
            sendStatusOnly(fd, "404 Not Found")
            return
        }
        if path.hasSuffix(".m3u8") {
            servePlaylist(remote: remote, gen: gen, clientFd: fd)
        } else {
            streamRemote(remote, gen: gen, rangeHeader: rangeHeader, clientFd: fd)
        }
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

    private func parseRequest(_ head: String) -> (path: String, rangeHeader: String?)? {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var path = String(parts[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        var rangeHeader: String?
        for line in lines.dropFirst() where line.lowercased().hasPrefix("range:") {
            rangeHeader = line
        }
        return (path, rangeHeader)
    }

    private func sendStatusOnly(_ fd: Int32, _ status: String) {
        let head = "HTTP/1.1 \(status)\r\nConnection: close\r\n\r\n"
        LocalStreamProxy.sendAll(fd, Array(head.utf8))
    }

    // MARK: - Playlists (buffered — small text, needs full parsing to rewrite URIs)

    private func servePlaylist(remote: URL, gen: UInt64, clientFd: Int32) {
        guard let data = CurlFetcher.fetchSyncData(url: remote.absoluteString) else {
            DebugLog.shared.log("Proxy", "playlist fetch failed for \(remote.absoluteString)")
            sendStatusOnly(clientFd, "502 Bad Gateway")
            return
        }
        let body = rewritePlaylist(data, baseURL: remote, gen: gen)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        guard LocalStreamProxy.sendAll(clientFd, Array(head.utf8)) else { return }
        body.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                _ = LocalStreamProxy.sendAll(clientFd, base.assumingMemoryBound(to: UInt8.self), body.count)
            }
        }
    }

    // Resolves every non-comment URI line against the playlist's own remote
    // URL and replaces it with a local proxy path, so nested playlists and
    // segments get proxied (and, if themselves playlists, rewritten again)
    // recursively.
    private func rewritePlaylist(_ data: Data, baseURL: URL, gen: UInt64) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let lines = text.components(separatedBy: "\n")
        let rewritten = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return line }
            guard let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL else { return line }
            let isNestedPlaylist = resolved.pathExtension.lowercased() == "m3u8"
            return registerPath(for: resolved, isPlaylist: isNestedPlaylist, gen: gen)
        }
        return Data(rewritten.joined(separator: "\n").utf8)
    }

    // MARK: - Segments / direct streams (true streaming — relayed as they arrive)

    private func streamRemote(_ remote: URL, gen: UInt64, rangeHeader: String?, clientFd: Int32) {
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
        if rc != 0 && !conn.aborted {
            DebugLog.shared.log("Proxy", "curl error \(rc) for \(remote.absoluteString)")
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
    } else if lower.hasPrefix("transfer-encoding:") || lower.hasPrefix("connection:") {
        // dropped — we set these ourselves
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
