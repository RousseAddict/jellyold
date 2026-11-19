import Foundation

// Lightweight on-device debug trace, aimed at diagnosing "playback doesn't
// start" reports without a Mac/Xcode attached. Writes timestamped lines to
// Documents/debug.log (capped + trimmed), and exposes the tail as plain text
// so it can be copied to the clipboard directly from the app.
final class DebugLog {
    static let shared = DebugLog()

    private let queue = DispatchQueue(label: "com.jellyold.debuglog")
    private let maxBytes = 500 * 1024

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // NSString-bridged appendingPathComponent, not the native Swift URL
        // overlay method — the latter's symbol isn't exported by the 5.1.5
        // runtime dylibs we ship, and since Swift overlay calls bind
        // non-lazily, a single missing symbol like that crashes the whole
        // binary at dyld load, before any code runs.
        let path = (docs.path as NSString).appendingPathComponent("debug.log")
        return URL(fileURLWithPath: path)
    }

    private init() {}

    // Masks Jellyfin access tokens in URLs before they reach the log, so the
    // file can be handed around without leaking one. We send `ApiKey=`, and
    // Jellyfin copies it into the child playlist URLs it generates; `api_key=`
    // is the legacy spelling that older logs and servers still carry. Only the
    // value is replaced; whatever follows it (&Next=..., a quote, the rest of
    // the line) is kept. NSString scanning, never Swift character walking
    // (slow on A5).
    private static let tokenKeys = ["ApiKey=", "api_key="]
    private static let tokenEnd = CharacterSet(charactersIn: "&#\"' \t\r\n")

    static func redact(_ text: String) -> String {
        let s = NSMutableString(string: text)
        for key in tokenKeys {
            var from = 0
            while from < s.length {
                let hit = s.range(of: key, options: .caseInsensitive,
                                  range: NSRange(location: from, length: s.length - from))
                if hit.location == NSNotFound { break }
                let start = hit.location + hit.length
                let end = s.rangeOfCharacter(from: tokenEnd, options: [],
                                             range: NSRange(location: start, length: s.length - start))
                let stop = end.location == NSNotFound ? s.length : end.location
                s.replaceCharacters(in: NSRange(location: start, length: stop - start), with: "***")
                from = start + 3
            }
        }
        return s as String
    }

    func log(_ category: String, _ message: String) {
        let stamp = dateFormatter.string(from: Date())
        let line = "[\(stamp)] [\(category)] \(message)\n"
        queue.async { [weak self] in
            self?.append(line)
        }
    }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let url = fileURL
        if let fh = FileManager.default.fileExists(atPath: url.path) ? try? FileHandle(forWritingTo: url) : nil {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        } else {
            try? data.write(to: url)
        }
        trimIfNeeded()
    }

    // Keeps the file bounded on long-running devices — drops the oldest half
    // once it crosses maxBytes rather than growing forever.
    private func trimIfNeeded() {
        let url = fileURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > maxBytes,
              let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        let trimmed = lines.suffix(lines.count / 2).joined(separator: "\n") + "\n"
        try? trimmed.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Retrieval for the "copy to clipboard" UI

    func readAll() -> String {
        queue.sync {
            (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "(debug log is empty)"
        }
    }

    func readLast(lines count: Int) -> String {
        let split = readAll().split(separator: "\n", omittingEmptySubsequences: true)
        return split.suffix(count).joined(separator: "\n")
    }

    func clear() {
        queue.async { [weak self] in
            guard let self = self else { return }
            try? FileManager.default.removeItem(at: self.fileURL)
        }
    }
}
