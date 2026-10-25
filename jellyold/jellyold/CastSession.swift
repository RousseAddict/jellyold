import Foundation

// MARK: - CastSession
//
// A single Chromecast CASTV2 session: TLS-connects to the device on port 8009 (via the
// curl bridge's CONNECT_ONLY socket — OpenSSL speaks the modern ciphers iOS 6 can't), then
// runs the CONNECT -> LAUNCH -> LOAD -> PLAY handshake and keeps a heartbeat alive.
//
// THREADING: everything TLS runs on ONE background thread (`ioLoop`). OpenSSL SSL_read /
// SSL_write on the same SSL object are not thread-safe, so the socket is never touched from
// two threads. Public methods (play/pause/seek/stop) just enqueue an outbound frame and the
// ioLoop flushes it between recv poll cycles. Callbacks fire back on the main thread.
//
// NOTE: the Chromecast fetches the media URL itself, so it must be the real Jellyfin server
// URL — LocalStreamProxy (127.0.0.1) is unreachable from the device and must not be used here.

final class CastSession: NSObject {

    private let device: CastDevice
    private var handle: CurlHandle?

    // Outbound frames waiting to be written by the ioLoop, guarded by `lock`.
    private var outbound = [Data]()
    private let lock = NSLock()

    private var running = false
    private var requestId = 0

    // The app's transport channel id, learned from RECEIVER_STATUS after LAUNCH.
    private var transportId: String?
    private var mediaSessionId: Int?

    // The media URL to LOAD once the receiver app is running.
    private var pendingMediaURL: String?
    private var pendingContentType = "video/mp4"
    private var pendingStartTime: Double = 0
    private var pendingMetadata: [String: Any]?

    // Last known playback progress, updated from MEDIA_STATUS (reported via onProgress).
    private var mediaDuration: Double = 0
    private var mediaCurrentTime: Double = 0
    private var isPlayingRemote = false

    private var lastHeartbeat = Date()
    private var lastStatusPoll = Date()

    private static let senderId = "sender-0"
    private static let platformReceiver = "receiver-0"

    // Reports human-readable state transitions on the main thread.
    var onState: ((String) -> Void)?
    // Reports playback progress on the main thread: (currentSeconds, durationSeconds, isPlaying).
    var onProgress: ((Double, Double, Bool) -> Void)?
    // Fires on the main thread when the receiver reports the media finished or failed to load.
    var onEnded: ((String) -> Void)?

    // Last progress seen, so CastController can persist a resume position on stop.
    private(set) var lastKnownTime: Double = 0

    init(device: CastDevice) {
        self.device = device
        super.init()
    }

    // MARK: - Public API (thread-safe — just enqueues / kicks the ioLoop)

    // Start the session and, once the receiver app is up, LOAD + play this URL.
    // `startTime` seeds the receiver's playback position (resume support).
    func start(mediaURL: String,
               contentType: String = "video/mp4",
               startTime: Double = 0,
               metadata: [String: Any]? = nil) {
        pendingMediaURL = mediaURL
        pendingContentType = contentType
        pendingStartTime = startTime
        pendingMetadata = metadata
        running = true
        DebugLog.shared.log("CAST", "start dev=\(device.name) \(device.host):\(device.port) type=\(contentType) at=\(Int(startTime))s url=\(DebugLog.redact(mediaURL))")
        let t = Thread(target: self, selector: #selector(ioLoop), object: nil)
        t.stackSize = 512 * 1024
        t.start()
    }

    func play()  { sendMedia(["type": "PLAY"]) }
    func pause() { sendMedia(["type": "PAUSE"]) }

    func seek(to seconds: Double) {
        let target = max(0, seconds)
        sendMedia(["type": "SEEK", "currentTime": target])
    }

    // Relative seek for the skip buttons; clamped to the known duration.
    func seek(by delta: Double) {
        var target = lastKnownTime + delta
        if mediaDuration > 0 { target = min(target, mediaDuration - 1) }
        seek(to: target)
    }

    // Stop playback + close the session.
    func stop() {
        if let tid = transportId {
            enqueue(namespace: CastNS.receiver, destination: CastSession.platformReceiver,
                    json: ["type": "STOP", "sessionId": tid])
        }
        running = false
        DebugLog.shared.log("CAST", "stop at=\(Int(lastKnownTime))s")
    }

    // MARK: - I/O loop (single thread; owns all TLS reads/writes)

    @objc private func ioLoop() {
        CurlFetcher.ensureGlobalInit()
        guard let h = curl_bridge_init() else { report("init failed"); return }
        handle = h
        defer { curl_bridge_cleanup(h); handle = nil }

        let rc = device.host.withCString { curl_bridge_connect_only(h, $0, device.port) }
        guard rc == 0 else {
            let msg = String(cString: curl_bridge_strerror(rc))
            DebugLog.shared.log("CAST", "connect FAILED rc=\(rc) (\(msg))")
            report("connect failed (\(msg))")
            return
        }
        DebugLog.shared.log("CAST", "connected \(device.name)")
        report("connected \(device.name)")

        // Virtual-connect + launch the default media receiver.
        enqueue(namespace: CastNS.connection, destination: CastSession.platformReceiver,
                json: ["type": "CONNECT"])
        launchReceiver()

        var inbound = [UInt8]()
        var recvBuf = [UInt8](repeating: 0, count: 16 * 1024)

        while running {
            flushOutbound(h)
            heartbeatIfDue()
            statusPollIfDue()

            let n = curl_bridge_recv(h, &recvBuf, recvBuf.count, 500)   // 500ms poll window
            if n < 0 {
                DebugLog.shared.log("CAST", "disconnected")
                report("disconnected")
                break
            }
            if n > 0 {
                inbound.append(contentsOf: recvBuf[0..<Int(n)])
                drainFrames(&inbound)
            }
        }

        // Best-effort: tell the device we're leaving.
        enqueue(namespace: CastNS.connection, destination: transportId ?? CastSession.platformReceiver,
                json: ["type": "CLOSE"])
        flushOutbound(h)
    }

    // Pull every complete UInt32-length-prefixed frame out of the inbound buffer and handle it.
    private func drainFrames(_ inbound: inout [UInt8]) {
        while inbound.count >= 4 {
            let len = (UInt32(inbound[0]) << 24) | (UInt32(inbound[1]) << 16)
                    | (UInt32(inbound[2]) << 8) | UInt32(inbound[3])
            let total = 4 + Int(len)
            if inbound.count < total { break }         // wait for the rest of the frame
            let body = Array(inbound[4..<total])
            inbound.removeFirst(total)
            if let msg = CastMessage.parse(body) { handle(msg) }
        }
    }

    private func flushOutbound(_ h: CurlHandle) {
        while true {
            lock.lock()
            let frame = outbound.isEmpty ? nil : outbound.removeFirst()
            lock.unlock()
            guard let data = frame else { break }
            _ = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Int(curl_bridge_send(h, base, data.count))
            }
        }
    }

    private func heartbeatIfDue() {
        if Date().timeIntervalSince(lastHeartbeat) >= 5 {
            lastHeartbeat = Date()
            enqueue(namespace: CastNS.heartbeat, destination: CastSession.platformReceiver,
                    json: ["type": "PING"])
        }
    }

    // Poll the receiver for a fresh MEDIA_STATUS ~once/sec so the scrubber tracks playback
    // (Chromecast only pushes status on state changes, not continuously).
    private func statusPollIfDue() {
        guard let tid = transportId, let msid = mediaSessionId else { return }
        if Date().timeIntervalSince(lastStatusPoll) >= 1 {
            lastStatusPoll = Date()
            requestId += 1
            enqueue(namespace: CastNS.media, destination: tid,
                    json: ["type": "GET_STATUS", "mediaSessionId": msid, "requestId": requestId])
        }
    }

    // MARK: - Incoming message handling

    private func handle(_ msg: CastMessage) {
        guard let obj = jsonObject(msg.payloadUtf8) else { return }
        let type = (obj["type"] as? String) ?? ""

        switch msg.namespace {
        case CastNS.heartbeat:
            if type == "PING" {
                enqueue(namespace: CastNS.heartbeat, destination: CastSession.platformReceiver,
                        json: ["type": "PONG"])
            }
        case CastNS.receiver:
            if type == "RECEIVER_STATUS" { handleReceiverStatus(obj) }
        case CastNS.media:
            if type == "MEDIA_STATUS" { handleMediaStatus(obj) }
            // The receiver rejects a URL it can't fetch or decode. Surface it —
            // otherwise the UI just sits on "loading media" forever.
            if type == "LOAD_FAILED" || type == "LOAD_CANCELLED" || type == "INVALID_REQUEST" {
                let reason = (obj["reason"] as? String) ?? type
                DebugLog.shared.log("CAST", "LOAD failed: \(type) reason=\(reason)")
                report("failed: \(reason)")
                DispatchQueue.main.async { [weak self] in self?.onEnded?(reason) }
            }
        default:
            break
        }
    }

    // Extract the launched app's transportId, virtual-connect to it, then LOAD the media.
    private func handleReceiverStatus(_ obj: [String: Any]) {
        guard let status = obj["status"] as? [String: Any],
              let apps = status["applications"] as? [[String: Any]],
              let app = apps.first,
              let tid = app["transportId"] as? String else { return }
        if transportId == tid { return }   // already connected to this app
        transportId = tid
        report("app ready")

        enqueue(namespace: CastNS.connection, destination: tid, json: ["type": "CONNECT"])
        if let url = pendingMediaURL { loadMedia(url, transport: tid) }
    }

    private func handleMediaStatus(_ obj: [String: Any]) {
        guard let arr = obj["status"] as? [[String: Any]], let first = arr.first else { return }
        if let msid = (first["mediaSessionId"] as? NSNumber)?.intValue { mediaSessionId = msid }
        // NSNumber bridging: `as? Double`/`as? Int` silently fail on the 5.1.5 runtime.
        if let cur = (first["currentTime"] as? NSNumber)?.doubleValue { mediaCurrentTime = cur }
        // duration lives on the nested media object, only present on the first status after LOAD.
        if let media = first["media"] as? [String: Any],
           let dur = (media["duration"] as? NSNumber)?.doubleValue, dur > 0 {
            mediaDuration = dur
        }
        let playerState = (first["playerState"] as? String) ?? ""
        if !playerState.isEmpty {
            isPlayingRemote = (playerState == "PLAYING" || playerState == "BUFFERING")
            report("player: \(playerState)")
        }
        lastKnownTime = mediaCurrentTime
        let cur = mediaCurrentTime, dur = mediaDuration, playing = isPlayingRemote
        DispatchQueue.main.async { [weak self] in self?.onProgress?(cur, dur, playing) }

        // IDLE with reason FINISHED is the receiver's end-of-media signal.
        if playerState == "IDLE", (first["idleReason"] as? String) == "FINISHED" {
            DebugLog.shared.log("CAST", "media finished")
            DispatchQueue.main.async { [weak self] in self?.onEnded?("FINISHED") }
        }
    }

    // MARK: - Outbound builders

    private func launchReceiver() {
        requestId += 1
        // CC1AD845 = the Default Media Receiver (plays a plain media URL, no custom app needed).
        enqueue(namespace: CastNS.receiver, destination: CastSession.platformReceiver,
                json: ["type": "LAUNCH", "appId": "CC1AD845", "requestId": requestId])
    }

    private func loadMedia(_ url: String, transport: String) {
        requestId += 1
        var media: [String: Any] = [
            "contentId": url,
            "contentType": pendingContentType,
            // A Jellyfin transcode has no Content-Length, so it can't be treated
            // as a seekable buffered file until the receiver probes it; BUFFERED
            // is still correct for the direct-stream/remux case and the receiver
            // downgrades itself when it can't seek.
            "streamType": "BUFFERED"
        ]
        if let meta = pendingMetadata { media["metadata"] = meta }
        let payload: [String: Any] = [
            "type": "LOAD",
            "requestId": requestId,
            "autoplay": true,
            "currentTime": pendingStartTime,
            "media": media
        ]
        enqueue(namespace: CastNS.media, destination: transport, json: payload)
        report("loading media")
    }

    private func sendMedia(_ base: [String: Any]) {
        guard let tid = transportId, let msid = mediaSessionId else { return }
        var json = base
        json["mediaSessionId"] = msid
        requestId += 1
        json["requestId"] = requestId
        enqueue(namespace: CastNS.media, destination: tid, json: json)
    }

    // Build a CastMessage frame and queue it for the ioLoop to write.
    private func enqueue(namespace: String, destination: String, json: [String: Any]) {
        let payload = jsonString(json)
        let msg = CastMessage(sourceId: CastSession.senderId, destinationId: destination,
                              namespace: namespace, payloadUtf8: payload)
        lock.lock()
        outbound.append(msg.framed())
        lock.unlock()
    }

    // MARK: - JSON helpers

    private func jsonString(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private func jsonObject(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else { return nil }
        return obj
    }

    private func report(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.onState?(text) }
    }
}
