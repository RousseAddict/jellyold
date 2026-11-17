import UIKit

// MARK: - Action sheets on iOS 8
//
// On an iPad a UIAlertController action sheet is a popover, which iOS 8 has to be told
// where to point: without that, choosing a TV in the detail page's "Cast to…" never led to
// a cast. Every action sheet goes through presentSheet(_:from:), pointed at the button, bar
// button or cell that opened it. On an iPhone the anchor is ignored. The iOS 6 target uses
// UIActionSheet, which needs none of this.

#if !IOS6_TARGET
enum SheetAnchor {
    case view(UIView?)
    case barButton(UIBarButtonItem?)
}

extension UIViewController {
    // A sheet asked for while another is still on screen waits for it to go, since UIKit
    // would drop it.
    func presentSheet(_ alert: UIAlertController, from anchor: SheetAnchor, attempt: Int = 0) {
        if presentedViewController != nil {
            if attempt == 0 {
                DebugLog.shared.log("UI", "sheet \"\(alert.title ?? "")\" waits for the previous one to close")
            }
            guard attempt < 30 else {
                DebugLog.shared.log("UI", "sheet \"\(alert.title ?? "")\" dropped: the previous one never closed")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.presentSheet(alert, from: anchor, attempt: attempt + 1)
            }
            return
        }
        if let popover = alert.popoverPresentationController {
            switch anchor {
            case .barButton(let item?):
                popover.barButtonItem = item
            case .view(let source?) where source.window != nil:
                popover.sourceView = source
                popover.sourceRect = source.bounds
            default:
                // The anchor is gone (a page rebuilt while the Chromecast search ran): the
                // middle of the screen, without an arrow.
                popover.sourceView = view
                popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
        }
        present(alert, animated: true)
    }
}
#endif
