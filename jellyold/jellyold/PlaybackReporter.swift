import Foundation

// MARK: - ServerPlayState
//
// What Jellyfin remembers about this user and an item (its UserData block): where
// they stopped, whether they finished it, and when they last played it on any client.

struct ServerPlayState {
    let positionSeconds: Double
    let played: Bool
    // 0...1 of the runtime, for a card's progress bar; nil when there's no resume point.
    let playedFraction: Double?
    // Kept as the server's string and parsed only on demand: every list item carries
    // UserData now, and a DateFormatter per item is real time on an A5.
    private let lastPlayedDate: String?

    // Seconds since 1970; nil when the item has never been played.
    var lastPlayed: Double? {
        return lastPlayedDate.flatMap(JellyfinAPI.parseServerDate)?.timeIntervalSince1970
    }

    init?(userData: [String: Any]?) {
        guard let ud = userData else { return nil }
        // NSNumber path: a bare numeric/Bool `as?` silently fails on the 5.1.5 runtime.
        let ticks = (ud["PlaybackPositionTicks"] as? NSNumber)?.int64Value ?? 0
        positionSeconds = Double(ticks) / 10_000_000
        played = (ud["Played"] as? NSNumber)?.boolValue ?? false
        playedFraction = (ud["PlayedPercentage"] as? NSNumber).map { min(1, max(0, $0.doubleValue / 100)) }
        lastPlayedDate = ud["LastPlayedDate"] as? String
    }
}

// MARK: - ResumeStore
//
// This device's own video resume points: "resume_<id>" (seconds, the key VideoPlayerVC
// always used) plus "resume_at_<id>", when it was written. That time is what lets a
// position saved here be weighed against the one Jellyfin holds, which may come from
// another client: whichever is newer wins. Shared by VideoPlayerVC and CastController;
// AudioPlayer keeps its own "aresume_<id>".

enum ResumeStore {
    private static func key(_ id: String) -> String { return "resume_\(id)" }
    private static func timeKey(_ id: String) -> String { return "resume_at_\(id)" }

    static func save(_ seconds: Double, for id: String) {
        let d = UserDefaults.standard
        d.set(seconds, forKey: key(id))
        d.set(Date().timeIntervalSince1970, forKey: timeKey(id))
    }

    static func clear(_ id: String) {
        let d = UserDefaults.standard
        d.removeObject(forKey: key(id))
        d.removeObject(forKey: timeKey(id))
    }

    // Where to start playing. Positions under 10 s don't count anywhere in the app.
    static func startPosition(for id: String, server: ServerPlayState?) -> Double {
        let d = UserDefaults.standard
        let local = d.double(forKey: key(id))
        let localAt = d.double(forKey: timeKey(id))   // 0 for a key saved before this existed
        guard let server = server else { return local > 10 ? local : 0 }

        if (server.lastPlayed ?? 0) > localAt {
            if server.played && server.positionSeconds <= 10 {
                // Finished on another client since this device last stopped: the
                // position kept here is stale, and would otherwise resurface offline.
                if local > 0 { clear(id) }
                return 0
            }
            if server.positionSeconds > 10 { return server.positionSeconds }
        }
        // Jellyfin drops positions under 5% of the runtime, so a short watch on this
        // device can leave the server with nothing while the local key still has it.
        if local > 10 { return local }
        return server.positionSeconds > 10 ? server.positionSeconds : 0
    }
}

// MARK: - PlaybackReporter
//
// Tells Jellyfin what this device is playing, the way its own apps do: a start once
// playback is really under way, a progress ping every 10 s (sooner on pause/resume) and
// a stop. That is what puts an item in "Continue watching" (here and on the web) and
// marks it watched at the end: Jellyfin decides that from the stop position (past 90%
// of the runtime = played).
//
// Reports go out fire-and-forget on their own curl queue with a 5 s timeout, so an
// unreachable server (a download played offline) costs a log line and nothing else.
// Nothing is reported for a playback that never started, so a stream that fails to
// load leaves the server's resume point and watched state alone.

struct PlaybackSample {
    let position: Double
    let isPlaying: Bool
}

final class PlaybackReporter: NSObject {

    // Posted on the main thread once a stop/finish report has been answered (or has
    // failed), so a page showing resume points — Home — can re-read them. Re-reading
    // on viewWillAppear alone races the report: it runs on a different queue.
    static let didStopNotification = Notification.Name("jellyold.playbackReportStopped")

    private static let progressInterval: CFAbsoluteTime = 10
    private static let sampleInterval: TimeInterval = 2

    private let itemId: String
    private let runTimeTicks: Int64?
    private let playSessionId: String
    private let playMethod: String
    private let audioIndex: Int?
    private let subtitleIndex: Int?

    private(set) var isStarted = false
    private var isStopped = false
    private var lastSentAt: CFAbsoluteTime = 0
    private var lastPaused = false
    private var progressInFlight = false

    private var timer: Timer?
    private var sample: (() -> PlaybackSample?)?

    init(item: MediaItem, playSessionId: String, playMethod: String,
         audioIndex: Int? = nil, subtitleIndex: Int? = nil) {
        itemId = item.id
        runTimeTicks = item.runTimeTicks
        self.playSessionId = playSessionId
        self.playMethod = playMethod
        self.audioIndex = audioIndex
        self.subtitleIndex = subtitleIndex
        super.init()
    }

    // MARK: Driving it

    // For a player with no progress callback of its own (VideoPlayerVC): polls `sample`
    // every 2 s, starts the session the first time it reports playing, then sends
    // progress. A nil sample means the owner has gone, and ends the polling.
    func begin(sample: @escaping () -> PlaybackSample?) {
        self.sample = sample
        timer?.invalidate()
        // Target/selector form: the block-based Timer API is iOS 10+.
        timer = Timer.scheduledTimer(timeInterval: PlaybackReporter.sampleInterval, target: self,
                                     selector: #selector(tick), userInfo: nil, repeats: true)
    }

    @objc private func tick() {
        guard let s = sample?() else { endTimer(); return }
        if isStarted {
            progress(at: s.position, paused: !s.isPlaying)
        } else if s.isPlaying {
            start(at: s.position)
        }
    }

    private func endTimer() {
        timer?.invalidate()
        timer = nil
        sample = nil
    }

    // MARK: Reports

    func start(at seconds: Double) {
        guard !isStarted, !isStopped else { return }
        isStarted = true
        lastSentAt = CFAbsoluteTimeGetCurrent()
        lastPaused = false
        send("Sessions/Playing", body(ticks: PlaybackReporter.ticks(seconds) ?? 0, paused: false), label: "start")
    }

    // Throttled to one every 10 s, except that a pause or resume goes out right away.
    func progress(at seconds: Double, paused: Bool) {
        guard isStarted, !isStopped, !progressInFlight,
              let ticks = PlaybackReporter.ticks(seconds) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard paused != lastPaused || now - lastSentAt >= PlaybackReporter.progressInterval else { return }
        lastSentAt = now
        lastPaused = paused
        progressInFlight = true
        send("Sessions/Playing/Progress", body(ticks: ticks, paused: paused), label: "progress") { [weak self] in
            self?.progressInFlight = false
        }
    }

    // Stopped part-way. The caller passes a real position: a missing PositionTicks
    // reads as "played to completion" on Jellyfin's side.
    func stop(at seconds: Double) {
        endTimer()
        guard isStarted, !isStopped, let ticks = PlaybackReporter.ticks(seconds) else { return }
        isStopped = true
        send("Sessions/Playing/Stopped", body(ticks: ticks, paused: false), label: "stop")
    }

    // Played to the end: report the full runtime so Jellyfin marks it watched and
    // drops its resume point (no runtime known = no PositionTicks = the same thing).
    func finish() {
        endTimer()
        guard isStarted, !isStopped else { return }
        isStopped = true
        send("Sessions/Playing/Stopped", body(ticks: runTimeTicks, paused: false), label: "finish")
    }

    // MARK: Plumbing

    private static func ticks(_ seconds: Double) -> Int64? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return Int64(seconds * 10_000_000)
    }

    private func body(ticks: Int64?, paused: Bool) -> [String: Any] {
        var b: [String: Any] = [
            "ItemId": itemId,
            "MediaSourceId": itemId,
            "PlaySessionId": playSessionId,
            "PlayMethod": playMethod,
            "CanSeek": NSNumber(value: true),
            "IsPaused": NSNumber(value: paused)
        ]
        if let t = ticks { b["PositionTicks"] = NSNumber(value: t) }
        if let a = audioIndex { b["AudioStreamIndex"] = NSNumber(value: a) }
        if let s = subtitleIndex { b["SubtitleStreamIndex"] = NSNumber(value: s) }
        return b
    }

    private func send(_ path: String, _ body: [String: Any], label: String, done: (() -> Void)? = nil) {
        guard let serverURL = JellyfinServer.serverURL,
              let data = try? JSONSerialization.data(withJSONObject: body, options: []) else {
            done?()
            return
        }
        let headers = ["Authorization": JellyfinServer.authHeader(),
                       "Content-Type": "application/json"]
        let id = itemId
        let ticks = (body["PositionTicks"] as? NSNumber)?.int64Value
        CurlFetcher.postReport(url: "\(serverURL)/\(path)", headers: headers, body: data) { ok in
            // Every 10 s during a film is too chatty for the log unless it fails.
            if !ok || label != "progress" {
                let at = ticks.map { "\($0 / 10_000_000)s" } ?? "end"
                DebugLog.shared.log("Report", "\(label) \(ok ? "ok" : "FAILED") id=\(id) at=\(at)")
            }
            if label == "stop" || label == "finish" {
                NotificationCenter.default.post(name: PlaybackReporter.didStopNotification, object: nil)
            }
            done?()
        }
    }
}
