import Foundation

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
    private(set) var state = ""
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false

    private var discovery: CastDiscovery?
    private var lastSavedTime: Double = 0
    // Set when the receiver reports the media played to the end, so the teardown
    // that follows doesn't write a resume position sitting at the very end.
    private var didFinish = false

    var isCasting: Bool { return session != nil }
    var deviceName: String { return device?.name ?? "" }

    // Bound by CastVC in viewWillAppear, cleared in viewWillDisappear.
    var onState: ((String) -> Void)?
    var onProgress: ((Double, Double, Bool) -> Void)?
    var onEnded: ((String) -> Void)?

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

    func start(item: MediaItem, kind: Kind, device: CastDevice,
               url: String, contentType: String, startTime: Double) {
        stop()   // only one session at a time

        self.item = item
        self.kind = kind
        self.device = device
        state = "connecting"
        currentTime = startTime
        duration = item.runTimeTicks.map { Double($0) / 10_000_000 } ?? 0
        isPlaying = false
        lastSavedTime = startTime
        didFinish = false

        let s = CastSession(device: device)
        session = s
        s.onState = { [weak self] text in
            guard let self = self else { return }
            self.state = text
            self.onState?(text)
        }
        s.onProgress = { [weak self] cur, dur, playing in
            guard let self = self else { return }
            self.currentTime = cur
            if dur > 0 { self.duration = dur }
            self.isPlaying = playing
            self.savePositionIfDue(cur)
            self.onProgress?(cur, self.duration, playing)
        }
        s.onEnded = { [weak self] reason in
            guard let self = self else { return }
            if reason == "FINISHED" {
                self.didFinish = true
                self.clearResume()
            }
            self.onEnded?(reason)
        }
        s.start(mediaURL: url, contentType: contentType, startTime: startTime,
                metadata: metadata(for: item, kind: kind))
    }

    func stop() {
        guard let s = session else { return }
        if !didFinish { savePosition(s.lastKnownTime) }
        s.stop()
        session = nil
        device = nil
        item = nil
        state = ""
        currentTime = 0
        duration = 0
        isPlaying = false
    }

    func togglePlayPause() {
        guard let s = session else { return }
        if isPlaying { s.pause() } else { s.play() }
    }

    func seek(to seconds: Double) { session?.seek(to: seconds) }
    func seek(by delta: Double) { session?.seek(by: delta) }

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
