# Experimental home and video playback sync

This is an experimental, fully AI/vibe-coded contribution. It is offered as a
starting point for review and further work, not as a production-ready release.
No new IPA is published by this change; the prebuilt IPAs already in this
repository do not contain these changes. Build from source using the existing
Xcode/Swift toolchain and iOS 6 runtime packaging process.

## Behavior

The configured root screen now has native Continue Watching and Next Up sections
from Jellyfin's Resume and NextUp endpoints. Rows identify the movie or series,
season and episode, show artwork and server progress, and open the existing detail
screen so audio/subtitle controls remain available. Libraries leads to the existing
browser, downloads and account controls. Refresh, return from playback, and app
foreground reload the shelves; empty and failed results remain distinct. Each shelf
is limited to 20 items. Next Up means a shelf, with no automatic episode playback.

Before Play, the client fetches current server UserData. A server position of zero
wins over an old local position, and the local value is a fallback when UserData
cannot be fetched. Each video playback has one PlaySessionId shared with its HLS
request and start/progress/stop reports. A stable, random per-installation DeviceId
is shared by login, streams, downloads, casting requests and reports; different
installations no longer all claim the same fixed device ID.

Reports include the item, media source, position in 100 ns ticks, pause and selected
stream state. Progress is sampled every second and sent about every 10 seconds or
on pause/resume/seek transitions. Exit, background pause, natural completion and
failure preserve or finish the position appropriately. Invalid player samples do
not overwrite the last valid sample, and stop reporting is idempotent. The server
continues to decide watched thresholds and NextUp ordering. AudioPlayer's music
queue does not gain server progress reporting in this patch.

The HLS proxy now adds Authorization to same-origin playlist and segment requests
while retaining Range. Different hosts, ports and schemes do not receive the token.
Default ports are normalized. DebugLog uses the old NSData writing API rather than
Swift Data.write, which invoked an iOS 7-only NSData selector on the tested iOS 6
runtime. No Objective-C method injection or private SSH/UI control bridge is included.

## Validation and its limits

The feature's device-specific precursor was built and exercised on an iPad 4
(iPad3,5) running iOS 6.1.3, using the upstream Swift 5.6.3 compiler/5.1.5 runtime
strategy and a compatible local TLS setup. Real movie and episode playback, server
resume, progress, pause, seek, stop, a non-default audio track and natural completion
were observed. A synthetic playbackError notification exercised the failure handler;
a real decode/network failure was not deliberately induced. Server API reads
confirmed persisted progress; a second physical client's interface was not driven.

The public source additionally generalizes device identity and English UI copy,
uses reusable shelf cells, and fixes shared iOS 8 completion/error/resume handling.
For this public revision, all eight host tests passed with Swift 5.6.3, and all app
Swift sources compiled to armv7 objects with the Apple Swift 5.6.3 compiler and
iPhoneOS 15.6 SDK in both IOS6_TARGET (deployment target 7.0 before the existing
iOS 6 packaging/patching step) and IOS8_TARGET (deployment target 8.0) modes.
This is compilation, not a complete Xcode archive, linked IPA or device validation.
This exact public revision has not yet been installed and retested on hardware. iOS 8/9, iPhones,
rotation, multiple media versions, offline transitions and varied server versions
need more testing. MediaSourceId currently follows the existing item-ID stream path.

Run `swift test -j 2` from the repository root with Swift 5.6 or newer. The small SwiftPM
package tests the app's actual Foundation model/policy files without importing UIKit
or replacing the Xcode app build. Checks cover tick bounds, server-zero precedence,
completion/error/exit, backward positions, large NSNumber values, per-installation
identity persistence and isolation of HLS credentials by origin. These host tests
are not a substitute for old-device playback tests.

Sync requires connectivity. There is no durable offline event queue or retry/replay
protocol. Existing upstream TLS behavior is unchanged: curl certificate verification
is disabled, and artwork still uses NSURLConnection, whose iOS 6 TLS support may
require an already-compatible server or local workaround. This patch does not
provide TLS hardening or bundle any system tweak. Do not treat it as a security
review of the entire application.
