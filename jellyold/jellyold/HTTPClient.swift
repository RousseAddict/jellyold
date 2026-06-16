import Foundation

class HTTPClient {

    static func get(url: String, headers: [String: String] = [:], completion: @escaping (Data?, Error?) -> Void) {
        guard let nsUrl = URL(string: url) else {
            completion(nil, makeError("Invalid URL: \(url)"))
            return
        }
        var request = URLRequest(url: nsUrl)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        send(request, completion: completion)
    }

    static func post(url: String, headers: [String: String] = [:], body: [String: Any], completion: @escaping (Data?, Error?) -> Void) {
        guard let nsUrl = URL(string: url) else {
            completion(nil, makeError("Invalid URL: \(url)"))
            return
        }
        var request = URLRequest(url: nsUrl)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if let data = try? JSONSerialization.data(withJSONObject: body, options: []) {
            request.httpBody = data
        }
        send(request, completion: completion)
    }

    private static func send(_ request: URLRequest, completion: @escaping (Data?, Error?) -> Void) {
        NSURLConnection.sendAsynchronousRequest(request, queue: OperationQueue.main) { _, data, error in
            completion(data, error)
        }
    }

    private static func makeError(_ message: String) -> NSError {
        return NSError(domain: "HTTPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
