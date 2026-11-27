import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) static var shared: AppDelegate!

    private var mainWindow: MainWindowController?
    private var preferences: PreferencesWindowController?
    private var loginWindow: LoginWindowController?
    private var diagnosticsWindow: DiagnosticsWindowController?
    private var transfersWindow: TransfersWindowController?

    @objc func showTransfers(_ sender: Any?) {
        if transfersWindow == nil { transfersWindow = TransfersWindowController() }
        transfersWindow?.refresh()
        transfersWindow?.showWindow(nil)
    }

    @objc func uploadVideo(_ sender: Any?) {
        showMainWindow(nil)
        mainWindow?.setMode(.library)
        mainWindow?.library.uploadVideo()
    }

    @objc func downloadVideo(_ sender: Any?) {
        guard let w = mainWindow, w.player.currentRef != nil else { NSSound.beep(); return }
        w.share.download(nil)
    }

    @objc func showDiagnostics(_ sender: Any?) {
        if diagnosticsWindow == nil { diagnosticsWindow = DiagnosticsWindowController() }
        diagnosticsWindow?.refresh()
        diagnosticsWindow?.showWindow(nil)
        diagnosticsWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private var receivedURLAtLaunch = false

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    // MARK: Životný cyklus

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Updater.shared.checkInBackground() }
        // Ak bola aplikácia spustená kvôli odkazu, okno otvorí až router.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self else { return }
            if !self.receivedURLAtLaunch {
                let w = self.ensureWindow()
                w.showStart()
                self.bringToFront()
                self.askToBecomeDefaultBrowserOnce()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Aplikácia ostáva bežať, aby mohla ďalej prijímať a presmerovávať odkazy.
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            let w = ensureWindow()
            if w.player.currentRef == nil && w.mode == .browse { w.showStart() }
            bringToFront()
        }
        return true
    }

    // MARK: Prijaté odkazy (http/https/vimeoviewer a súbory)

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedURLAtLaunch = true
        for u in urls { route(u) }
    }

    /// Hlavný router: Vimeo video → panel Video, iná Vimeo stránka → Prehliadať, všetko ostatné → prehliadač.
    func route(_ raw: URL) {
        if raw.isFileURL {
            if raw.pathExtension.lowercased() == "webloc",
               let dict = NSDictionary(contentsOf: raw), let s = dict["URL"] as? String, let u = URL(string: s) {
                route(u)
            } else {
                BrowserForwarder.shared.open([raw])
            }
            return
        }
        // Príkazy: open "vimeoviewer://set-default-browser" / "vimeoviewer://restore-default-browser"
        if raw.scheme?.lowercased() == "vimeoviewer" {
            switch raw.host?.lowercased() {
            case "set-default-browser":
                BrowserForwarder.shared.makeDefaultBrowser(); return
            case "restore-default-browser":
                BrowserForwarder.shared.restoreDefaultBrowser(); return
            case "settings":
                showPreferences(nil); return
            default:
                break
            }
        }
        let url = VimeoLinks.normalize(raw)
        if let ref = VimeoLinks.videoRef(from: url) {
            let w = ensureWindow()
            w.openVideo(ref)
            bringToFront()
        } else if VimeoLinks.isVimeoSiteHost(url.host), let s = url.scheme?.lowercased(), s == "http" || s == "https" {
            let w = ensureWindow()
            w.openBrowse(url)
            bringToFront()
        } else {
            BrowserForwarder.shared.open([url])
        }
    }

    @discardableResult
    private func ensureWindow() -> MainWindowController {
        if let w = mainWindow { return w }
        let w = MainWindowController()
        mainWindow = w
        return w
    }

    private func bringToFront() {
        guard let w = mainWindow else { return }
        w.showWindow(nil)
        w.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func askToBecomeDefaultBrowserOnce() {
        let key = "askedToBecomeDefaultBrowser"
        let fw = BrowserForwarder.shared
        guard !UserDefaults.standard.bool(forKey: key), !fw.isDefaultBrowser, let win = mainWindow?.window else { return }
        UserDefaults.standard.set(true, forKey: key)
        var browserName = "Safari"
        if let id = fw.currentDefaultBrowserID(), let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            browserName = BrowserForwarder.appName(appURL)
        }
        let a = NSAlert()
        a.messageText = "Otvárať odkazy na Vimeo vždy v tejto aplikácii?"
        a.informativeText = "macOS posiela odkazy z prezentácií, PDF či e-mailov do predvoleného webového prehliadača. Ak Vimeo Viewer nastavíte ako predvolený prehliadač, Vimeo odkazy sa otvoria tu a všetky ostatné odkazy sa okamžite prepošlú do prehliadača \(browserName).\n\nNastavenie môžete kedykoľvek zmeniť v Nastaveniach (⌘,)."
        a.addButton(withTitle: "Nastaviť")
        a.addButton(withTitle: "Neskôr")
        a.beginSheetModal(for: win) { resp in
            if resp == .alertFirstButtonReturn { fw.makeDefaultBrowser() }
        }
    }

    // MARK: Akcie menu

    @objc func showPreferences(_ sender: Any?) {
        if preferences == nil { preferences = PreferencesWindowController() }
        preferences?.refresh()
        preferences?.showWindow(nil)
        preferences?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func makeDefaultBrowser(_ sender: Any?) {
        BrowserForwarder.shared.makeDefaultBrowser()
    }

    @objc func showMainWindow(_ sender: Any?) {
        let w = ensureWindow()
        if w.player.currentRef == nil && w.mode == .browse { w.showStart() }
        bringToFront()
    }

    @objc func openLocation(_ sender: Any?) {
        showMainWindow(nil)
        mainWindow?.focusAddress()
    }

    @objc func openPasteboardLink(_ sender: Any?) {
        guard let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let u = URL(string: s), u.scheme != nil else { NSSound.beep(); return }
        route(u)
    }

    @objc func openInBrowser(_ sender: Any?) {
        if let u = mainWindow?.currentURL { BrowserForwarder.shared.open([u]) }
    }

    @objc func copyLinkAtTime(_ sender: Any?) {
        guard let w = mainWindow, let r = w.player.currentRef else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(r.pageURL(at: w.player.currentTime).absoluteString, forType: .string)
    }

    @objc func setHomePage(_ sender: Any?) { mainWindow?.setCurrentPageAsHome() }
    @objc func resetHomePage(_ sender: Any?) { mainWindow?.resetHome() }
    @objc func showLibraryMode(_ sender: Any?) { showMainWindow(nil); mainWindow?.setMode(.library) }
    @objc func showBrowseMode(_ sender: Any?) { showMainWindow(nil); mainWindow?.setMode(.browse) }
    @objc func showVideoMode(_ sender: Any?) { showMainWindow(nil); mainWindow?.setMode(.video) }
    @objc func toggleTranscript(_ sender: Any?) { mainWindow?.togglePanel(.transcript) }
    @objc func toggleComments(_ sender: Any?) { mainWindow?.togglePanel(.comments) }
    @objc func toggleShare(_ sender: Any?) { mainWindow?.togglePanel(.share) }
    @objc func findInTranscript(_ sender: Any?) { mainWindow?.focusTranscriptSearch() }

    @objc func navBack(_ sender: Any?) { mainWindow?.goBack(nil) }
    @objc func navForward(_ sender: Any?) { mainWindow?.goForward(nil) }
    @objc func login(_ sender: Any?) { showLoginWindow(nil) }

    @objc func showLoginWindow(_ sender: Any?) {
        if loginWindow == nil {
            let w = LoginWindowController()
            w.onLoggedIn = { [weak self] in self?.mainWindow?.accountChanged() }
            w.onOpenWebLogin = { [weak self] in
                guard let self = self else { return }
                let m = self.ensureWindow()
                m.openWebLogin()
                self.bringToFront()
            }
            loginWindow = w
        }
        loginWindow?.refreshStatus()
        loginWindow?.showWindow(nil)
        loginWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func navHome(_ sender: Any?) { showMainWindow(nil); mainWindow?.goHome(nil) }
    @objc func navReload(_ sender: Any?) { mainWindow?.reloadPage(nil) }

    @objc func playPause(_ sender: Any?) { mainWindow?.player.togglePlay() }
    @objc func skipBack(_ sender: Any?) { mainWindow?.player.skip(-10) }
    @objc func skipForward(_ sender: Any?) { mainWindow?.player.skip(10) }
    @objc func setRate(_ sender: NSMenuItem) { mainWindow?.player.setRate(Double(sender.tag) / 100.0) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let w = mainWindow
        guard let action = item.action else { return true }
        switch action {
        case #selector(toggleTranscript(_:)):
            item.state = (w?.isPanelVisible(.transcript) ?? true) ? .on : .off
            return w != nil
        case #selector(toggleComments(_:)):
            item.state = (w?.isPanelVisible(.comments) ?? true) ? .on : .off
            return w != nil
        case #selector(toggleShare(_:)):
            item.state = (w?.isPanelVisible(.share) ?? true) ? .on : .off
            return w != nil
        case #selector(showBrowseMode(_:)):
            item.state = w?.mode == .browse ? .on : .off
            return true
        case #selector(showLibraryMode(_:)):
            item.state = w?.mode == .library ? .on : .off
            return true
        case #selector(showVideoMode(_:)):
            item.state = w?.mode == .video ? .on : .off
            return true
        case #selector(playPause(_:)), #selector(skipBack(_:)), #selector(skipForward(_:)),
             #selector(setRate(_:)), #selector(copyLinkAtTime(_:)), #selector(downloadVideo(_:)):
            return w?.player.currentRef != nil
        case #selector(makeDefaultBrowser(_:)):
            return !BrowserForwarder.shared.isDefaultBrowser
        default:
            return true
        }
    }
}
