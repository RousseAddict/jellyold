import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Light status bar text throughout the app
        UIApplication.shared.statusBarStyle = .lightContent
        // White navigation bar title
        UINavigationBar.appearance().titleTextAttributes = [
            NSAttributedString.Key.foregroundColor: UIColor.white
        ]

        window = UIWindow(frame: UIScreen.main.bounds)
        let root: UIViewController = JellyfinServer.isConfigured ? LibraryListVC() : ServerSetupVC()
        let nav = UINavigationController(rootViewController: root)
        nav.navigationBar.barStyle = .black
        nav.navigationBar.tintColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1.0)
        window?.rootViewController = nav
        window?.makeKeyAndVisible()
        return true
    }
}
