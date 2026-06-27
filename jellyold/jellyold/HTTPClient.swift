import Foundation

class HTTPClient {

    static func get(url: String, headers: [String: String] = [:], completion: @escaping (Data?, Error?) -> Void) {
        guard URL(string: url) != nil else {
            completion(nil, makeError("Invalid URL: \(url)"))
            return
        }
        // Route GET through libcurl + embedded OpenSSL for the same reason as
        // post(): iOS 6 Secure Transport can't negotiate GCM-only TLS, so HTTPS
        // hosts fail under NSURLConnection. Works over both HTTP and HTTPS.
        CurlFetcher.fetchData(url: url, headers: headers) { data in
            if let data = data {
                completion(data, nil)
            } else {
                completion(nil, makeError("Connection failed. Check the server URL and that it is reachable."))
            }
        }
    }

    static func post(url: String, headers: [String: String] = [:], body: [String: Any], completion: @escaping (Data?, Error?) -> Void) {
        guard URL(string: url) != nil else {
            completion(nil, makeError("Invalid URL: \(url)"))
            return
        }
        var allHeaders = headers
        allHeaders["Content-Type"] = "application/json"
        let bodyData = (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data()
        // Route POST (login) through libcurl + embedded OpenSSL. iOS 6 Secure
        // Transport only negotiates CBC cipher suites, so HTTPS servers that
        // require GCM-only TLS fail the handshake under NSURLConnection. OpenSSL
        // negotiates GCM correctly — HTTPS logins now work and HTTP logins are
        // unaffected (curl handles both schemes).
        CurlFetcher.postData(url: url, headers: allHeaders, body: bodyData) { data in
            if let data = data {
                completion(data, nil)
            } else {
                completion(nil, makeError("Connection failed. Check the server URL and that it is reachable."))
            }
        }
    }

    private static func makeError(_ message: String) -> NSError {
        return NSError(domain: "HTTPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
