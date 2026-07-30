import Foundation

// The audio queue: an ordered list plus the index of the track being played.
// Every mutation persists to UserDefaults so the mini bar can come back after
// a relaunch, and any change of index asks AudioPlayer to start the new track.
final class AudioQueue {
    static let shared = AudioQueue()

    private(set) var items: [MediaItem] = []
    private(set) var index: Int = 0

    private static let itemsKey = "audio_queue"
    private static let indexKey = "audio_queue_index"

    private init() { restore() }

    var current: MediaItem? {
        guard index >= 0, index < items.count else { return nil }
        return items[index]
    }

    var hasNext: Bool { return index + 1 < items.count }
    var hasPrevious: Bool { return index > 0 }

    // MARK: - Playback commands

    func play(items newItems: [MediaItem], startAt start: Int) {
        guard !newItems.isEmpty else { return }
        items = newItems
        index = max(0, min(start, newItems.count - 1))
        persist()
        startCurrent()
    }

    func jump(to newIndex: Int) {
        guard newIndex >= 0, newIndex < items.count else { return }
        index = newIndex
        persist()
        startCurrent()
    }

    func next() {
        guard hasNext else { return }
        index += 1
        persist()
        startCurrent()
    }

    func previous() {
        guard hasPrevious else { return }
        index -= 1
        persist()
        startCurrent()
    }

    // Called by AudioPlayer when a track plays to its end. Returns false at the
    // end of the queue, so the player can leave the last track loaded/paused
    // rather than tearing the mini bar down.
    func advanceAfterFinish() -> Bool {
        guard hasNext else { return false }
        index += 1
        persist()
        startCurrent()
        return true
    }

    // MARK: - Queue editing

    func playNext(_ item: MediaItem) {
        if items.isEmpty { play(items: [item], startAt: 0); return }
        items.insert(item, at: min(index + 1, items.count))
        persist()
    }

    func addToEnd(_ item: MediaItem) {
        if items.isEmpty { play(items: [item], startAt: 0); return }
        items.append(item)
        persist()
    }

    func remove(at i: Int) {
        guard i >= 0, i < items.count else { return }
        let wasCurrent = (i == index)
        items.remove(at: i)
        if items.isEmpty {
            index = 0
            persist()
            return
        }
        if i < index { index -= 1 }
        if wasCurrent {
            // The playing track is gone — whatever slid into its slot takes over
            // (clamped, in case it was the last one).
            index = min(index, items.count - 1)
            persist()
            startCurrent()
            return
        }
        persist()
    }

    func move(from: Int, to: Int) {
        guard from >= 0, from < items.count, to >= 0, to < items.count, from != to else { return }
        let playingId = current?.id
        let moved = items.remove(at: from)
        items.insert(moved, at: to)
        // Follow the playing track to its new slot rather than leaving the index
        // pointing at whatever shifted underneath it.
        if let playingId = playingId {
            for i in 0..<items.count where items[i].id == playingId {
                index = i
                break
            }
        }
        persist()
    }

    // Only ever called from AudioPlayer.stopAll() — it must not call back into
    // the player, or the two would recurse.
    func clear() {
        items = []
        index = 0
        persist()
    }

    private func startCurrent() {
        guard let item = current else { return }
        AudioPlayer.shared.play(item: item)
    }

    // MARK: - Persistence

    private func persist() {
        UserDefaults.standard.set(items.map { $0.toDict() }, forKey: AudioQueue.itemsKey)
        UserDefaults.standard.set(index, forKey: AudioQueue.indexKey)
    }

    // Metadata only, and deliberately so: this runs on the launch path, where
    // building a player would reach LocalStreamProxy.ensureStarted() and run
    // curl_global_init() on the main thread — which crashes in OpenSSL's
    // threading setup. The mini bar just shows the restored track, paused.
    private func restore() {
        guard let dicts = UserDefaults.standard.array(forKey: AudioQueue.itemsKey) as? [[String: Any]] else { return }
        items = dicts.compactMap { MediaItem.from(dict: $0) }
        let saved = UserDefaults.standard.integer(forKey: AudioQueue.indexKey)
        index = (saved >= 0 && saved < items.count) ? saved : 0
    }
}
