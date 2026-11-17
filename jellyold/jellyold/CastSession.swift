import Foundation

// MARK: - CastSession
//
// One TLS connection to a Chromecast (port 8009, via the curl bridge's CONNECT_ONLY socket —
// OpenSSL speaks the modern ciphers iOS 6 can't) and the CASTV2 conversation over it. It plays
// media on the Default Media Receiver in one of two ways:
//   - start(): get the receiver app running (launching it only when it isn't), then LOAD.
//   - join():  attach to media the receiver is ALREADY playing. The phone lost its connection
//              (it slept, or iOS suspended the app on the lock screen) while the TV carried on;
//              nothing is launched or loaded, the media session is adopted as it stands.
// The TV doesn't care which socket its commands arrive on, so a lost connection is replaced
// by a new session that joins — CastController owns that decision.
//
// THREADING: everything TLS runs on ONE background thread (`ioLoop`). OpenSSL SSL_read /
// SSL_write on the same SSL object are not thread-safe, so the socket is never touched from
// two threads. Public methods enqueue a closure that the ioLoop runs between recv polls, so
// all session state is only ever read and written on that one thread. Events go back on the
// main thread.
//
// NOTE: the Chromecast fetches the media URL itself, so it must be the real Jellyfin server
// URL — LocalStreamProxy (127.0.0.1) is unreachable from the device and must not be used here.

// Why the receiver stopped playing the current media.
enum CastEnd {
    case finished              // played to the end
    case failed(String)        // LOAD rejected, or the receiver hit a playback error
    case stoppedRemotely       // stopped from the TV / Google Home / another sender took over
    case disconnected(String)  // the TV couldn't be reached (again); the text says which
}

// What join() found playing on the TV.
struct CastJoin {
    let contentId: String
    // The item id our LOAD put in customData; "" when the receiver doesn't echo it back.
    let itemId: String
    // The offset the session adopted for this media (see CastSession.timeOffset).
    let timeOffset: Double
}

final class CastSession: NSObject {

    enum Event {
        // Connection-level progress: "connected", "app ready", "loading media".
        case state(String)
        // A MEDIA_STATUS for the current media. `position` already includes timeOffset;
        // `playerState` is the receiver's raw PLAYING / PAUSED / BUFFERING / IDLE.
        case progress(position: Double, duration: Double, playerState: String)
        // The current media stopped for good.
        case ended(CastEnd)
        // join() attached to the media already on the TV. Its first .progress follows.
        case joined(CastJoin)
        // join() found nothing to attach to: no receiver app running, or one with no media.
        case nothingToJoin
        // The TV refused to start the Default Media Receiver.
        case launchFailed
        // The TV's volume, 0...1, or -1 when it can't be changed (fixed-volume output).
        case volume(Double)
        // The receiver app went away — stopped from the TV or Google Home, or another app
        // took the screen. The session closes itself after this.
        case appClosed
        // The connection is gone. `lost` is false only when stop()/close() asked for it.
        case closed(lost: Bool)
    }

    let device: CastDevice
    var onEvent: ((Event) -> Void)?

    // A subtitle the receiver draws itself: a WebVTT file it fetches alongside the media,
    // timed to match it.
    struct TextTrack {
        let url: String
        let name: String
    }

    private struct PendingLoad {
        let url: String
        let contentType: String
        let startTime: Double
        let timeOffset: Double
        let autoplay: Bool
        let textTrack: TextTrack?
    }

    // Shared with the caller's thread, guarded by `lock`.
    private let lock = NSLock()
    private var commands = [() -> Void]()
    private var started = false

    // Set before the ioLoop starts; read-only afterwards.
    private var joining = false
    private var itemId = ""
    private var metadata: [String: Any]?
    // join(): what this phone last loaded, so the adopted media gets the right timeOffset.
    private var joinContentId = ""
    private var joinTimeOffset: Double = 0

    // Everything below belongs to the ioLoop thread.
    private var handle: CurlHandle?
    private var requestId = 0
    private var launched = false
    // The receiver app's channel and session, learned from RECEIVER_STATUS.
    private var transportId: String?
    private var appSessionId: String?
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
    // Set once .ended fired for the current LOAD. The receiver often reports one failure
    // twice (LOAD_FAILED + an IDLE/ERROR status), and the second must not end a fallback.
    private var endReported = false
    // join() asked for the media status and is waiting for the first answer.
    private var awaitingJoin = false
    // A LOAD waiting for the receiver app to come up.
    private var pendingLoad: PendingLoad?
    // Added to every position the receiver reports. Non-zero when the URL itself starts
    // mid-file (a re-requested progressive stream), whose timeline the receiver sees as 0-based.
    private var timeOffset: Double = 0
    // A SEEK asked for before the receiver assigned a mediaSessionId; sent with the first status.
    private var deferredSeek: Double?
    private var lastVolume: Double = -2

    private var lastHeartbeat = Date()
    private var lastStatusPoll = Date()
    private var lastInbound = Date()
    // Set by probe(): the connection is presumed dead unless the TV answers by then.
    private var probeDeadline: Date?
    // Set by a stop() made before the receiver app was known: STOP goes out as soon as a
    // RECEIVER_STATUS names it, and the session gives up waiting at this time.
    private var stopDeadline: Date?
    // Why the loop is ending, once it is. nil = keep going.
    private var exitLost: Bool?

    private static let senderId = "sender-0"
    private static let platformReceiver = "receiver-0"
    // The Default Media Receiver — plays a plain media URL, no custom receiver app needed.
    static let mediaReceiverApp = "CC1AD845"
    // The TV answers our 5 s heartbeat and the 1 s status poll, so this long without a byte
    // from it means the connection is gone even when the socket hasn't said so (a suspended
    // app's socket can look open long after the TV dropped it).
    private static let silenceLimit: TimeInterval = 30
    private static let probeTimeout: TimeInterval = 6
    private static let stopTimeout: TimeInterval = 5

    init(device: CastDevice) {
        self.device = device
        super.init()
    }

    // MARK: - Public API (any thread — work is queued for the ioLoop)

    // Connect, get the media receiver running, and LOAD `mediaURL`. `startTime` seeds the
    // receiver's position (resume); `timeOffset` is where the URL itself starts in the item.
    // `itemId` rides in the LOAD's customData, so a later join can recognise the media.
    func start(mediaURL: String, contentType: String, startTime: Double, timeOffset: Double,
               textTrack: TextTrack?, itemId: String, metadata: [String: Any]?) {
        self.itemId = itemId
        self.metadata = metadata
        pendingLoad = PendingLoad(url: mediaURL, contentType: contentType, startTime: startTime,
                                  timeOffset: timeOffset, autoplay: true, textTrack: textTrack)
        DebugLog.shared.log("CAST", "start dev=\(device.name) \(device.host):\(device.port) type=\(contentType) at=\(Int(startTime))s offset=\(Int(timeOffset))s url=\(DebugLog.redact(mediaURL))\(CastSession.describe(textTrack))")
        run(joining: false)
    }

    // Connect and attach to whatever the media receiver is already playing. `contentId` and
    // `timeOffset` are the URL this phone last loaded and its offset: when the TV is still on
    // that URL its positions are read with that offset. `itemId`/`metadata` are for any
    // LOAD sent later on this session (a re-LOAD seek, a fallback source).
    func join(contentId: String, timeOffset: Double, itemId: String, metadata: [String: Any]?) {
        self.itemId = itemId
        self.metadata = metadata
        joinContentId = contentId
        joinTimeOffset = timeOffset
        DebugLog.shared.log("CAST", "join dev=\(device.name) \(device.host):\(device.port)")
        run(joining: true)
    }

    // Replace the media on the running receiver app — used to fall back to another
    // source and to "seek" a stream the receiver can't seek itself.
    func load(mediaURL: String, contentType: String, startTime: Double, timeOffset: Double,
              autoplay: Bool, textTrack: TextTrack?) {
        perform {
            DebugLog.shared.log("CAST", "reload type=\(contentType) at=\(Int(startTime))s offset=\(Int(timeOffset))s autoplay=\(autoplay) url=\(DebugLog.redact(mediaURL))\(CastSession.describe(textTrack))")
            self.deferredSeek = nil
            let p = PendingLoad(url: mediaURL, contentType: contentType, startTime: startTime,
                                timeOffset: timeOffset, autoplay: autoplay, textTrack: textTrack)
            if let tid = self.transportId { self.sendLoad(p, transport: tid) } else { self.pendingLoad = p }
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

    // The TV's own volume (the receiver's, not the media's), 0...1.
    func setVolume(_ level: Double) {
        let v = min(1, max(0, level))
        perform {
            // The TV echoes the new level in a RECEIVER_STATUS; that is not news.
            self.lastVolume = v
            self.send(CastNS.receiver, to: CastSession.platformReceiver,
                      ["type": "SET_VOLUME", "volume": ["level": v], "requestId": self.nextRequestId()])
        }
    }

    // Ask the TV for its status now and give up on the connection if it doesn't answer
    // within a few seconds — called when the app comes back to the foreground, since a
    // socket that sat through a suspension can look open long after the TV dropped it.
    func probe() {
        perform {
            self.probeDeadline = Date().addingTimeInterval(CastSession.probeTimeout)
            self.requestReceiverStatus()
        }
    }

    // Stop the receiver app on the TV (back to its ambient screen), then close. Before the
    // app is known (still launching, or a join that hasn't heard back) the STOP waits for
    // the first RECEIVER_STATUS that names it.
    func stop() {
        perform {
            self.pendingLoad = nil
            self.awaitingJoin = false
            if self.appSessionId != nil {
                self.sendStopApp()
            } else {
                self.stopDeadline = Date().addingTimeInterval(CastSession.stopTimeout)
            }
        }
        DebugLog.shared.log("CAST", "stop")
    }

    // Close the connection and leave the TV as it is.
    func close() {
        perform { self.exitLost = false }
    }

    private func run(joining: Bool) {
        lock.lock()
        let first = !started
        started = true
        lock.unlock()
        guard first else { return }
        self.joining = joining
        let t = Thread(target: self, selector: #selector(ioLoop), object: nil)
        t.stackSize = 512 * 1024
        t.start()
    }

    private func perform(_ block: @escaping () -> Void) {
        lock.lock()
        commands.append(block)
        lock.unlock()
    }

    // MARK: - I/O loop (single thread; owns the socket and all protocol state)

    @objc private func ioLoop() {
        CurlFetcher.ensureGlobalInit()
        guard let h = curl_bridge_init() else { emit(.closed(lost: true)); return }
        handle = h
        defer { curl_bridge_cleanup(h); handle = nil }

        let rc = device.host.withCString { curl_bridge_connect_only(h, $0, device.port) }
        guard rc == 0 else {
            let msg = String(cString: curl_bridge_strerror(rc))
            DebugLog.shared.log("CAST", "connect FAILED rc=\(rc) (\(msg))")
            emit(.closed(lost: true))
            return
        }
        DebugLog.shared.log("CAST", "connected \(device.name) mode=\(joining ? "join" : "start")")
        emit(.state("connected"))
        lastInbound = Date()

        // Ask what is running first: an app that is already up is joined or reused, and
        // only a missing one is launched.
        send(CastNS.connection, to: CastSession.platformReceiver, ["type": "CONNECT"])
        requestReceiverStatus()

        var inbound = [UInt8]()
        var recvBuf = [UInt8](repeating: 0, count: 16 * 1024)

        while exitLost == nil {
            runCommands()
            if exitLost != nil { break }
            heartbeatIfDue()
            statusPollIfDue()

            let n = curl_bridge_recv(h, &recvBuf, recvBuf.count, 500)   // 500ms poll window
            if n < 0 {
                DebugLog.shared.log("CAST", "socket closed by \(device.name)")
                exitLost = true
                break
            }
            if n > 0 {
                lastInbound = Date()
                probeDeadline = nil
                inbound.append(contentsOf: recvBuf[0..<Int(n)])
                drainFrames(&inbound)
            }
            guard exitLost == nil else { break }
            let now = Date()
            if let d = probeDeadline, now > d {
                DebugLog.shared.log("CAST", "probe unanswered — connection presumed dead")
                exitLost = true
            } else if let d = stopDeadline, now > d {
                DebugLog.shared.log("CAST", "stop: receiver app never showed up, leaving")
                exitLost = false
            } else if now.timeIntervalSince(lastInbound) > CastSession.silenceLimit {
                DebugLog.shared.log("CAST", "no word from \(device.name) for \(Int(CastSession.silenceLimit))s")
                exitLost = true
            }
        }

        let lost = exitLost ?? true
        if !lost {
            // Best effort: leave the receiver's channel and the platform's politely.
            if let tid = transportId { send(CastNS.connection, to: tid, ["type": "CLOSE"]) }
            send(CastNS.connection, to: CastSession.platformReceiver, ["type": "CLOSE"])
        }
        DebugLog.shared.log("CAST", "session closed lost=\(lost)")
        emit(.closed(lost: lost))
    }

    private func runCommands() {
        lock.lock()
        let pending = commands
        commands.removeAll()
        lock.unlock()
        for block in pending {
            block()
            if exitLost != nil { return }
        }
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
            if exitLost != nil { return }
        }
    }

    private func heartbeatIfDue() {
        if Date().timeIntervalSince(lastHeartbeat) >= 5 {
            lastHeartbeat = Date()
            send(CastNS.heartbeat, to: CastSession.platformReceiver, ["type": "PING"])
        }
    }

    // Poll the receiver for a fresh MEDIA_STATUS ~once/sec so the scrubber tracks playback
    // (Chromecast only pushes status on state changes, not continuously).
    private func statusPollIfDue() {
        guard let tid = transportId, let msid = mediaSessionId else { return }
        if Date().timeIntervalSince(lastStatusPoll) >= 1 {
            lastStatusPoll = Date()
            send(CastNS.media, to: tid,
                 ["type": "GET_STATUS", "mediaSessionId": msid, "requestId": nextRequestId()])
        }
    }

    // MARK: - Incoming message handling

    private func handle(_ msg: CastMessage) {
        guard let obj = jsonObject(msg.payloadUtf8) else { return }
        let type = (obj["type"] as? String) ?? ""

        switch msg.namespace {
        case CastNS.heartbeat:
            if type == "PING" { send(CastNS.heartbeat, to: msg.sourceId, ["type": "PONG"]) }
        case CastNS.connection:
            // The receiver app closing its channel to us is the app going away.
            if type == "CLOSE", let tid = transportId, msg.sourceId == tid { receiverAppGone() }
        case CastNS.receiver:
            if type == "RECEIVER_STATUS" {
                handleReceiverStatus(obj)
            } else if type == "LAUNCH_ERROR" {
                DebugLog.shared.log("CAST", "LAUNCH_ERROR \(msg.payloadUtf8)")
                emit(.launchFailed)
            }
        case CastNS.media:
            if type == "MEDIA_STATUS" { handleMediaStatus(obj) }
            if type == "LOAD_FAILED" || type == "LOAD_CANCELLED" || type == "INVALID_REQUEST" {
                handleMediaError(type, obj)
            }
        default:
            break
        }
    }

    // Find the media receiver among the running apps: connect to it, then LOAD (start) or
    // read back what it is playing (join). Its absence is news too — the app closed.
    private func handleReceiverStatus(_ obj: [String: Any]) {
        guard let st = obj["status"] as? [String: Any] else { return }
        // NSNumber bridging: `as? Double`/`as? Int` silently fail on the 5.1.5 runtime.
        if let vol = st["volume"] as? [String: Any],
           let raw = (vol["level"] as? NSNumber)?.doubleValue {
            let level = (vol["controlType"] as? String) == "fixed" ? -1 : raw
            if abs(level - lastVolume) > 0.001 {
                lastVolume = level
                emit(.volume(level))
            }
        }
        let apps = (st["applications"] as? [[String: Any]]) ?? []
        guard let app = apps.first(where: { ($0["appId"] as? String) == CastSession.mediaReceiverApp }),
              let tid = app["transportId"] as? String else {
            if stopDeadline != nil {
                // Nothing running and nothing on its way up: nothing to stop.
                if !launched { exitLost = false }
            } else if transportId != nil {
                receiverAppGone()
            } else if joining {
                DebugLog.shared.log("CAST", "join: media receiver not running")
                emit(.nothingToJoin)
                exitLost = false
            } else if !launched {
                launched = true
                send(CastNS.receiver, to: CastSession.platformReceiver,
                     ["type": "LAUNCH", "appId": CastSession.mediaReceiverApp, "requestId": nextRequestId()])
            }
            return
        }
        appSessionId = (app["sessionId"] as? String) ?? tid
        if stopDeadline != nil {
            sendStopApp()
            return
        }
        if transportId == tid { return }   // already connected to this app
        transportId = tid
        emit(.state("app ready"))
        send(CastNS.connection, to: tid, ["type": "CONNECT"])
        if joining {
            awaitingJoin = true
            send(CastNS.media, to: tid, ["type": "GET_STATUS", "requestId": nextRequestId()])
        }
        if let p = pendingLoad {
            pendingLoad = nil
            sendLoad(p, transport: tid)
        }
    }

    private func receiverAppGone() {
        DebugLog.shared.log("CAST", "media receiver closed on \(device.name)")
        transportId = nil
        mediaSessionId = nil
        emit(.appClosed)
        exitLost = false
    }

    private func handleMediaStatus(_ obj: [String: Any]) {
        let arr = (obj["status"] as? [[String: Any]]) ?? []
        guard let first = arr.first else {
            // No media session on the receiver at all.
            if awaitingJoin {
                awaitingJoin = false
                DebugLog.shared.log("CAST", "join: receiver has no media")
                emit(.nothingToJoin)
                exitLost = false
            }
            return
        }
        // NSNumber bridging: `as? Double`/`as? Int` silently fail on the 5.1.5 runtime.
        let rid = (obj["requestId"] as? NSNumber)?.intValue ?? 0
        let msid = (first["mediaSessionId"] as? NSNumber)?.intValue

        if awaitingJoin {
            awaitingJoin = false
            adoptJoinedMedia(first)
            // Then handled like any status: an ended media ends, anything else is adopted.
        }

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
            // Whether the receiver took the subtitle track and turned it on.
            let tracks = ((first["media"] as? [String: Any])?["tracks"] as? [Any])?.count ?? 0
            let active = ((first["activeTrackIds"] as? [NSNumber]) ?? []).map { $0.stringValue }
            DebugLog.shared.log("CAST", "media session \(m): tracks=\(tracks) active=[\(active.joined(separator: ","))]")
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
        emit(.progress(position: cur + timeOffset, duration: dur, playerState: playerState))
    }

    // The first status after a join: learn which media this is and the offset its positions
    // need. The URL this phone last loaded is the surest match; otherwise our own LOAD's
    // customData carries the offset it was made with.
    private func adoptJoinedMedia(_ first: [String: Any]) {
        let media = first["media"] as? [String: Any]
        let contentId = (media?["contentId"] as? String) ?? ""
        let custom = media?["customData"] as? [String: Any]
        let id = (custom?["itemId"] as? String) ?? ""
        if !joinContentId.isEmpty && contentId == joinContentId {
            timeOffset = joinTimeOffset
        } else if let off = (custom?["timeOffset"] as? NSNumber)?.doubleValue {
            timeOffset = off
        } else {
            timeOffset = 0
        }
        let state = (first["playerState"] as? String) ?? ""
        DebugLog.shared.log("CAST", "join: \(state) item=\(id.isEmpty ? "?" : id) offset=\(Int(timeOffset))s sameURL=\(contentId == joinContentId)")
        emit(.joined(CastJoin(contentId: contentId, itemId: id, timeOffset: timeOffset)))
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
        emit(.ended(end))
    }

    // MARK: - Outbound

    private func sendLoad(_ p: PendingLoad, transport: String) {
        // A new media session is coming; the old one's statuses must not be read as its.
        if let msid = mediaSessionId { staleMediaSessionIds.insert(msid) }
        mediaSessionId = nil
        timeOffset = p.timeOffset
        let rid = nextRequestId()
        loadRequestId = rid
        awaitingLoad = true
        endReported = false
        firstNewMediaSessionId = maxSeenMediaSessionId + 1
        var media: [String: Any] = [
            "contentId": p.url,
            "contentType": p.contentType,
            "streamType": "BUFFERED",
            // How a later join (after the phone slept) recognises this media and reads its
            // positions: the receiver hands customData back in its statuses.
            "customData": ["itemId": itemId, "timeOffset": p.timeOffset]
        ]
        if let meta = metadata { media["metadata"] = meta }
        var payload: [String: Any] = [
            "type": "LOAD",
            "requestId": rid,
            "autoplay": p.autoplay,
            "currentTime": p.startTime,
            "media": media
        ]
        if let track = p.textTrack {
            media["tracks"] = [[
                "trackId": 1,
                "type": "TEXT",
                "subtype": "SUBTITLES",
                "trackContentId": track.url,
                "trackContentType": "text/vtt",
                "name": track.name
            ]]
            // Like the phone draws them: white with a dark outline, no box behind.
            media["textTrackStyle"] = [
                "foregroundColor": "#FFFFFFFF",
                "backgroundColor": "#00000000",
                "edgeType": "OUTLINE",
                "edgeColor": "#000000FF"
            ]
            payload["media"] = media
            payload["activeTrackIds"] = [1]
        }
        send(CastNS.media, to: transport, payload)
        emit(.state("loading media"))
    }

    private static func describe(_ track: TextTrack?) -> String {
        guard let t = track else { return "" }
        return " sub=\"\(t.name)\" \(DebugLog.redact(t.url))"
    }

    private func sendMedia(_ base: [String: Any]) {
        guard let tid = transportId, let msid = mediaSessionId else { return }
        var json = base
        json["mediaSessionId"] = msid
        json["requestId"] = nextRequestId()
        send(CastNS.media, to: tid, json)
    }

    private func sendStopApp() {
        if let sid = appSessionId {
            send(CastNS.receiver, to: CastSession.platformReceiver,
                 ["type": "STOP", "sessionId": sid, "requestId": nextRequestId()])
        }
        exitLost = false
    }

    private func requestReceiverStatus() {
        send(CastNS.receiver, to: CastSession.platformReceiver,
             ["type": "GET_STATUS", "requestId": nextRequestId()])
    }

    private func nextRequestId() -> Int {
        requestId += 1
        return requestId
    }

    // Write one CastMessage frame. ioLoop thread only. A write that fails means the socket
    // is gone, which ends the loop.
    private func send(_ namespace: String, to destination: String, _ json: [String: Any]) {
        guard let h = handle, exitLost != true else { return }
        let msg = CastMessage(sourceId: CastSession.senderId, destinationId: destination,
                              namespace: namespace, payloadUtf8: jsonString(json))
        let data = msg.framed()
        let sent = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return Int(curl_bridge_send(h, base, data.count))
        }
        if sent < 0 {
            DebugLog.shared.log("CAST", "send failed — connection lost")
            exitLost = true
        }
    }

    private func emit(_ e: Event) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(e) }
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
}
