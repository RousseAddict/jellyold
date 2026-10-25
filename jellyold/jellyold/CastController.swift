import Foundation

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
// App-lifetime owner of the Chromecast session, so casting survives navigating away from
// the screen that started it (CastVC is just a view onto this).
//
// CastSession's callbacks are single-slot, so they're claimed here and re-broadcast through
// this object's own slots — same pattern AudioPlayer uses for NowPlayingVC.
//
// IMPORTANT: a Chromecast fetches the media URL itself over the LAN. Every URL handed to
// `start` must therefore be the real Jellyfin server URL — never a LocalStreamProxy
// 127.0.0.1 URL, which is unreachable from the device.
final class CastController {

    static let shared = CastController()
    private init() {}

    // Media kind being cast — decides which resume key applies and whether the
    // transport controls make sense at all.
    enum Kind {
        case video, audio, photo
    }

    private(set) var session: CastSession?
    private(set) var device: CastDevice?
    private(set) var item: MediaItem?
    private(set) var kind: Kind = .video
    // Human-readable status line for CastVC.
    private(set) var state = ""
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false

    // Position the UI should show: a seek the receiver hasn't caught up with yet wins over
    // the last reported position, so the scrubber doesn't snap back while Jellyfin restarts
    // the transcode at the new point.
    var currentTime: Double { return seekTarget ?? reportedTime }
    var isSeeking: Bool { return seekTarget != nil }

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

    private var discovery: CastDiscovery?
    private var lastSavedTime: Double = 0
    // Set when the receiver reports the media played to the end, so the teardown
    // that follows doesn't write a resume position sitting at the very end.
    private var didFinish = false

    private static let skipDebounce: TimeInterval = 0.6
    // A receiver lands on a segment/keyframe boundary, not the exact second asked for.
    private static let seekTolerance: Double = 8
    // How long a seek may go unconfirmed before the scrubber falls back to what the
    // receiver reports (a rejected SEEK would otherwise freeze it).
    private static let seekHoldTimeout: CFAbsoluteTime = 20
    // A transcode that hasn't produced a frame by now isn't going to.
    private static let loadTimeout: TimeInterval = 45

    var isCasting: Bool { return session != nil }
    var deviceName: String { return device?.name ?? "" }

    // Bound by CastVC in viewWillAppear, cleared in viewWillDisappear.
    var onState: ((String) -> Void)?
    var onProgress: ((Double, Double, Bool) -> Void)?
    var onEnded: ((CastEnd) -> Void)?

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

    // MARK: - Session lifecycle

    // Single fixed URL the receiver can seek natively (photos).
    func start(item: MediaItem, kind: Kind, device: CastDevice,
               url: String, contentType: String, startTime: Double) {
        let source = CastSource(contentType: contentType, seeksByReloading: false) { _ in url }
        start(item: item, kind: kind, device: device, sources: [source], startTime: startTime)
    }

    func start(item: MediaItem, kind: Kind, device: CastDevice,
               sources: [CastSource], startTime: Double) {
        stop()   // only one session at a time
        guard let first = sources.first,
              let url = first.url(first.seeksByReloading ? startTime : 0) else { return }

        self.item = item
        self.kind = kind
        self.device = device
        self.sources = sources
        sourceIndex = 0
        state = "Connecting\u{2026}"
        reportedTime = startTime
        seekTarget = nil
        // runTimeTicks is the authoritative length — see progressReceived.
        duration = item.runTimeTicks.map { Double($0) / 10_000_000 } ?? 0
        isPlaying = false
        isBuffering = false
        playStateHoldUntil = 0
        lastSavedTime = startTime
        didFinish = false

        let s = CastSession(device: device)
        session = s
        bind(s)
        s.start(mediaURL: url, contentType: first.contentType,
                startTime: first.seeksByReloading ? 0 : startTime,
                timeOffset: first.seeksByReloading ? startTime : 0,
                metadata: metadata(for: item, kind: kind))
        armLoadWatchdog()
    }

    func stop() {
        guard let s = session else { return }
        if !didFinish { savePosition(currentTime) }
        s.stop()
        session = nil
        device = nil
        item = nil
        sources = []
        state = ""
        reportedTime = 0
        seekTarget = nil
        seekCommittedAt = nil
        duration = 0
        isPlaying = false
        isBuffering = false
        // Orphan any pending skip / load watchdog.
        seekGen += 1
        loadGen += 1
    }

    // Callbacks from a session that has since been replaced are dropped, so a late
    // status from the previous cast can't leak into this one.
    private func bind(_ s: CastSession) {
        s.onState = { [weak self, weak s] text in
            guard let self = self, let s = s, self.session === s else { return }
            self.connectionStateChanged(text)
        }
        s.onProgress = { [weak self, weak s] cur, dur, playerState in
            guard let self = self, let s = s, self.session === s else { return }
            self.progressReceived(cur, dur, playerState)
        }
        s.onEnded = { [weak self, weak s] end in
            guard let self = self, let s = s, self.session === s else { return }
            self.mediaEnded(end)
        }
    }

    // MARK: - Transport

    func togglePlayPause() {
        guard let s = session else { return }
        if isPlaying { s.pause() } else { s.play() }
        isPlaying = !isPlaying
        playStateHoldUntil = CFAbsoluteTimeGetCurrent() + 2
        emitProgress()
    }

    // Absolute seek (scrubber release) — sent immediately.
    func seek(to seconds: Double) {
        guard session != nil, kind != .photo else { return }
        let t = clamped(seconds)
        holdSeek(t)
        commitSeek(t)
    }

    // Relative skip. Rapid taps stack on the pending target and go out as a single seek,
    // so three taps on +30 is one jump of 90 s rather than three transcode restarts.
    func seek(by delta: Double) {
        guard session != nil, kind != .photo else { return }
        let t = clamped(currentTime + delta)
        holdSeek(t)
        let gen = seekGen
        DispatchQueue.main.asyncAfter(deadline: .now() + CastController.skipDebounce) { [weak self] in
            guard let self = self, self.seekGen == gen, let target = self.seekTarget else { return }
            self.commitSeek(target)
        }
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
        guard session != nil, sourceIndex < sources.count else { return }
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
        s.load(mediaURL: url, contentType: src.contentType,
               startTime: src.seeksByReloading ? 0 : t,
               timeOffset: src.seeksByReloading ? t : 0,
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
            guard let self = self, self.loadGen == gen, self.session != nil, !self.sourceStarted else { return }
            DebugLog.shared.log("CAST", "no playback \(Int(CastController.loadTimeout))s after LOAD")
            self.mediaEnded(.failed("the TV never started playing"))
        }
    }

    // MARK: - Session events

    private func connectionStateChanged(_ text: String) {
        switch text {
        case "connected", "app ready": state = "Starting receiver\u{2026}"
        case "loading media": state = "Loading\u{2026}"
        default: state = text
        }
        onState?(state)
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
        onState?(state)
        emitProgress()
    }

    private func mediaEnded(_ end: CastEnd) {
        switch end {
        case .finished:
            didFinish = true
            clearResume()
        case .failed(let reason):
            // Fall through the source list (HLS -> progressive mp4) before giving up,
            // resuming from wherever the failed source got to.
            if sourceIndex + 1 < sources.count {
                sourceIndex += 1
                DebugLog.shared.log("CAST", "source failed (\(reason)), falling back to #\(sourceIndex) \(sources[sourceIndex].contentType) at \(Int(currentTime))s")
                state = "Retrying\u{2026}"
                onState?(state)
                loadCurrentSource(at: currentTime, autoplay: true)
                return
            }
        case .stoppedRemotely:
            break
        }
        onEnded?(end)
    }

    private func emitProgress() {
        onProgress?(currentTime, duration, isPlaying)
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
        guard let key = resumeKey else { return }
        // Same thresholds the local players use: 10s for video, and audio only
        // resumes long-form content so a 3-minute song always restarts.
        let threshold: Double = (kind == .audio) ? 900 : 10
        guard t > 10, duration == 0 || duration > threshold else { return }
        UserDefaults.standard.set(t, forKey: key)
    }

    private func clearResume() {
        guard let key = resumeKey else { return }
        UserDefaults.standard.removeObject(forKey: key)
    }

    // The position to seed a new cast with, mirroring the local players' rules.
    func savedResumePosition(for item: MediaItem, kind: Kind) -> Double {
        let key: String
        switch kind {
        case .video: key = "resume_\(item.id)"
        case .audio: key = "aresume_\(item.id)"
        case .photo: return 0
        }
        let saved = UserDefaults.standard.double(forKey: key)
        return saved > 10 ? saved : 0
    }
}
