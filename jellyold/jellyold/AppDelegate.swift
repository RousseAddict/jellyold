import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, UINavigationControllerDelegate {
    var window: UIWindow?
    private var miniBar: MiniPlayerBar?
    private var videoTransition = false

    // libcurl/OpenSSL warm-up runs here rather than on DispatchQueue.global(),
    // which isn't used anywhere else in this app — DispatchQueue(label:) is the
    // proven form on this toolchain.
    private let warmupQueue = DispatchQueue(label: "com.jellyold.warmup")

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Light status bar text throughout the app
        UIApplication.shared.statusBarStyle = .lightContent
        // White navigation bar title
        UINavigationBar.appearance().titleTextAttributes = [
            NSAttributedString.Key.foregroundColor: UIColor.white
        ]

        window = UIWindow(frame: UIScreen.main.bounds)
        let root: UIViewController = JellyfinServer.isConfigured ? HomeVC() : ServerSetupVC()
        let nav = UINavigationController(rootViewController: root)
        nav.delegate = self
        nav.navigationBar.barStyle = .black
        nav.navigationBar.tintColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1.0)
        window?.rootViewController = nav
        window?.makeKeyAndVisible()

        let bar = MiniPlayerBar(nav: nav)
        nav.view.addSubview(bar)
        miniBar = bar

        // Get curl_global_init out of the way off the main thread now — running
        // it there crashes in OpenSSL's threading setup, and the first playback
        // would otherwise be the first thing to trigger it.
        warmupQueue.async { CurlFetcher.ensureGlobalInit() }
        return true
    }

    func navigationController(_ navigationController: UINavigationController,
                              willShow viewController: UIViewController, animated: Bool) {
        if viewController is VideoPlayerVC { videoTransition = true }
    }

    func navigationController(_ navigationController: UINavigationController,
                              didShow viewController: UIViewController, animated: Bool) {
        // iOS6 can finish an outgoing full-screen transition after the video's
        // disappearance callback, especially when opening playback is cancelled.
        // Restore only video transitions, leaving PhotoVC's full-screen mode alone.
        guard videoTransition || viewController is VideoPlayerVC,
              !(navigationController.topViewController is VideoPlayerVC) else { return }
        videoTransition = false
        UIApplication.shared.setStatusBarHidden(false, with: .none)
        navigationController.setNavigationBarHidden(false, animated: false)
    }

    // MARK: - Remote control (lock screen / headphone buttons)

    override var canBecomeFirstResponder: Bool { return true }

    func applicationDidBecomeActive(_ application: UIApplication) {
        application.beginReceivingRemoteControlEvents()
        becomeFirstResponder()
    }

    override func remoteControlReceived(with event: UIEvent?) {
        guard let event = event, event.type == .remoteControl else { return }
        switch event.subtype {
        case .remoteControlPlay:            AudioPlayer.shared.resume()
        case .remoteControlPause:           AudioPlayer.shared.pause()
        case .remoteControlTogglePlayPause: AudioPlayer.shared.togglePlayPause()
        case .remoteControlNextTrack:       AudioQueue.shared.next()
        case .remoteControlPreviousTrack:   AudioQueue.shared.previous()
        default: break
        }
    }
}
