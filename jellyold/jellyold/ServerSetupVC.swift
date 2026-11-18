import UIKit

class ServerSetupVC: UIViewController {

    private var logoView: UIImageView!
    private var serverField: UITextField!
    private var hintLabel: UILabel!
    private var usernameField: UITextField!
    private var passwordField: UITextField!
    private var connectButton: UIButton!
    private var spinner: UIActivityIndicatorView!
    // What the frames were last set from: the top of the visible area and the width.
    private var laidOutTop: CGFloat = 0
    private var laidOutWidth: CGFloat = 0
    // The keyboard has slid the whole view up to keep Connect above it.
    private var slidUp = false

    private let bgColor = UIColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1.0)
    private let accentColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1.0)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "JellyOld"
        view.backgroundColor = bgColor
        registerKeyboardObservers()
        buildUI()
#if IOS6_TARGET
        // iOS 6/7: the bar is opaque and the view starts below it, at its final size.
        layoutUI(top: 0)
#endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
#if !IOS6_TARGET
        // iOS 8: the view runs under the translucent bar, and the content starts at
        // topLayoutGuide (0 under an opaque bar, which UIKit already insets the view for;
        // navigationBar.frame is still 44 high on the first appearance). Laying out once,
        // on the first pass, left the logo partly under the bar, and the iPad rotates: so
        // the frames follow the guide and the width whenever either changes. Not while
        // the keyboard has slid the view up; hiding it lays out again.
        let top = topLayoutGuide.length
        let width = view.bounds.width
        guard top != laidOutTop || width != laidOutWidth else { return }
        guard !slidUp || laidOutWidth == 0 else { return }
        DebugLog.shared.log("UI", "login screen laid out below y \(Int(top)), \(Int(width)) wide")
        layoutUI(top: top)
#endif
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // The views, without frames: layoutUI sets those.
    private func buildUI() {
        logoView = UIImageView(frame: .zero)
        logoView.image = UIImage(named: "Logo@2x")
        logoView.contentMode = .scaleAspectFit
        logoView.backgroundColor = .clear
        view.addSubview(logoView)

        serverField = makeField("Server (e.g. 192.168.1.10)", secure: false, returnKey: .next)
        serverField.keyboardType = .URL
        view.addSubview(serverField)

        hintLabel = UILabel(frame: .zero)
        hintLabel.text = "The port and http or https are found for you."
        hintLabel.font = UIFont.systemFont(ofSize: 12)
        hintLabel.textColor = UIColor(white: 0.55, alpha: 1.0)
        hintLabel.backgroundColor = .clear
        hintLabel.adjustsFontSizeToFitWidth = true
        view.addSubview(hintLabel)

        usernameField = makeField("Username", secure: false, returnKey: .next)
        view.addSubview(usernameField)

        passwordField = makeField("Password", secure: true, returnKey: .go)
        view.addSubview(passwordField)

        connectButton = UIButton(type: .custom)
        connectButton.setTitle("Connect", for: .normal)
        connectButton.setTitleColor(.white, for: .normal)
        connectButton.setTitleColor(UIColor(white: 1.0, alpha: 0.5), for: .disabled)
        connectButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 17)
        connectButton.backgroundColor = accentColor
        connectButton.layer.cornerRadius = 10
        connectButton.addTarget(self, action: #selector(connectTapped), for: .touchUpInside)
        view.addSubview(connectButton)

        spinner = UIActivityIndicatorView(style: .whiteLarge)
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)
    }

    // Everything from `top`, the top of the visible area: 0 on iOS 6 (opaque bar), the
    // bar's bottom on iOS 8.
    private func layoutUI(top: CGFloat) {
        let w = view.bounds.width
        laidOutTop = top
        laidOutWidth = w
        let logoSize: CGFloat = 110
        logoView.frame = CGRect(x: (w - logoSize) / 2, y: top + 20, width: logoSize, height: logoSize)
        serverField.frame = CGRect(x: 20, y: top + 150, width: w - 40, height: 46)
        hintLabel.frame = CGRect(x: 24, y: top + 199, width: w - 48, height: 16)
        usernameField.frame = CGRect(x: 20, y: top + 224, width: w - 40, height: 46)
        passwordField.frame = CGRect(x: 20, y: top + 282, width: w - 40, height: 46)
        connectButton.frame = CGRect(x: 20, y: top + 346, width: w - 40, height: 46)
        spinner.center = CGPoint(x: w / 2, y: top + (view.bounds.height - top) / 2)
    }

    private func makeField(_ placeholder: String, secure: Bool, returnKey: UIReturnKeyType) -> UITextField {
        let f = UITextField(frame: .zero)
        f.backgroundColor = UIColor(white: 1.0, alpha: 0.08)
        f.textColor = .white
        f.contentVerticalAlignment = .center
        f.layer.cornerRadius = 10
        f.layer.borderColor = UIColor(white: 1.0, alpha: 0.15).cgColor
        f.layer.borderWidth = 1
        f.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 46))
        f.leftViewMode = .always
        f.isSecureTextEntry = secure
        f.autocapitalizationType = .none
        f.autocorrectionType = .no
        f.keyboardAppearance = .dark
        f.returnKeyType = returnKey
        f.delegate = self
        f.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [NSAttributedString.Key.foregroundColor: UIColor(white: 0.5, alpha: 1.0)]
        )
        return f
    }

    // MARK: - Keyboard avoidance

    private func registerKeyboardObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let screenHeight = UIScreen.main.bounds.height
        let visibleBottom = screenHeight - keyboardFrame.height
        let contentBottom = connectButton.frame.maxY + 16
        let needed = contentBottom - visibleBottom
        guard needed > 0 else { return }
        guard view.frame.origin.y == 0 else { return }
        slidUp = true
        // The form slides up over the logo, which fades rather than going under the bar
        // (an iPad in landscape, a 3.5-inch iPhone).
        let logoCovered = logoView.frame.minY - needed < laidOutTop
        UIView.animate(withDuration: duration) {
            self.view.frame.origin.y = -needed
            if logoCovered { self.logoView.alpha = 0 }
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        slidUp = false
        UIView.animate(withDuration: duration) {
            self.view.frame.origin.y = 0
            self.logoView.alpha = 1
        }
        view.setNeedsLayout()
    }

    // MARK: - Actions

    @objc private func connectTapped() {
        guard connectButton.isEnabled else { return }   // Go pressed while signing in
        view.endEditing(true)
        guard let raw = serverField.text, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            showAlert("Please enter the server URL."); return
        }
        guard let user = usernameField.text, !user.trimmingCharacters(in: .whitespaces).isEmpty else {
            showAlert("Please enter your username."); return
        }
        let pass = passwordField.text ?? ""

        setLoading(true)
        ServerAddress.find(raw) { server, problem in
            guard let server = server else {
                self.setLoading(false)
                self.showAlert(problem ?? "No Jellyfin server answered.")
                return
            }
            // The field shows the full address found, which a retry (after a wrong
            // password, say) then reaches directly.
            self.serverField.text = server.baseURL
            JellyfinAPI.login(serverURL: server.baseURL, username: user, password: pass) { success, errorMsg in
                self.setLoading(false)
                if success {
                    self.navigationController?.setViewControllers([HomeVC()], animated: true)
                } else {
                    self.showAlert(errorMsg ?? "The sign-in failed.")
                }
            }
        }
    }

    private func setLoading(_ loading: Bool) {
        connectButton.isEnabled = !loading
        connectButton.alpha = loading ? 0.5 : 1.0
        loading ? spinner.startAnimating() : spinner.stopAnimating()
    }

    private func showAlert(_ message: String) {
#if IOS6_TARGET
        let alert = UIAlertView()
        alert.title = "JellyOld"
        alert.message = message
        alert.addButton(withTitle: "OK")
        alert.show()
#else
        let alert = UIAlertController(title: "JellyOld", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
#endif
    }
}

extension ServerSetupVC: UITextFieldDelegate {
    // Next, Next, Go: the server and username lead to the following field, the
    // password signs in.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === serverField {
            usernameField.becomeFirstResponder()
        } else if textField === usernameField {
            passwordField.becomeFirstResponder()
        } else {
            connectTapped()
        }
        return true
    }
}
