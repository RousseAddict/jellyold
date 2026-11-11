import Foundation

// Jellyfin ticks are 100 ns, independent of the player's timescale.
// Invalid player samples must never overwrite the last valid position.
enum PlaybackPosition {
    static func ticks(seconds: Double, duration: Double = 0) -> Int64? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let bounded = duration.isFinite && duration > 0 ? min(seconds, duration) : seconds
        guard bounded < Double(Int64.max) / 10_000_000 else { return nil }
        return Int64((bounded * 10_000_000).rounded())
    }
    static func seconds(ticks: Int64) -> Double { Double(max(0, ticks)) / 10_000_000 }
    static func resume(serverTicks: Int64?, localSeconds: Double, duration: Double) -> Double {
        let value = serverTicks.map { seconds(ticks: $0) } ?? localSeconds
        guard let ticks = ticks(seconds: value, duration: duration) else { return 0 }
        return seconds(ticks: ticks)
    }
    static func stopped(last: Int64, duration: Double, ended: Bool, failed: Bool) -> Int64 {
        if ended && !failed, let ticks = ticks(seconds: duration), ticks > 0 { return ticks }
        return max(0, last)
    }
}
