import UIKit

class ServerSetupVC: UIViewController {

    private var serverField: UITextField!
    private var usernameField: UITextField!
    private var passwordField: UITextField!
    private var connectButton: UIButton!
    private var spinner: UIActivityIndicatorView!
    private var topOffset: CGFloat = 0
    private var didBuildUI = false

    private let bgColor = UIColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1.0)
    private let accentColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1.0)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "JellyOld"
        view.backgroundColor = bgColor
        registerKeyboardObservers()
#if IOS6_TARGET
        // iOS 6/7: nav bar is opaque, view starts below it automatically — build immediately
        buildUI()
#endif
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
#if !IOS6_TARGET
        // Read nav bar bottom once the nav stack is fully wired up
        topOffset = navigationController?.navigationBar.frame.maxY ?? 64
#endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
#if !IOS6_TARGET
        // iOS 8/9: build UI once, after topOffset has been set in viewWillAppear
        guard !didBuildUI, topOffset > 0 else { return }
        didBuildUI = true
        buildUI()
#endif
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func buildUI() {
        let w = view.bounds.width
        let top = topOffset   // 0 on iOS 6 (opaque bar), nav bar bottom on iOS 8

        let logoSize: CGFloat = 110
        let logoView = UIImageView(frame: CGRect(x: (w - logoSize) / 2, y: top + 20,
                                                  width: logoSize, height: logoSize))
        logoView.image = UIImage(named: "Logo@2x")
        logoView.contentMode = .scaleAspectFit
        logoView.backgroundColor = .clear
        view.addSubview(logoView)

        serverField = makeField("Server URL  (e.g. http://192.168.1.10:8096)",
                                y: top + 150, secure: false)
        serverField.keyboardType = .URL
        view.addSubview(serverField)

        usernameField = makeField("Username", y: top + 208, secure: false)
        view.addSubview(usernameField)

        passwordField = makeField("Password", y: top + 266, secure: true)
        view.addSubview(passwordField)

        connectButton = UIButton(type: .custom)
        connectButton.frame = CGRect(x: 20, y: top + 330, width: w - 40, height: 46)
        connectButton.setTitle("Connect", for: .normal)
        connectButton.setTitleColor(.white, for: .normal)
        connectButton.setTitleColor(UIColor(white: 1.0, alpha: 0.5), for: .disabled)
        connectButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 17)
        connectButton.backgroundColor = accentColor
        connectButton.layer.cornerRadius = 10
        connectButton.addTarget(self, action: #selector(connectTapped), for: .touchUpInside)
        view.addSubview(connectButton)

        let visibleMidY = top + (view.bounds.height - top) / 2
        spinner = UIActivityIndicatorView(style: .whiteLarge)
        spinner.center = CGPoint(x: w / 2, y: visibleMidY)
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)
    }

    private func makeField(_ placeholder: String, y: CGFloat, secure: Bool) -> UITextField {
        let f = UITextField(frame: CGRect(x: 20, y: y, width: view.bounds.width - 40, height: 46))
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
        f.returnKeyType = .done
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
        guard connectButton != nil else { return }
        guard let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let screenHeight = UIScreen.main.bounds.height
        let visibleBottom = screenHeight - keyboardFrame.height
        let contentBottom = connectButton.frame.maxY + 16
        let needed = contentBottom - visibleBottom
        guard needed > 0 else { return }
        guard view.frame.origin.y == 0 else { return }
        UIView.animate(withDuration: duration) { self.view.frame.origin.y = -needed }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        UIView.animate(withDuration: duration) { self.view.frame.origin.y = 0 }
    }

    // MARK: - Actions

    @objc private func connectTapped() {
        view.endEditing(true)
        guard let raw = serverField.text, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            showAlert("Please enter the server URL."); return
        }
        guard let user = usernameField.text, !user.trimmingCharacters(in: .whitespaces).isEmpty else {
            showAlert("Please enter your username."); return
        }
        let pass = passwordField.text ?? ""
        let serverURL = raw.hasSuffix("/") ? String(raw.dropLast()) : raw

        setLoading(true)
        JellyfinAPI.login(serverURL: serverURL, username: user, password: pass) { success, errorMsg in
            self.setLoading(false)
            if success {
                self.navigationController?.setViewControllers([LibraryListVC()], animated: true)
            } else {
                self.showAlert(errorMsg ?? "Connection failed.")
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
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
