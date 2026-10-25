import Foundation

// MARK: - CastSession
//
// A single Chromecast CASTV2 session: TLS-connects to the device on port 8009 (via the
// curl bridge's CONNECT_ONLY socket — OpenSSL speaks the modern ciphers iOS 6 can't), then
// runs the CONNECT -> LAUNCH -> LOAD -> PLAY handshake and keeps a heartbeat alive.
//
// THREADING: everything TLS runs on ONE background thread (`ioLoop`). OpenSSL SSL_read /
// SSL_write on the same SSL object are not thread-safe, so the socket is never touched from
// two threads. Public methods (play/pause/seek/load/stop) enqueue a command that the ioLoop
// runs between recv poll cycles, so all session state is only ever read and written on that
// one thread. Callbacks fire back on the main thread.
//
// NOTE: the Chromecast fetches the media URL itself, so it must be the real Jellyfin server
// URL — LocalStreamProxy (127.0.0.1) is unreachable from the device and must not be used here.

// Why the receiver stopped playing the current media.
enum CastEnd {
    case finished              // played to the end
    case failed(String)        // LOAD rejected, or the receiver hit a playback error
    case stoppedRemotely       // stopped from the TV / another sender took the device
}

final class CastSession: NSObject {

    private let device: CastDevice
    private var handle: CurlHandle?

    // Outbound frames + commands waiting for the ioLoop, guarded by `lock`.
    private var outbound = [Data]()
    private var commands = [() -> Void]()
    private let lock = NSLock()

    private var running = false
    private var requestId = 0

    // The app's transport channel id, learned from RECEIVER_STATUS after LAUNCH.
    private var transportId: String?
    private var mediaSessionId: Int?
    // Media sessions replaced by a newer LOAD. The receiver still reports their teardown
    // (IDLE/INTERRUPTED) after the new LOAD, which must not read as "playback ended".
    private var staleMediaSessionIds = Set<Int>()
    // requestId of the latest LOAD: errors echoing an older id belong to a superseded load.
    private var loadRequestId = 0
    // True from a LOAD until the receiver reports the new media. In that window a status
    // for a media session older than the LOAD (the receiver numbers them upwards) is the
    // previous media winding down, even if its id was never seen before (a reload sent
    // before the first status arrived).
    private var awaitingLoad = false
    private var maxSeenMediaSessionId = 0
    private var firstNewMediaSessionId = 0
    // Set once onEnded fired for the current LOAD. The receiver often reports one failure
    // twice (LOAD_FAILED + an IDLE/ERROR status), and the second must not end a fallback.
    private var endReported = false

    // The media to LOAD once the receiver app is running.
    private var pendingMediaURL: String?
    private var pendingContentType = "video/mp4"
    private var pendingStartTime: Double = 0
    private var pendingMetadata: [String: Any]?
    private var pendingAutoplay = true
    // Added to every position the receiver reports. Non-zero when the URL itself starts
    // mid-file (a re-requested progressive stream), whose timeline the receiver sees as 0-based.
    private var timeOffset: Double = 0
    // A SEEK asked for before the receiver assigned a mediaSessionId; sent with the first status.
    private var deferredSeek: Double?

    private var lastHeartbeat = Date()
    private var lastStatusPoll = Date()

    private static let senderId = "sender-0"
    private static let platformReceiver = "receiver-0"

    // Reports connection-level state transitions on the main thread.
    var onState: ((String) -> Void)?
    // Reports playback on the main thread: (currentSeconds, receiverDurationSeconds, playerState).
    // currentSeconds already includes timeOffset; playerState is the receiver's raw
    // PLAYING / PAUSED / BUFFERING / IDLE.
    var onProgress: ((Double, Double, String) -> Void)?
    // Fires on the main thread when the current media stops for good.
    var onEnded: ((CastEnd) -> Void)?

    init(device: CastDevice) {
        self.device = device
        super.init()
    }

    // MARK: - Public API (thread-safe — enqueues work for the ioLoop)

    // Start the session and, once the receiver app is up, LOAD + play this URL.
    // `startTime` seeds the receiver's playback position (resume support); `timeOffset`
    // is where the URL itself starts in the item (see the property).
    func start(mediaURL: String,
               contentType: String = "video/mp4",
               startTime: Double = 0,
               timeOffset: Double = 0,
               metadata: [String: Any]? = nil) {
        pendingMediaURL = mediaURL
        pendingContentType = contentType
        pendingStartTime = startTime
        self.timeOffset = timeOffset
        pendingMetadata = metadata
        running = true
        DebugLog.shared.log("CAST", "start dev=\(device.name) \(device.host):\(device.port) type=\(contentType) at=\(Int(startTime))s offset=\(Int(timeOffset))s url=\(DebugLog.redact(mediaURL))")
        let t = Thread(target: self, selector: #selector(ioLoop), object: nil)
        t.stackSize = 512 * 1024
        t.start()
    }

    // Replace the media on the running receiver app — used to fall back to another
    // source and to "seek" a stream the receiver can't seek itself.
    func load(mediaURL: String, contentType: String, startTime: Double, timeOffset: Double,
              autoplay: Bool) {
        perform {
            DebugLog.shared.log("CAST", "reload type=\(contentType) at=\(Int(startTime))s offset=\(Int(timeOffset))s autoplay=\(autoplay) url=\(DebugLog.redact(mediaURL))")
            self.pendingMediaURL = mediaURL
            self.pendingContentType = contentType
            self.pendingStartTime = startTime
            self.timeOffset = timeOffset
            self.pendingAutoplay = autoplay
            self.deferredSeek = nil
            if let msid = self.mediaSessionId { self.staleMediaSessionIds.insert(msid) }
            self.mediaSessionId = nil
            if let tid = self.transportId { self.loadMedia(mediaURL, transport: tid) }
        }
    }

    func play()  { perform { self.sendMedia(["type": "PLAY"]) } }
    func pause() { perform { self.sendMedia(["type": "PAUSE"]) } }

    // Absolute position in the item. Only valid while timeOffset is 0 (a natively seekable
    // source) — CastController re-requests offset streams via load() instead.
    func seek(to seconds: Double) {
        perform {
            let target = max(0, seconds - self.timeOffset)
            if self.mediaSessionId == nil {
                self.deferredSeek = target
            } else {
                self.sendMedia(["type": "SEEK", "currentTime": target])
            }
        }
    }

    // Stop playback + close the session.
    func stop() {
        perform {
            if let tid = self.transportId {
                self.enqueue(namespace: CastNS.receiver, destination: CastSession.platformReceiver,
                             json: ["type": "STOP", "sessionId": tid])
            }
        }
        running = false
        DebugLog.shared.log("CAST", "stop")
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
            reportEnd(.failed("connect failed"))
            return
        }
        DebugLog.shared.log("CAST", "connected \(device.name)")
        report("connected")

        // Virtual-connect + launch the default media receiver.
        enqueue(namespace: CastNS.connection, destination: CastSession.platformReceiver,
                json: ["type": "CONNECT"])
        launchReceiver()

        var inbound = [UInt8]()
        var recvBuf = [UInt8](repeating: 0, count: 16 * 1024)

        while running {
            runCommands()
            flushOutbound(h)
            heartbeatIfDue()
            statusPollIfDue()

            let n = curl_bridge_recv(h, &recvBuf, recvBuf.count, 500)   // 500ms poll window
            if n < 0 {
                DebugLog.shared.log("CAST", "disconnected")
                report("disconnected")
                if running && !endReported { reportEnd(.failed("disconnected")) }
                break
            }
            if n > 0 {
                inbound.append(contentsOf: recvBuf[0..<Int(n)])
                drainFrames(&inbound)
            }
        }

        // stop() flips `running` right after queueing its STOP, so the loop can exit
        // before running it — drain once more, then tell the device we're leaving.
        runCommands()
        enqueue(namespace: CastNS.connection, destination: transportId ?? CastSession.platformReceiver,
                json: ["type": "CLOSE"])
        flushOutbound(h)
    }

    private func perform(_ block: @escaping () -> Void) {
        lock.lock()
        commands.append(block)
        lock.unlock()
    }

    private func runCommands() {
        lock.lock()
        let pending = commands
        commands.removeAll()
        lock.unlock()
        for block in pending { block() }
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
            if type == "LOAD_FAILED" || type == "LOAD_CANCELLED" || type == "INVALID_REQUEST" {
                handleMediaError(type, obj)
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
        // NSNumber bridging: `as? Double`/`as? Int` silently fail on the 5.1.5 runtime.
        let rid = (obj["requestId"] as? NSNumber)?.intValue ?? 0
        let msid = (first["mediaSessionId"] as? NSNumber)?.intValue
        if let m = msid {
            if staleMediaSessionIds.contains(m) { return }
            if awaitingLoad && rid != loadRequestId && m < firstNewMediaSessionId {
                staleMediaSessionIds.insert(m)
                return
            }
            maxSeenMediaSessionId = max(maxSeenMediaSessionId, m)
        }

        let playerState = (first["playerState"] as? String) ?? ""
        let idleReason = (first["idleReason"] as? String) ?? ""
        let terminal = playerState == "IDLE" && !idleReason.isEmpty

        if terminal {
            // Terminal: never poll or command this media session again.
            if let m = msid { staleMediaSessionIds.insert(m) }
            // No id at all can't be placed — while a LOAD is outstanding, only trust it
            // when it answers that LOAD (a real load failure also arrives as LOAD_FAILED).
            if endReported || (awaitingLoad && msid == nil && rid != loadRequestId) {
                DebugLog.shared.log("CAST", "player IDLE reason=\(idleReason) msid=\(msid ?? -1) (ignored)")
                return
            }
            mediaSessionId = nil
            awaitingLoad = false
            DebugLog.shared.log("CAST", "player IDLE reason=\(idleReason)")
            let end: CastEnd
            switch idleReason {
            case "FINISHED": end = .finished
            case "ERROR":    end = .failed("playback error")
            default:         end = .stoppedRemotely     // CANCELLED / INTERRUPTED
            }
            reportEnd(end)
            return
        }

        if let m = msid, mediaSessionId != m {
            mediaSessionId = m
            awaitingLoad = false
            if let target = deferredSeek {
                deferredSeek = nil
                sendMedia(["type": "SEEK", "currentTime": target])
            }
        }

        guard let cur = (first["currentTime"] as? NSNumber)?.doubleValue else { return }
        // duration lives on the nested media object, only present on some statuses.
        var dur: Double = 0
        if let media = first["media"] as? [String: Any],
           let d = (media["duration"] as? NSNumber)?.doubleValue, d > 0 {
            dur = d
        }
        let position = cur + timeOffset
        DispatchQueue.main.async { [weak self] in self?.onProgress?(position, dur, playerState) }
    }

    private func handleMediaError(_ type: String, _ obj: [String: Any]) {
        let reason = (obj["reason"] as? String) ?? type
        let rid = (obj["requestId"] as? NSNumber)?.intValue ?? 0
        // Only an error answering the latest LOAD ends playback. A rejected SEEK/PLAY, or
        // the LOAD_CANCELLED a superseded reload gets, leaves the current media running.
        guard rid == loadRequestId, type != "LOAD_CANCELLED", !endReported else {
            DebugLog.shared.log("CAST", "\(type) reason=\(reason) req=\(rid) (ignored, load=\(loadRequestId))")
            return
        }
        DebugLog.shared.log("CAST", "LOAD failed: \(type) reason=\(reason)")
        reportEnd(.failed(reason))
    }

    private func reportEnd(_ end: CastEnd) {
        endReported = true
        DispatchQueue.main.async { [weak self] in self?.onEnded?(end) }
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
        loadRequestId = requestId
        awaitingLoad = true
        endReported = false
        firstNewMediaSessionId = maxSeenMediaSessionId + 1
        var media: [String: Any] = [
            "contentId": url,
            "contentType": pendingContentType,
            "streamType": "BUFFERED"
        ]
        if let meta = pendingMetadata { media["metadata"] = meta }
        let payload: [String: Any] = [
            "type": "LOAD",
            "requestId": requestId,
            "autoplay": pendingAutoplay,
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
