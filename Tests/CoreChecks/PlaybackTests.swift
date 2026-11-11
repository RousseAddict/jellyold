import Foundation
import XCTest
@testable import JellyoldCoreChecks

final class PlaybackTests: XCTestCase {
    func testTicksUseHundredNanosecondUnits() {
        XCTAssertEqual(PlaybackPosition.ticks(seconds: 1.25), 12_500_000)
        XCTAssertEqual(PlaybackPosition.seconds(ticks: 3_200_000_000), 320)
        XCTAssertEqual(PlaybackPosition.ticks(seconds: 0), 0)
    }

    func testInvalidPlayerSamplesCannotBecomePositions() {
        for value in [Double.nan, Double.infinity, -Double.infinity, -1, 9e18] {
            XCTAssertNil(PlaybackPosition.ticks(seconds: value))
        }
        XCTAssertEqual(PlaybackPosition.ticks(seconds: 150, duration: 120), 1_200_000_000)
        XCTAssertEqual(PlaybackPosition.seconds(ticks: -1), 0)
        let limit = Double(Int64.max) / 10_000_000
        XCTAssertNil(PlaybackPosition.ticks(seconds: limit))
        XCTAssertNotNil(PlaybackPosition.ticks(seconds: limit.nextDown))
    }

    func testServerZeroAndServerProgressOverrideLocalResume() {
        XCTAssertEqual(PlaybackPosition.resume(serverTicks: 0, localSeconds: 600, duration: 1200), 0)
        XCTAssertEqual(PlaybackPosition.resume(serverTicks: 900_000_000, localSeconds: 600, duration: 1200), 90)
        XCTAssertEqual(PlaybackPosition.resume(serverTicks: nil, localSeconds: 600, duration: 1200), 600)
        XCTAssertEqual(PlaybackPosition.resume(serverTicks: nil, localSeconds: .nan, duration: 1200), 0)
    }

    func testOnlyNaturalCompletionMovesToTheEnd() {
        let last: Int64 = 45_000_000
        XCTAssertEqual(PlaybackPosition.stopped(last: last, duration: 120, ended: false, failed: true), last)
        XCTAssertEqual(PlaybackPosition.stopped(last: last, duration: 120, ended: false, failed: false), last)
        XCTAssertEqual(PlaybackPosition.stopped(last: last, duration: 120, ended: true, failed: false), 1_200_000_000)
        XCTAssertEqual(PlaybackPosition.stopped(last: last, duration: 120, ended: true, failed: true), last)
        XCTAssertEqual(PlaybackPosition.stopped(last: last, duration: .nan, ended: true, failed: false), last)
    }

    func testBackwardSeekRemainsAValidPosition() {
        let before = PlaybackPosition.ticks(seconds: 600)
        let after = PlaybackPosition.ticks(seconds: 120)
        XCTAssertNotNil(after)
        XCTAssertLessThan(after!, before!)
        XCTAssertEqual(PlaybackPosition.stopped(last: after!, duration: 1200, ended: false, failed: false), after)
    }

    func testLargeServerNumbersAndMissingUserData() {
        let item = MediaItem(json: ["Id": "episode", "Name": "Episode", "Type": "Episode",
            "SeriesName": "Series", "ParentIndexNumber": 2, "IndexNumber": 3,
            "RunTimeTicks": NSNumber(value: Int64(75_504_640_000)),
            "UserData": ["PlaybackPositionTicks": NSNumber(value: Int64(32_000_000_000))]])
        XCTAssertEqual(item?.playbackPositionTicks, 32_000_000_000)
        XCTAssertEqual(item?.durationSeconds, 7550.464)
        XCTAssertEqual(item?.seriesName, "Series")
        XCTAssertEqual(item?.episodeLabel, "S02E03")
        XCTAssertNil(MediaItem(json: ["Id": "movie", "Name": "Movie"])?.playbackPositionTicks)
    }

    func testHLSCredentialsStayOnTheConfiguredOrigin() {
        let base = URL(string: "https://media.example.invalid/jellyfin")!
        for candidate in ["https://media.example.invalid/a.m3u8", "https://MEDIA.example.invalid:443/a.ts"] {
            XCTAssertTrue(JellyfinServer.sameOrigin(URL(string: candidate)!, base))
        }
        for candidate in ["https://cdn.example.invalid/a.ts", "http://media.example.invalid/a.ts",
                          "https://media.example.invalid:8443/a.ts", "file:///a.ts",
                          "https://media.example.invalid.attacker.invalid/a.ts"] {
            XCTAssertFalse(JellyfinServer.sameOrigin(URL(string: candidate)!, base))
        }
        XCTAssertTrue(JellyfinServer.sameOrigin(URL(string: "http://media.example.invalid:80/a.ts")!,
                                                URL(string: "http://media.example.invalid")!))
    }

    func testDeviceIdentityPersistsAndDiffersBetweenInstallations() {
        let suite = "JellyoldCoreChecks-" + UUID().uuidString
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        let first = JellyfinServer.loadDeviceId(from: store)
        XCTAssertNotNil(first.range(of: "^jellyold-[0-9a-f]{32}$", options: .regularExpression))
        XCTAssertEqual(JellyfinServer.loadDeviceId(from: store), first)
        let otherSuite = suite + "-other"
        let other = UserDefaults(suiteName: otherSuite)!
        defer { other.removePersistentDomain(forName: otherSuite) }
        XCTAssertNotEqual(JellyfinServer.loadDeviceId(from: other), first)
    }
}
