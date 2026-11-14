import UIKit

// MARK: - CastSource
//
// One way of getting an item onto the receiver. CastController tries an item's sources in
// order and moves to the next one if the receiver rejects or fails on the current one.
struct CastSource {
    let contentType: String
    // false: the receiver can seek the stream itself (an HLS VOD playlist, or a file served
    //        with a Content-Length) — `url` is built once from 0 and positions go out as SEEK.
    // true:  a chunked, length-less transcode the receiver can only play forward. Seeking
    //        re-requests the stream from the new position, so `url` takes the start time.
    let seeksByReloading: Bool
    let url: (Double) -> String?
}

// MARK: - CastController
//
// App-lifetime owner of the Chromecast cast, so it survives navigating away from the screen
// that started it (CastVC and the mini bar are just views onto this).
//
// A cast also survives losing its connection. iOS suspends the app soon after the screen
// locks (background audio only covers the phone playing sound, and it is silent while
// casting), the TV stops hearing the heartbeat and drops the socket, and the item carries on
// playing on the TV. So the connection is replaced instead of the cast ending: a new session
// JOINS the media already on the TV — no launch, no load, position and play state as they
// stand. That happens on the way back from the lock screen, after a dropped socket while the
// app is in front (3 tries), and on a cold launch after iOS killed the app, from a record
// kept in UserDefaults. A background task keeps the socket for the few minutes iOS allows,
// so a short lock costs nothing. The cast ends when it is stopped here, stopped from the TV,
// or the TV can't be reached again.
//
// CastSession reports through a single event slot, claimed here; CastVC binds this object's
// own slots (same pattern AudioPlayer uses for NowPlayingVC). The mini bar polls.
//
// IMPORTANT: a Chromecast fetches the media URL itself over the LAN. Every URL handed to
// `start` must therefore be the real Jellyfin server URL — never a LocalStreamProxy
// 127.0.0.1 URL, which is unreachable from the device.
final class CastController {

    static let shared = CastController()
    private init() {}

    // Media kind being cast — decides which resume key applies and whether the
    // transport controls make sense at all.
    enum Kind: String {
        case video, audio, photo
    }

    // Where the connection to the TV stands while a cast is on.
    enum Link {
        case connecting     // first connection, nothing has played yet
        case connected
        case reconnecting   // lost it; joining the TV again
    }

    private(set) var device: CastDevice?
    private(set) var item: MediaItem?
    private(set) var kind: Kind = .video
    private(set) var link = Link.connecting
    // Human-readable status line for CastVC.
    private(set) var state = ""
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    // The TV's volume, 0...1; -1 until it has said, or when its output is fixed.
    private(set) var volume: Double = -1

    // Position the UI should show: a seek the receiver hasn't caught up with yet wins over
    // the last reported position, so the scrubber doesn't snap back while Jellyfin restarts
    // the transcode at the new point.
    var currentTime: Double { return seekTarget ?? reportedTime }
    var isSeeking: Bool { return seekTarget != nil }

    // A cast is on — including while its connection is being re-established.
    var isCasting: Bool { return item != nil }
    var isReconnecting: Bool { return isCasting && link == .reconnecting }
    var deviceName: String { return device?.name ?? "" }

    // One line for the mini bar: "Playing on Living Room TV".
    var statusText: String {
        let name = deviceName.isEmpty ? "TV" : deviceName
        switch link {
        case .connecting:   return "Connecting to \(name)\u{2026}"
        case .reconnecting: return "Reconnecting to \(name)\u{2026}"
        case .connected:    break
        }
        if kind == .photo { return "Showing on \(name)" }
        if !sourceStarted { return "Loading on \(name)\u{2026}" }
        if isSeeking || isBuffering { return "Buffering on \(name)\u{2026}" }
        return isPlaying ? "Playing on \(name)" : "Paused on \(name)"
    }

    // Bound by CastVC in viewWillAppear, cleared in viewWillDisappear. onEnded fires after
    // the cast has already been torn down here — the screen only has to leave.
    var onState: ((String) -> Void)?
    var onProgress: ((Double, Double, Bool) -> Void)?
    var onEnded: ((CastEnd) -> Void)?

    private var session: CastSession?
    private var reportedTime: Double = 0
    private var seekTarget: Double?
    // When the held seek actually went out; nil while a skip is still debouncing.
    private var seekCommittedAt: CFAbsoluteTime?
    // Bumped by every seek; a pending skip only fires if no newer seek replaced it.
    private var seekGen = 0
    // Play/pause is shown optimistically; a status already in flight would flip it back.
    private var playStateHoldUntil: CFAbsoluteTime = 0

    private var sources = [CastSource]()
    private var sourceIndex = 0
    // The current source reached PLAYING/PAUSED since its last LOAD (watchdog).
    private var sourceStarted = false
    private var loadGen = 0
    // The URL last handed to the receiver and where it starts in the item: what a rejoin
    // recognises the TV's media by, and how it reads the TV's positions.
    private var contentId = ""
    private var timeOffset: Double = 0

    private var discovery: CastDiscovery?
    private var lastSavedTime: Double = 0
    // Set when the receiver reports the media played to the end, so the teardown
    // that follows doesn't write a resume position sitting at the very end.
    private var didFinish = false
    // Video casts report to Jellyfin like local playback does (see PlaybackReporter);
    // driven from progressReceived rather than a timer. Nil for audio and photos.
    private var reporter: PlaybackReporter?
    // Where this cast started, reported instead of a position under 10 s.
    private var resumeFrom: Double = 0

    // Reconnecting.
    private var joinPending = false
    private var joinGen = 0
    private var reconnectAttempts = 0
    private var reconnectTimer: Timer?
    // The connection dropped while the app was in the background; rejoin when it comes back.
    private var rejoinOnActive = false
    // Browses while reconnecting, so a TV that came back on another address is found by name.
    private var reconnectDiscovery: CastDiscovery?
    private var bgTask = UIBackgroundTaskIdentifier.invalid

    private static let skipDebounce: TimeInterval = 0.6
    // A receiver lands on a segment/keyframe boundary, not the exact second asked for.
    private static let seekTolerance: Double = 8
    // How long a seek may go unconfirmed before the scrubber falls back to what the
    // receiver reports (a rejected SEEK would otherwise freeze it).
    private static let seekHoldTimeout: CFAbsoluteTime = 20
    // A transcode that hasn't produced a frame by now isn't going to.
    private static let loadTimeout: TimeInterval = 45
    private static let maxReconnectAttempts = 3
    private static let reconnectDelays: [TimeInterval] = [0.5, 2, 5]
    // A join that has connected but heard nothing about the media by now is treated as lost.
    private static let joinTimeout: TimeInterval = 15

    // MARK: - Discovery

    // Browses for `timeout` seconds, then reports whatever was found. Bonjour has no
    // "done" signal, so a fixed window is the only way to decide the list is complete.
    func discoverDevices(timeout: TimeInterval = 3.0, completion: @escaping ([CastDevice]) -> Void) {
        let disco = CastDiscovery()
        discovery = disco
        var found = [CastDevice]()
        disco.onUpdate = { devices in found = devices }
        disco.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            disco.stop()
            self?.discovery = nil
            DebugLog.shared.log("CAST", "discovery found \(found.count) device(s): \(found.map { $0.name }.joined(separator: ", "))")
            completion(found)
        }
    }

    // MARK: - Cast lifecycle

    // Single fixed URL the receiver can seek natively (photos).
    func start(item: MediaItem, kind: Kind, device: CastDevice,
               url: String, contentType: String, startTime: Double) {
        let source = CastSource(contentType: contentType, seeksByReloading: false) { _ in url }
        start(item: item, kind: kind, device: device, sources: [source], startTime: startTime)
    }

    func start(item: MediaItem, kind: Kind, device: CastDevice,
               sources: [CastSource], startTime: Double) {
        // Only one cast at a time. On the same TV the receiver app stays up and the new LOAD
        // replaces what it shows; another TV goes back to its own screen.
        let sameTV = self.device.map { $0.host == device.host } ?? false
        teardown(remote: sameTV ? .close : .stop)
        guard let first = sources.first,
              let url = first.url(first.seeksByReloading ? startTime : 0) else { return }

        // The phone gives way to the TV. A photo leaves music playing.
        if kind != .photo { AudioPlayer.shared.pause() }

        self.item = item
        self.kind = kind
        self.device = device
        self.sources = sources
        sourceIndex = 0
        link = .connecting
        state = "Connecting\u{2026}"
        reportedTime = startTime
        seekTarget = nil
        // runTimeTicks is the authoritative length — see progressReceived.
        duration = item.runTimeTicks.map { Double($0) / 10_000_000 } ?? 0
        isPlaying = false
        isBuffering = false
        volume = -1
        playStateHoldUntil = 0
        lastSavedTime = startTime
        didFinish = false
        resumeFrom = startTime
        reconnectAttempts = 0
        reporter = kind == .video ? makeReporter(item) : nil
        contentId = url
        timeOffset = first.seeksByReloading ? startTime : 0
        saveRecord()

        let s = makeSession(device)
        s.start(mediaURL: url, contentType: first.contentType,
                startTime: first.seeksByReloading ? 0 : startTime,
                timeOffset: timeOffset, itemId: item.id,
                metadata: metadata(for: item, kind: kind))
        armLoadWatchdog()
    }

    // Stop casting: the TV goes back to its own screen.
    func stop() {
        teardown(remote: .stop)
    }

    private enum Remote { case stop, close }

    // Ends the cast on the phone's side. `.stop` also sends the TV back to its own screen;
    // `.close` just hangs up and leaves the TV as it is.
    private func teardown(remote: Remote) {
        guard isCasting else { return }
        if !didFinish {
            savePosition(currentTime)
            reporter?.stop(at: currentTime > 10 ? currentTime : resumeFrom)
        }
        reporter = nil
        if let s = session {
            if remote == .stop { s.stop() } else { s.close() }
        } else if remote == .stop, let d = device {
            // Between reconnect attempts there is no connection to send STOP on: open one
            // just for that, so Stop still stops the TV. Nothing listens to it.
            let s = CastSession(device: d)
            s.join(contentId: "", timeOffset: 0, itemId: "", metadata: nil)
            s.stop()
        }
        DebugLog.shared.log("CAST", "cast ended (\(remote == .stop ? "stop" : "close"))")
        session = nil
        device = nil
        item = nil
        sources = []
        link = .connecting
        state = ""
        reportedTime = 0
        seekTarget = nil
        seekCommittedAt = nil
        duration = 0
        isPlaying = false
        isBuffering = false
        volume = -1
        contentId = ""
        timeOffset = 0
        joinPending = false
        // Orphan any pending skip / load watchdog / join watchdog.
        seekGen += 1
        loadGen += 1
        joinGen += 1
        cancelReconnect()
        endBackgroundHold()
        clearRecord()
    }

    // The cast is over for a reason the screen may want to show: tear down, then tell it.
    private func finishCast(_ end: CastEnd, remote: Remote) {
        let notify = onEnded
        teardown(remote: remote)
        notify?(end)
    }

    private func makeSession(_ d: CastDevice) -> CastSession {
        let s = CastSession(device: d)
        // Events from a session that has since been replaced (another cast, a reconnect)
        // are dropped, so a late status from it can't leak into this one.
        s.onEvent = { [weak self, weak s] e in
            guard let self = self, let s = s, self.session === s else { return }
            self.handle(e)
        }
        session = s
        return s
    }

    private func makeReporter(_ item: MediaItem) -> PlaybackReporter {
        return PlaybackReporter(item: item,
                                playSessionId: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                                playMethod: "Transcode")
    }

    // MARK: - Transport

    private var canControl: Bool { return session != nil && link != .reconnecting }

    func togglePlayPause() {
        guard let s = session, canControl else { return }
        if isPlaying { s.pause() } else { s.play() }
        isPlaying = !isPlaying
        playStateHoldUntil = CFAbsoluteTimeGetCurrent() + 2
        emitProgress()
    }

    // Absolute seek (scrubber release) — sent immediately.
    func seek(to seconds: Double) {
        guard canControl, kind != .photo else { return }
        let t = clamped(seconds)
        holdSeek(t)
        commitSeek(t)
    }

    // Relative skip. Rapid taps stack on the pending target and go out as a single seek,
    // so three taps on +30 is one jump of 90 s rather than three transcode restarts.
    func seek(by delta: Double) {
        guard canControl, kind != .photo else { return }
        let t = clamped(currentTime + delta)
        holdSeek(t)
        let gen = seekGen
        DispatchQueue.main.asyncAfter(deadline: .now() + CastController.skipDebounce) { [weak self] in
            guard let self = self, self.seekGen == gen, let target = self.seekTarget else { return }
            self.commitSeek(target)
        }
    }

    // The TV's own volume, 0...1.
    func setVolume(_ level: Double) {
        guard let s = session, canControl, volume >= 0 else { return }
        volume = min(1, max(0, level))
        s.setVolume(volume)
    }

    private func clamped(_ t: Double) -> Double {
        var v = max(0, t)
        if duration > 1 { v = min(v, duration - 1) }
        return v
    }

    private func holdSeek(_ t: Double) {
        seekGen += 1
        seekTarget = t
        seekCommittedAt = nil
        state = "Seeking\u{2026}"
        onState?(state)
        emitProgress()
    }

    private func commitSeek(_ t: Double) {
        guard canControl, sourceIndex < sources.count else { return }
        let reload = sources[sourceIndex].seeksByReloading
        seekCommittedAt = CFAbsoluteTimeGetCurrent()
        DebugLog.shared.log("CAST", "seek to \(Int(t))s via \(reload ? "reload" : "SEEK")")
        if reload {
            // A paused cast stays paused across the re-request.
            loadCurrentSource(at: t, autoplay: isPlaying)
        } else {
            session?.seek(to: t)
        }
    }

    private func loadCurrentSource(at t: Double, autoplay: Bool) {
        guard let s = session, sourceIndex < sources.count else { return }
        let src = sources[sourceIndex]
        guard let url = src.url(src.seeksByReloading ? t : 0) else {
            mediaEnded(.failed("no stream URL"))
            return
        }
        contentId = url
        timeOffset = src.seeksByReloading ? t : 0
        saveRecord()
        s.load(mediaURL: url, contentType: src.contentType,
               startTime: src.seeksByReloading ? 0 : t,
               timeOffset: timeOffset,
               autoplay: autoplay)
        armLoadWatchdog()
    }

    // A receiver that accepts a LOAD but never starts playing (a stalled transcode, a
    // stream it silently can't decode) is treated as a failure, so the next source
    // gets a chance instead of the screen sitting on "Buffering" forever.
    private func armLoadWatchdog() {
        loadGen += 1
        sourceStarted = false
        guard kind != .photo else { return }   // an image never reports PLAYING
        let gen = loadGen
        DispatchQueue.main.asyncAfter(deadline: .now() + CastController.loadTimeout) { [weak self] in
            guard let self = self, self.loadGen == gen, self.isCasting, !self.sourceStarted else { return }
            guard self.link == .connected else {
                // No connection to judge the receiver by — look again once there is one.
                self.armLoadWatchdog()
                return
            }
            DebugLog.shared.log("CAST", "no playback \(Int(CastController.loadTimeout))s after LOAD")
            self.mediaEnded(.failed("the TV never started playing"))
        }
    }

    // MARK: - Session events

    private func handle(_ e: CastSession.Event) {
        switch e {
        case .state(let text):
            connectionStateChanged(text)
        case .progress(let position, let dur, let playerState):
            markConnected()
            progressReceived(position, dur, playerState)
        case .ended(let end):
            mediaEnded(end)
        case .joined(let j):
            markConnected()
            joined(j)
        case .nothingToJoin:
            // Finished or stopped from the TV while we were away, and the receiver has moved
            // on. Which one can't be told, so the resume point stays where it was last seen.
            DebugLog.shared.log("CAST", "rejoin: nothing playing on the TV any more")
            finishCast(.stoppedRemotely, remote: .close)
        case .launchFailed:
            finishCast(.failed("the TV couldn't start its media player"), remote: .close)
        case .volume(let level):
            volume = level
            emitProgress()
        case .appClosed:
            // Stopped from the TV or Google Home, or another app took the screen.
            finishCast(.stoppedRemotely, remote: .close)
        case .closed(let lost):
            session = nil
            if lost {
                connectionLost()
            } else {
                finishCast(.stoppedRemotely, remote: .close)
            }
        }
    }

    private func connectionStateChanged(_ text: String) {
        // A rejoining session says "connected"/"app ready" too; the screen keeps saying
        // "Reconnecting" until the TV's media has actually been picked back up.
        guard link != .reconnecting else { return }
        switch text {
        case "connected", "app ready": state = "Starting receiver\u{2026}"
        case "loading media": state = "Loading\u{2026}"
        default: state = text
        }
        onState?(state)
    }

    private func markConnected() {
        guard link != .connected else { return }
        DebugLog.shared.log("CAST", "connected (was \(link))")
        link = .connected
        reconnectAttempts = 0
        stopReconnectBrowsing()
    }

    private func joined(_ j: CastJoin) {
        guard joinPending, let item = item else { return }
        joinPending = false
        joinGen += 1
        // Ours if it's the URL this phone last loaded, or our LOAD's customData names the item.
        let ours = (!contentId.isEmpty && j.contentId == contentId) || (!j.itemId.isEmpty && j.itemId == item.id)
        guard ours else {
            DebugLog.shared.log("CAST", "rejoin: the TV is playing something else — leaving it alone")
            finishCast(.stoppedRemotely, remote: .close)
            return
        }
        if j.contentId != contentId {
            // The last LOAD never reached the TV; it is still on the one before.
            contentId = j.contentId
            timeOffset = j.timeOffset
            saveRecord()
        }
        // The first status (right behind this) says whether it is actually playing, and
        // starts the Jellyfin report if a restored cast hasn't one yet. The watchdog covers a
        // join that lands on a source still struggling to start.
        armLoadWatchdog()
    }

    private func progressReceived(_ cur: Double, _ dur: Double, _ playerState: String) {
        reportedTime = cur
        let reload = sourceIndex < sources.count && sources[sourceIndex].seeksByReloading
        // runTimeTicks wins: a chunked transcode has no length up front, so the receiver's
        // duration is just how much it has buffered so far (it grows as the transcode runs —
        // the scrubber looked like a buffer bar), and an offset stream's covers only the rest.
        if duration <= 0, dur > 0, !reload { duration = dur }

        if playerState == "PLAYING" || playerState == "PAUSED" { sourceStarted = true }
        isBuffering = playerState == "BUFFERING"
        if CFAbsoluteTimeGetCurrent() >= playStateHoldUntil {
            isPlaying = playerState == "PLAYING" || playerState == "BUFFERING"
        }

        // Release the held seek once the receiver is there, or once it has settled
        // (PLAYING/PAUSED a moment after the SEEK) somewhere else — a rejected or
        // keyframe-snapped seek must not leave the scrubber frozen.
        if let target = seekTarget, let committed = seekCommittedAt {
            let since = CFAbsoluteTimeGetCurrent() - committed
            let settled = since > 2 && (playerState == "PLAYING" || playerState == "PAUSED")
            if abs(cur - target) < CastController.seekTolerance || settled
                || since > CastController.seekHoldTimeout {
                seekTarget = nil
                seekCommittedAt = nil
            }
        }

        if kind == .photo {
            state = "Showing on TV"
        } else if seekTarget != nil {
            state = "Seeking\u{2026}"
        } else {
            switch playerState {
            case "PLAYING":   state = "Playing"
            case "PAUSED":    state = "Paused"
            case "BUFFERING": state = "Buffering\u{2026}"
            default:          state = "Loading\u{2026}"
            }
        }
        savePositionIfDue(currentTime)
        // Started = the receiver actually played, so a cast that never loads reports nothing.
        if let r = reporter, sourceStarted {
            let t = currentTime > 10 ? currentTime : resumeFrom
            if r.isStarted {
                r.progress(at: t, paused: playerState == "PAUSED")
            } else {
                r.start(at: t)
            }
        }
        onState?(state)
        emitProgress()
    }

    private func mediaEnded(_ end: CastEnd) {
        switch end {
        case .finished:
            didFinish = true
            clearResume()
            // A restored cast that finished on the TV while the phone was away never got to
            // report a start; it still has to tell Jellyfin the item was watched.
            if let r = reporter, !r.isStarted { r.start(at: resumeFrom) }
            reporter?.finish()
            reporter = nil
            // The TV goes back to its own screen.
            finishCast(end, remote: .stop)
        case .failed(let reason):
            // Fall through the source list (HLS -> progressive mp4) before giving up,
            // resuming from wherever the failed source got to.
            if sourceIndex + 1 < sources.count, session != nil {
                sourceIndex += 1
                DebugLog.shared.log("CAST", "source failed (\(reason)), falling back to #\(sourceIndex) \(sources[sourceIndex].contentType) at \(Int(currentTime))s")
                state = "Retrying\u{2026}"
                onState?(state)
                loadCurrentSource(at: currentTime, autoplay: true)
                return
            }
            finishCast(end, remote: .stop)
        case .stoppedRemotely, .disconnected:
            // Someone else has the TV, or there is no TV to talk to: leave it be.
            finishCast(end, remote: .close)
        }
    }

    private func emitProgress() {
        onProgress?(currentTime, duration, isPlaying)
    }

    // MARK: - Reconnecting

    private func connectionLost() {
        guard isCasting else { return }
        joinPending = false
        joinGen += 1
        if link == .connecting {
            // Never got as far as playing: there is nothing on the TV to go back to.
            finishCast(.disconnected("Couldn't connect to \(deviceName)."), remote: .close)
            return
        }
        isBuffering = false
        if UIApplication.shared.applicationState == .background {
            // A suspended app can't hold a connection anyway; try again on the way back.
            DebugLog.shared.log("CAST", "connection lost in the background — rejoin when active")
            rejoinOnActive = true
            setReconnecting()
            return
        }
        guard reconnectAttempts < CastController.maxReconnectAttempts else {
            finishCast(.disconnected("Lost connection to \(deviceName)."), remote: .close)
            return
        }
        reconnectAttempts += 1
        setReconnecting()
        startReconnectBrowsing()
        let delays = CastController.reconnectDelays
        let delay = delays[min(reconnectAttempts - 1, delays.count - 1)]
        reconnectTimer?.invalidate()
        let t = Timer(timeInterval: delay, target: CastTimerTarget { [weak self] in self?.rejoin() },
                      selector: #selector(CastTimerTarget.fire), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
        reconnectTimer = t
    }

    private func setReconnecting() {
        link = .reconnecting
        state = "Reconnecting to \(deviceName)\u{2026}"
        onState?(state)
        emitProgress()
    }

    private func rejoin() {
        reconnectTimer = nil
        guard isCasting, let d = device, let item = item else { return }
        DebugLog.shared.log("CAST", "rejoin attempt \(reconnectAttempts) on \(d.name) \(d.host)")
        joinPending = true
        joinGen += 1
        let gen = joinGen
        let s = makeSession(d)
        s.join(contentId: contentId, timeOffset: timeOffset, itemId: item.id,
               metadata: metadata(for: item, kind: kind))
        // A connection that comes up but never says what the TV is playing counts as lost.
        DispatchQueue.main.asyncAfter(deadline: .now() + CastController.joinTimeout) { [weak self] in
            guard let self = self, self.joinGen == gen, self.joinPending, self.session === s else { return }
            DebugLog.shared.log("CAST", "rejoin: no answer in \(Int(CastController.joinTimeout))s")
            s.close()
            self.session = nil
            self.connectionLost()
        }
    }

    private func cancelReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        rejoinOnActive = false
        stopReconnectBrowsing()
    }

    private func startReconnectBrowsing() {
        guard reconnectDiscovery == nil else { return }
        let d = CastDiscovery()
        d.onUpdate = { [weak self] list in
            guard let self = self, let cur = self.device,
                  let fresh = list.first(where: { $0.name == cur.name }), fresh.host != cur.host else { return }
            // DHCP gave the TV a new address: the next attempt goes there.
            DebugLog.shared.log("CAST", "\(cur.name) moved \(cur.host) -> \(fresh.host)")
            self.device = fresh
            self.saveRecord()
        }
        d.start()
        reconnectDiscovery = d
    }

    private func stopReconnectBrowsing() {
        reconnectDiscovery?.stop()
        reconnectDiscovery = nil
    }

    // MARK: - App lifecycle (from AppDelegate)

    func appDidBecomeActive() {
        endBackgroundHold()
        guard isCasting else {
            restore()
            return
        }
        if rejoinOnActive || session == nil {
            reconnectAttempts = 0
            cancelReconnect()
            setReconnecting()
            rejoin()
        } else {
            // A socket that sat through a suspension can look open long after the TV dropped
            // it; a probe the TV doesn't answer ends it, and the drop rejoins.
            session?.probe()
        }
    }

    // Keep the connection while iOS lets a backgrounded app finish its work (about ten
    // minutes on iOS 6, three from iOS 7): a short lock then costs nothing. After that the
    // app is suspended and the next appDidBecomeActive rejoins.
    func appDidEnterBackground() {
        guard isCasting else { return }
        // The record must be on disk if iOS kills the suspended app.
        UserDefaults.standard.synchronize()
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(expirationHandler: { [weak self] in
            DebugLog.shared.log("CAST", "background hold expired")
            self?.endBackgroundHold()
        })
    }

    private func endBackgroundHold() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    // A cold launch with a cast on record (iOS killed the app in the background): one quiet
    // attempt to pick it back up. The page's URL builders are gone, so the TV's current
    // stream is all there is to seek with — see rebuiltURL.
    private func restore() {
        guard JellyfinServer.isConfigured, let rec = savedRecord() else { return }
        DebugLog.shared.log("CAST", "restoring cast of \(rec.item.id) on \(rec.device.name) \(rec.device.host)")
        item = rec.item
        kind = rec.kind
        device = rec.device
        let stored = rec.contentId
        let reload = rec.seeksByReloading
        sources = [CastSource(contentType: rec.contentType, seeksByReloading: reload) { t in
            CastController.rebuiltURL(stored, startTime: t, seeksByReloading: reload)
        }]
        sourceIndex = 0
        contentId = rec.contentId
        timeOffset = rec.timeOffset
        duration = rec.item.runTimeTicks.map { Double($0) / 10_000_000 } ?? 0
        resumeFrom = savedResumePosition(for: rec.item, kind: rec.kind)
        reportedTime = resumeFrom
        lastSavedTime = resumeFrom
        seekTarget = nil
        isPlaying = false
        isBuffering = false
        volume = -1
        didFinish = false
        reporter = rec.kind == .video ? makeReporter(rec.item) : nil
        setReconnecting()
        reconnectAttempts = CastController.maxReconnectAttempts - 1
        rejoin()
    }

    // A re-LOAD seek on a restored progressive stream: the same request with a new
    // StartTimeTicks and a fresh PlaySessionId (Jellyfin keys a running transcode on it, and
    // a reused one hands back the old job from its old position).
    private static func rebuiltURL(_ url: String, startTime: Double, seeksByReloading: Bool) -> String? {
        guard seeksByReloading else { return url }
        let parts = url.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return url }
        var params = parts[1].split(separator: "&").map(String.init).filter {
            !$0.hasPrefix("StartTimeTicks=") && !$0.hasPrefix("PlaySessionId=")
        }
        params.append("PlaySessionId=\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))")
        if startTime > 0 { params.append("StartTimeTicks=\(Int64(startTime * 10_000_000))") }
        return String(parts[0]) + "?" + params.joined(separator: "&")
    }

    // MARK: - Saved cast (UserDefaults)

    private static let recordKey = "cast_session"

    private struct Record {
        let device: CastDevice
        let item: MediaItem
        let kind: Kind
        let contentId: String
        let timeOffset: Double
        let contentType: String
        let seeksByReloading: Bool
    }

    private func saveRecord() {
        guard let d = device, let item = item, sourceIndex < sources.count, !contentId.isEmpty else { return }
        let src = sources[sourceIndex]
        // NSNumber throughout: numbers read back through `as? Int`/`as? Double` silently
        // fail on the 5.1.5 runtime, so they are written and read as NSNumber.
        let r: [String: Any] = [
            "name": d.name, "host": d.host, "port": NSNumber(value: d.port),
            "serviceName": d.serviceName,
            "item": item.toDict(), "kind": kind.rawValue,
            "contentId": contentId, "timeOffset": NSNumber(value: timeOffset),
            "contentType": src.contentType, "seeksByReloading": NSNumber(value: src.seeksByReloading)
        ]
        UserDefaults.standard.set(r, forKey: CastController.recordKey)
    }

    private func savedRecord() -> Record? {
        guard let r = UserDefaults.standard.dictionary(forKey: CastController.recordKey),
              let name = r["name"] as? String, let host = r["host"] as? String,
              let itemDict = r["item"] as? [String: Any], let item = MediaItem.from(dict: itemDict),
              let kindRaw = r["kind"] as? String, let kind = Kind(rawValue: kindRaw),
              let contentId = r["contentId"] as? String, !contentId.isEmpty,
              let contentType = r["contentType"] as? String else {
            clearRecord()
            return nil
        }
        let port = (r["port"] as? NSNumber)?.intValue ?? 8009
        let d = CastDevice(name: name, host: host, port: port,
                           serviceName: (r["serviceName"] as? String) ?? "")
        return Record(device: d, item: item, kind: kind, contentId: contentId,
                      timeOffset: (r["timeOffset"] as? NSNumber)?.doubleValue ?? 0,
                      contentType: contentType,
                      seeksByReloading: (r["seeksByReloading"] as? NSNumber)?.boolValue ?? false)
    }

    private func clearRecord() {
        UserDefaults.standard.removeObject(forKey: CastController.recordKey)
    }

    // MARK: - Receiver metadata (what the TV shows on screen)

    private func metadata(for item: MediaItem, kind: Kind) -> [String: Any] {
        // metadataType: 0 = generic, 1 = movie, 3 = music track, 4 = photo.
        var meta: [String: Any] = ["title": item.name]
        switch kind {
        case .video:
            meta["metadataType"] = 1
        case .audio:
            meta["metadataType"] = 3
            if let artist = item.artistText { meta["artist"] = artist }
            if let album = item.album { meta["albumName"] = album }
        case .photo:
            meta["metadataType"] = 4
        }
        if let serverURL = JellyfinServer.serverURL {
            meta["images"] = [["url": "\(serverURL)/Items/\(item.id)/Images/Primary?width=400"]]
        }
        return meta
    }

    // MARK: - Resume position (shares VideoPlayerVC / AudioPlayer's keys)

    private var resumeKey: String? {
        guard let item = item else { return nil }
        switch kind {
        case .video: return "resume_\(item.id)"
        case .audio: return "aresume_\(item.id)"
        case .photo: return nil
        }
    }

    // Progress arrives ~once a second; only write every 10s of playback so a
    // long movie doesn't hammer UserDefaults.
    private func savePositionIfDue(_ t: Double) {
        guard abs(t - lastSavedTime) >= 10 else { return }
        lastSavedTime = t
        savePosition(t)
    }

    private func savePosition(_ t: Double) {
        guard let key = resumeKey, let item = item else { return }
        // Same thresholds the local players use: 10s for video, and audio only
        // resumes long-form content so a 3-minute song always restarts.
        let threshold: Double = (kind == .audio) ? 900 : 10
        guard t > 10, duration == 0 || duration > threshold else { return }
        if kind == .video {
            ResumeStore.save(t, for: item.id)   // also stamps when, to weigh against the server's
        } else {
            UserDefaults.standard.set(t, forKey: key)
        }
    }

    private func clearResume() {
        guard let key = resumeKey, let item = item else { return }
        if kind == .video {
            ResumeStore.clear(item.id)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // The position to seed a new cast with, mirroring the local players' rules: video
    // weighs this device's resume point against Jellyfin's (`server`), as VideoPlayerVC does.
    func savedResumePosition(for item: MediaItem, kind: Kind, server: ServerPlayState? = nil) -> Double {
        switch kind {
        case .video:
            return ResumeStore.startPosition(for: item.id, server: server)
        case .audio:
            let saved = UserDefaults.standard.double(forKey: "aresume_\(item.id)")
            return saved > 10 ? saved : 0
        case .photo:
            return 0
        }
    }
}

// Timer target wrapper so the Timer doesn't retain the controller via a selector.
private class CastTimerTarget: NSObject {
    let block: () -> Void
    init(_ b: @escaping () -> Void) { block = b }
    @objc func fire() { block() }
}
