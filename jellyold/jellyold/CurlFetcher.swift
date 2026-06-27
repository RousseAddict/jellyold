import Foundation

// MARK: - C-compatible write callback (file scope, no captures allowed)

// Accumulates the HTTP response body into an NSMutableData passed via userdata.
private let curlDataWriteCallback: @convention(c) (UnsafeRawPointer?, Int, Int, UnsafeMutableRawPointer?) -> Int = { ptr, size, nmemb, userdata in
    guard let ptr = ptr, let userdata = userdata else { return 0 }
    let bytes = size * nmemb
    let buf = Unmanaged<NSMutableData>.fromOpaque(userdata).takeUnretainedValue()
    buf.append(ptr, length: bytes)
    return bytes
}

// MARK: - CurlFetcher
//
// libcurl + embedded OpenSSL transport. Bypasses iOS 6 Secure Transport, which
// only negotiates CBC cipher suites — modern Jellyfin servers behind HTTPS
// (and any reverse proxy enforcing GCM-only TLS) fail the handshake under
// NSURLConnection on iOS 6. OpenSSL negotiates GCM correctly, so HTTPS logins
// work while plain HTTP logins keep working unchanged.

class CurlFetcher {
    private static var active: [CurlFetcher] = []
    // Serial queue — serial prevents concurrent curl_easy_init before global init.
    // curl_global_init is NOT thread-safe; concurrent implicit calls via curl_easy_init crash.
    private static let curlQueue = DispatchQueue(label: "com.jellyold.curl")
    // Thread-safe once-init: Swift static let uses dispatch_once. The first
    // background thread to touch this runs curl_global_init exactly once.
    // Never run from the main thread (crashes — OpenSSL threading init).
    private static let curlGlobalInit: Bool = { curl_bridge_global_init(); return true }()

    // GET url -> Data on a background thread; completion on the main thread.
    static func fetchData(url: String,
                          headers: [String: String] = [:],
                          timeout: Int = 30,
                          completion: @escaping (Data?) -> Void) {
        let fetcher = CurlFetcher()
        retain(fetcher)
        CurlFetcher.curlQueue.async {
            let data = fetcher.syncFetchData(url: url, headers: headers, timeout: timeout)
            DispatchQueue.main.async {
                release(fetcher)
                completion(data)
            }
        }
    }

    // POST url with JSON body + custom headers -> Data on a background thread;
    // completion on the main thread. Used by the login path.
    static func postData(url: String,
                         headers: [String: String],
                         body: Data,
                         timeout: Int = 30,
                         completion: @escaping (Data?) -> Void) {
        let fetcher = CurlFetcher()
        retain(fetcher)
        CurlFetcher.curlQueue.async {
            let data = fetcher.syncPostData(url: url, headers: headers, body: body, timeout: timeout)
            DispatchQueue.main.async {
                release(fetcher)
                completion(data)
            }
        }
    }

    // MARK: - Lifecycle management

    private static func retain(_ f: CurlFetcher) {
        objc_sync_enter(CurlFetcher.self)
        active.append(f)
        objc_sync_exit(CurlFetcher.self)
    }

    private static func release(_ f: CurlFetcher) {
        objc_sync_enter(CurlFetcher.self)
        active.removeAll { $0 === f }
        objc_sync_exit(CurlFetcher.self)
    }

    // MARK: - Synchronous implementations (run on the background queue)

    private func syncFetchData(url: String, headers: [String: String], timeout: Int) -> Data? {
        _ = CurlFetcher.curlGlobalInit  // ensures curl_global_init ran once before any easy_init
        let h = curl_bridge_init()
        defer { curl_bridge_cleanup(h) }

        let buf = NSMutableData()
        let ptr = Unmanaged.passUnretained(buf).toOpaque()

        url.withCString { curl_bridge_set_url(h, $0) }
        curl_bridge_set_ssl_noverify(h)
        curl_bridge_set_follow_redirects(h)
        curl_bridge_set_timeout(h, CLong(timeout))
        curl_bridge_set_write_fn(h, curlDataWriteCallback, ptr)

        var headerList: UnsafeMutableRawPointer?
        for (k, v) in headers {
            "\(k): \(v)".withCString { headerList = curl_bridge_headers_append(headerList, $0) }
        }
        if headerList != nil { curl_bridge_set_headers(h, headerList) }
        defer { if headerList != nil { curl_bridge_headers_free(headerList) } }

        let rc = curl_bridge_perform(h)
        guard rc == 0 else { return nil }
        let code = curl_bridge_response_code(h)
        guard code >= 200, code < 300 else { return nil }
        return buf as Data
    }

    private func syncPostData(url: String, headers: [String: String], body: Data, timeout: Int) -> Data? {
        _ = CurlFetcher.curlGlobalInit
        let h = curl_bridge_init()
        defer { curl_bridge_cleanup(h) }

        let buf = NSMutableData()
        let ptr = Unmanaged.passUnretained(buf).toOpaque()

        url.withCString { curl_bridge_set_url(h, $0) }
        curl_bridge_set_ssl_noverify(h)
        curl_bridge_set_follow_redirects(h)
        curl_bridge_set_timeout(h, CLong(timeout))
        curl_bridge_set_write_fn(h, curlDataWriteCallback, ptr)

        var headerList: UnsafeMutableRawPointer?
        for (k, v) in headers {
            "\(k): \(v)".withCString { headerList = curl_bridge_headers_append(headerList, $0) }
        }
        if headerList != nil { curl_bridge_set_headers(h, headerList) }
        defer { if headerList != nil { curl_bridge_headers_free(headerList) } }

        body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            curl_bridge_set_post_body(h, raw.baseAddress, CLong(body.count))
        }

        let rc = curl_bridge_perform(h)
        guard rc == 0 else { return nil }
        let code = curl_bridge_response_code(h)
        guard code >= 200, code < 300 else { return nil }
        return buf as Data
    }
}
