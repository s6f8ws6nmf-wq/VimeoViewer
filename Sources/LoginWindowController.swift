import AppKit
import WebKit

/// Vlastné prihlasovacie okno – nezávisí od vykreslenia stránky vimeo.com/log_in.
/// Prihlásenie prebehne požiadavkou z pozadia (rovnaká relácia/cookies ako zvyšok aplikácie).
final class LoginWindowController: NSWindowController, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    var onLoggedIn: (() -> Void)?
    var onOpenWebLogin: (() -> Void)?

    private let emailField = NSTextField()
    private let passField = NSSecureTextField()
    private let statusLabel = UI.wrappingLabel("", size: 12)
    private let accountLabel = UI.label("Zisťujem stav prihlásenia…", size: 12, color: .secondaryLabelColor)
    private let spinner = NSProgressIndicator()
    private var loginButton: NSButton!
    private var logoutButton: NSButton!
    private var helper: WKWebView!
    private var helperReady = false
    private var pending: [() -> Void] = []

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.title = "Prihlásenie do Vimea"
        super.init(window: win)
        win.delegate = self
        build()
        win.center()

        let cfg = WebKitFactory.configuration()
        cfg.userContentController.add(WeakScriptHandler(self), name: "login")
        helper = WKWebView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), configuration: cfg)
        helper.navigationDelegate = self
        helper.loadHTMLString(LoginWindowController.html, baseURL: URL(string: "https://vimeo.com/"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build() {
        let title = UI.label("Prihláste sa svojím Vimeo účtom", size: 15, weight: .semibold)
        emailField.placeholderString = "E-mail"
        passField.placeholderString = "Heslo"
        passField.target = self
        passField.action = #selector(login)
        loginButton = UI.button("Prihlásiť sa", target: self, action: #selector(login))
        loginButton.keyEquivalent = "\r"
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let row = NSStackView(views: [loginButton, spinner, NSView()])
        row.orientation = .horizontal

        logoutButton = UI.button("Odhlásiť sa", target: self, action: #selector(logout))
        logoutButton.isHidden = true
        let accountRow = NSStackView(views: [accountLabel, NSView(), logoutButton])
        accountRow.orientation = .horizontal

        let hint = UI.wrappingLabel("Účet cez Google/Apple alebo s dvojfázovým overením? Použite prihlásenie cez webovú stránku.", size: 11)
        let web = UI.button("Prihlásiť cez webovú stránku", symbol: "globe", target: self, action: #selector(openWeb))
        web.controlSize = .small

        let webkit = Bundle(identifier: "com.apple.WebKit")?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let version = UI.label("Safari \(WebKitFactory.safariVersion) · WebKit \(webkit)", size: 10, color: .tertiaryLabelColor)

        let stack = UI.vstack([title, accountRow, emailField, passField, row, statusLabel, UI.separator(), hint, web, version],
                              spacing: 9, insets: NSEdgeInsets(top: 20, left: 22, bottom: 16, right: 22))
        let root = NSView()
        root.addSubview(stack)
        UI.pin(stack, to: root)
        root.widthAnchor.constraint(equalToConstant: 440).isActive = true
        window?.contentView = root
        window?.initialFirstResponder = emailField
    }

    // MARK: Pomocná stránka (pôvod vimeo.com)

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        helperReady = true
        let p = pending
        pending = []
        p.forEach { $0() }
        refreshStatus()
    }

    private func run(_ script: String) {
        let work = { [weak self] in self?.helper.evaluateJavaScript(script, completionHandler: nil); return }
        if helperReady { work() } else { pending.append(work) }
    }

    func refreshStatus() { run("window.vvCheck()") }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "status":
            setAccount(body["user"] as? String)
        case "login":
            spinner.stopAnimation(nil)
            loginButton.isEnabled = true
            if body["ok"] as? Bool == true {
                setAccount(body["user"] as? String)
                statusLabel.textColor = .systemGreen
                statusLabel.stringValue = "✓ Prihlásenie úspešné."
                passField.stringValue = ""
                onLoggedIn?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.window?.close() }
            } else {
                statusLabel.textColor = .systemRed
                var msg = "Prihlásenie sa nepodarilo."
                if let e = body["error"] as? String, !e.isEmpty { msg += " (\(e))" }
                else if let s = body["status"] as? NSNumber { msg += " Skontrolujte e-mail a heslo. (HTTP \(s.intValue))" }
                statusLabel.stringValue = msg
            }
        default:
            break
        }
    }

    private func setAccount(_ user: String?) {
        if let u = user, !u.isEmpty {
            accountLabel.stringValue = "✓ Prihlásený ako \(u)"
            accountLabel.textColor = .systemGreen
            logoutButton.isHidden = false
        } else {
            accountLabel.stringValue = "Nie ste prihlásený."
            accountLabel.textColor = .secondaryLabelColor
            logoutButton.isHidden = true
        }
    }

    // MARK: Akcie

    @objc private func login() {
        let email = emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = passField.stringValue
        guard !email.isEmpty, !pass.isEmpty else { NSSound.beep(); return }
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Prihlasujem…"
        loginButton.isEnabled = false
        spinner.startAnimation(nil)
        run("window.vvLogin(\(PlayerViewController.jsString(email)), \(PlayerViewController.jsString(pass)))")
    }

    @objc private func logout() {
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.getAllCookies { [weak self] cookies in
            let group = DispatchGroup()
            for c in cookies where c.domain.lowercased().contains("vimeo") {
                group.enter()
                store.delete(c) { group.leave() }
            }
            group.notify(queue: .main) {
                self?.refreshStatus()
                self?.onLoggedIn?()
            }
        }
    }

    @objc private func openWeb() {
        window?.close()
        onOpenWebLogin?()
    }

    func windowDidBecomeKey(_ notification: Notification) { refreshStatus() }

    // MARK: JavaScript

    static let html = """
    <!doctype html><html><head><meta charset="utf-8"></head><body>
    <script>
    function post(m){ try { window.webkit.messageHandlers.login.postMessage(m); } catch(e){} }
    function getJSON(path){
      return fetch(path, { credentials: 'include', headers: { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest' } })
        .then(function(r){ if (!r.ok) throw new Error(path + ' HTTP ' + r.status); return r.json(); });
    }
    function viewer(){ return getJSON('/_rv/viewer').catch(function(){ return getJSON('/_next/viewer'); }); }
    function who(v){
      if (!v) return null;
      var logged = v.is_logged_in || v.isLoggedIn || v.logged_in || (v.user_id && v.user_id !== 0 && v.user_id !== '0');
      if (!logged) return null;
      return String(v.name || v.display_name || v.user_name || v.user_id || 'Vimeo');
    }
    window.vvCheck = function(){
      viewer().then(function(v){ post({ type: 'status', user: who(v) }); })
              .catch(function(e){ post({ type: 'status', user: null, error: String((e && e.message) || e) }); });
    };
    window.vvLogin = function(email, pass){
      viewer().then(function(v){
        var token = v.xsrft || v.xsrf || v.token;
        if (!token) throw new Error('Vimeo nevrátilo bezpečnostný kľúč');
        var body = new URLSearchParams({ action: 'login', email: email, password: pass, service: 'vimeo', token: token });
        return fetch('/log_in', { method: 'POST', credentials: 'include',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-Requested-With': 'XMLHttpRequest' },
          body: body.toString() }).then(function(r){ return r.status; });
      }).then(function(status){
        return viewer().then(function(v){ var u = who(v); post({ type: 'login', ok: !!u, user: u, status: status }); });
      }).catch(function(e){ post({ type: 'login', ok: false, error: String((e && e.message) || e) }); });
    };
    </script></body></html>
    """
}
