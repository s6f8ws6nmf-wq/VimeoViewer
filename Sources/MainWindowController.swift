import AppKit
import WebKit

/// Hlavné okno: režim „Prehliadať“ (vimeo.com) a režim „Video“ so štyrmi panelmi
/// – Prepis | Video | Komentáre / Zdieľanie.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
                                  WKNavigationDelegate, WKUIDelegate, PlayerDelegate {
    enum Mode: Int { case browse = 0, video = 1 }

    static let homeURL = URL(string: "https://vimeo.com/")!

    private(set) var mode: Mode = .browse
    private var browseView: WKWebView!
    let player = PlayerViewController()
    let transcript = TranscriptViewController()
    let comments = CommentsViewController()
    let share = ShareViewController()
    private let videoSplit = NSSplitViewController()
    private let rightSplit = NSSplitViewController()
    private var transcriptItem: NSSplitViewItem!
    private var rightItem: NSSplitViewItem!
    private var commentsItem: NSSplitViewItem!
    private weak var shareDivider: NSView?

    private let modeControl = NSSegmentedControl(labels: ["Prehliadať", "Video"], trackingMode: .selectOne,
                                                 target: nil, action: nil)
    private let addressField = NSTextField()
    private var urlObservation: NSKeyValueObservation?
    private var titleObservation: NSKeyValueObservation?
    private var popups: [PopupWindowController] = []
    /// ID videa, ktorého stránku chceme zámerne ukázať na vimeo.com (napr. komentáre na webe).
    private var allowedBrowserVideoID: String?
    private var didSetInitialSplit = false
    private var videoTitle: String?
    private var videoAuthor: String?

    private enum ToolbarID {
        static let back = NSToolbarItem.Identifier("back")
        static let forward = NSToolbarItem.Identifier("forward")
        static let mode = NSToolbarItem.Identifier("mode")
        static let address = NSToolbarItem.Identifier("address")
        static let home = NSToolbarItem.Identifier("home")
        static let reload = NSToolbarItem.Identifier("reload")
        static let login = NSToolbarItem.Identifier("login")
    }

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 980, height: 560)
        win.title = "Vimeo Viewer"
        win.toolbarStyle = .unified
        win.tabbingMode = .disallowed
        super.init(window: win)
        win.delegate = self
        buildContent()
        buildToolbar()
        win.center()
        win.setFrameAutosaveName("MainWindow")
        setMode(.browse, loadHome: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Obsah

    private func buildContent() {
        let config = WebKitFactory.configuration()
        browseView = WKWebView(frame: .zero, configuration: config)
        browseView.navigationDelegate = self
        browseView.uiDelegate = self
        browseView.allowsBackForwardNavigationGestures = true
        browseView.allowsMagnification = true

        player.delegate = self
        VimeoAPI.shared.webBridge = player
        transcript.onSeek = { [weak self] t in self?.player.seek(to: t) }
        comments.onSeek = { [weak self] t in self?.player.seek(to: t) }
        comments.onOpenURL = { url in AppDelegate.shared.route(url) }
        comments.onOpenSettings = { [weak self] in self?.showLogin(nil) }
        comments.onOpenOnWeb = { [weak self] in self?.showCurrentVideoOnWeb() }
        share.currentTime = { [weak self] in self?.player.currentTime ?? 0 }
        share.onOpenInBrowser = { url in BrowserForwarder.shared.open([url]) }

        player.onTracks = { [weak self] list, err in self?.transcript.playerTracks(list, error: err) }
        player.onVTT = { [weak self] url, text, err in self?.transcript.playerVTT(url: url, text: text, error: err) }
        transcript.requestPlayerTrack = { [weak self] t in self?.player.loadTrack(url: t.url) }

        // Ľavý (hlavný) stĺpec: veľké video + kompaktná lišta zdieľania pod ním
        let videoColumn = NSViewController()
        let column = NSStackView()
        column.orientation = .vertical
        column.spacing = 0
        column.distribution = .fill
        column.alignment = .leading
        videoColumn.view = column
        videoColumn.addChild(player)
        videoColumn.addChild(share)
        let divider = UI.separator()
        for v in [player.view, divider, share.view] {
            column.addArrangedSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
            v.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
            v.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true
        }
        player.view.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        player.view.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)
        shareDivider = divider

        // Pravý bočný panel: Prepis nad Komentármi
        rightSplit.splitView.isVertical = false
        rightSplit.splitView.dividerStyle = .thin
        transcriptItem = NSSplitViewItem(viewController: transcript)
        transcriptItem.minimumThickness = 150
        transcriptItem.canCollapse = true
        transcriptItem.holdingPriority = NSLayoutConstraint.Priority(250)
        commentsItem = NSSplitViewItem(viewController: comments)
        commentsItem.minimumThickness = 150
        commentsItem.canCollapse = true
        commentsItem.holdingPriority = NSLayoutConstraint.Priority(250)
        rightSplit.addSplitViewItem(transcriptItem)
        rightSplit.addSplitViewItem(commentsItem)
        rightSplit.splitView.autosaveName = "VimeoViewer.Sidebar2"

        // Hlavné rozdelenie: Video (dominantné) | bočný panel
        videoSplit.splitView.isVertical = true
        videoSplit.splitView.dividerStyle = .thin
        let videoItem = NSSplitViewItem(viewController: videoColumn)
        videoItem.minimumThickness = 520
        videoItem.holdingPriority = NSLayoutConstraint.Priority(240)
        rightItem = NSSplitViewItem(viewController: rightSplit)
        rightItem.minimumThickness = 280
        rightItem.maximumThickness = 640
        rightItem.canCollapse = true
        rightItem.holdingPriority = NSLayoutConstraint.Priority(260)
        videoSplit.addSplitViewItem(videoItem)
        videoSplit.addSplitViewItem(rightItem)
        videoSplit.splitView.autosaveName = "VimeoViewer.Main2"

        let container = NSViewController()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 860))
        container.view = root
        container.addChild(videoSplit)
        root.addSubview(browseView)
        root.addSubview(videoSplit.view)
        UI.pin(browseView, to: root)
        UI.pin(videoSplit.view, to: root)
        window?.contentViewController = container

        urlObservation = browseView.observe(\.url, options: [.new]) { [weak self] wv, _ in
            guard let self = self, let url = wv.url else { return }
            self.browseURLChanged(url)
        }
        titleObservation = browseView.observe(\.title, options: [.new]) { [weak self] _, _ in
            self?.updateWindowTitle()
        }
    }

    private func setInitialSplitIfNeeded() {
        guard !didSetInitialSplit else { return }
        didSetInitialSplit = true
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "NSSplitView Subview Frames VimeoViewer.Main2") == nil {
            let w = videoSplit.splitView.bounds.width
            // Video zaberie približne 72 % šírky okna.
            videoSplit.splitView.setPosition(max(520, (w * 0.72).rounded()), ofDividerAt: 0)
        }
        if defaults.object(forKey: "NSSplitView Subview Frames VimeoViewer.Sidebar2") == nil {
            let h = rightSplit.splitView.bounds.height
            rightSplit.splitView.setPosition((h * 0.55).rounded(), ofDividerAt: 0)
        }
    }

    // MARK: Panel nástrojov

    private func buildToolbar() {
        let tb = NSToolbar(identifier: "VimeoViewer.Toolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        window?.toolbar = tb

        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.selectedSegment = 0

        addressField.placeholderString = "Odkaz na Vimeo, číslo videa alebo hľadaný výraz"
        addressField.bezelStyle = .roundedBezel
        addressField.lineBreakMode = .byTruncatingTail
        addressField.usesSingleLineMode = true
        addressField.target = self
        addressField.action = #selector(addressEntered)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [ToolbarID.back, ToolbarID.forward, ToolbarID.mode, .flexibleSpace,
                ToolbarID.address, .flexibleSpace, ToolbarID.reload, ToolbarID.home, ToolbarID.login]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case ToolbarID.back:
            configure(item, symbol: "chevron.left", label: "Späť", action: #selector(goBack(_:)))
            item.isNavigational = true
        case ToolbarID.forward:
            configure(item, symbol: "chevron.right", label: "Dopredu", action: #selector(goForward(_:)))
            item.isNavigational = true
        case ToolbarID.home:
            configure(item, symbol: "house", label: "Domov", action: #selector(goHome(_:)))
        case ToolbarID.reload:
            configure(item, symbol: "arrow.clockwise", label: "Obnoviť", action: #selector(reloadPage(_:)))
        case ToolbarID.login:
            configure(item, symbol: "person.crop.circle", label: "Prihlásiť sa do Vimea", action: #selector(showLogin(_:)))
        case ToolbarID.mode:
            item.label = "Režim"
            item.view = modeControl
        case ToolbarID.address:
            item.label = "Adresa"
            item.view = addressField
            item.minSize = NSSize(width: 260, height: 24)
            item.maxSize = NSSize(width: 720, height: 24)
        default:
            return nil
        }
        return item
    }

    private func configure(_ item: NSToolbarItem, symbol: String, label: String, action: Selector) {
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        item.isBordered = true
    }

    // MARK: Režimy

    @objc private func modeChanged() {
        setMode(Mode(rawValue: modeControl.selectedSegment) ?? .browse)
    }

    func setMode(_ m: Mode, loadHome: Bool = true) {
        mode = m
        browseView.isHidden = (m != .browse)
        videoSplit.view.isHidden = (m != .video)
        modeControl.selectedSegment = m.rawValue
        if m == .browse {
            player.pause()
            addressField.stringValue = browseView.url?.absoluteString ?? ""
            if loadHome && browseView.url == nil { browseView.load(URLRequest(url: MainWindowController.homeURL)) }
        } else {
            addressField.stringValue = player.currentRef?.pageURL.absoluteString ?? ""
            comments.reloadIfNeedsLogin()
            DispatchQueue.main.async { [weak self] in self?.setInitialSplitIfNeeded() }
        }
        updateWindowTitle()
    }

    private func updateWindowTitle() {
        guard let w = window else { return }
        if mode == .browse {
            let t = browseView.title ?? ""
            w.title = t.isEmpty ? "Vimeo" : t
            w.subtitle = ""
        } else {
            w.title = videoTitle ?? (player.currentRef == nil ? "Video" : "Načítavam…")
            w.subtitle = videoAuthor ?? ""
        }
    }

    // MARK: Otváranie obsahu

    func openVideo(_ ref: VimeoVideoRef) {
        if player.currentRef != nil, ref.isSameVideo(player.currentRef) {
            setMode(.video)
            if let t = ref.startTime { player.seek(to: t) }
            return
        }
        videoTitle = nil
        videoAuthor = nil
        player.load(ref)
        transcript.load(ref)
        comments.load(ref)
        share.load(ref, info: nil)
        setMode(.video)
        VimeoAPI.shared.videoInfo(ref) { [weak self] r in
            guard let self = self, ref.isSameVideo(self.player.currentRef) else { return }
            switch r {
            case .success(let info):
                self.videoTitle = info.title
                self.videoAuthor = info.author
                self.player.setInfo(info)
                self.share.setInfo(info)
            case .failure:
                self.videoTitle = "Video \(ref.id)"
                self.player.setInfo(VideoInfo(title: "Video \(ref.id)", author: "", authorURL: nil,
                                              description: "", duration: 0, thumbnailURL: nil))
            }
            self.updateWindowTitle()
        }
    }

    func openBrowse(_ url: URL, allowVideoPage videoID: String? = nil) {
        allowedBrowserVideoID = videoID
        browseView.load(URLRequest(url: url))
        setMode(.browse)
    }

    private func showCurrentVideoOnWeb() {
        guard let ref = player.currentRef else { return }
        openBrowse(ref.pageURL, allowVideoPage: ref.id)
    }

    /// Aktuálne zobrazená adresa (video s časom alebo stránka v prehliadaní).
    var currentURL: URL? {
        if mode == .video, let r = player.currentRef { return r.pageURL(at: player.currentTime) }
        return browseView.url
    }

    // MARK: Akcie (toolbar + menu)

    @objc func goBack(_ sender: Any?) {
        if mode == .video { setMode(.browse); return }
        if browseView.canGoBack { browseView.goBack() }
    }

    @objc func goForward(_ sender: Any?) {
        if mode == .browse, browseView.canGoForward { browseView.goForward() }
        else if mode == .browse, player.currentRef != nil { setMode(.video) }
    }

    static let loginURL = URL(string: "https://vimeo.com/log_in")!

    @objc func showLogin(_ sender: Any?) { openBrowse(MainWindowController.loginURL) }

    @objc func goHome(_ sender: Any?) { openBrowse(MainWindowController.homeURL) }

    @objc func reloadPage(_ sender: Any?) {
        if mode == .browse { browseView.reload() }
        else if let r = player.currentRef {
            var ref = r
            ref.startTime = player.currentTime
            player.load(ref)
            transcript.load(r)
            comments.load(r)
        }
    }

    func focusAddress() {
        window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    func focusTranscriptSearch() {
        if mode != .video { setMode(.video) }
        if rightItem.isCollapsed { rightItem.animator().isCollapsed = false }
        if transcriptItem.isCollapsed { transcriptItem.animator().isCollapsed = false }
        transcript.focusSearch()
    }

    @objc private func addressEntered() {
        let s = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if VimeoLinks.isNumeric(s) {
            openVideo(VimeoVideoRef(id: s, hash: nil, startTime: nil))
            return
        }
        if let u = URL(string: s), let scheme = u.scheme?.lowercased(), ["http", "https", "vimeoviewer"].contains(scheme) {
            AppDelegate.shared.route(u)
            return
        }
        if !s.contains(" "), s.contains("."), let u = URL(string: "https://" + s), u.host != nil {
            AppDelegate.shared.route(u)
            return
        }
        var c = URLComponents(string: "https://vimeo.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: s)]
        openBrowse(c.url!)
    }

    // MARK: Panely

    enum Panel { case transcript, comments, share }

    func togglePanel(_ p: Panel) {
        if mode != .video { setMode(.video) }
        switch p {
        case .share:
            let hide = !share.view.isHidden
            share.view.isHidden = hide
            shareDivider?.isHidden = hide
        case .transcript, .comments:
            let item = (p == .transcript) ? transcriptItem! : commentsItem!
            let other = (p == .transcript) ? commentsItem! : transcriptItem!
            if rightItem.isCollapsed {
                // Bočný panel je skrytý – zobraz ho len s vybraným panelom.
                item.isCollapsed = false
                other.isCollapsed = true
                rightItem.animator().isCollapsed = false
            } else if item.isCollapsed {
                item.animator().isCollapsed = false
            } else if other.isCollapsed {
                rightItem.animator().isCollapsed = true
            } else {
                item.animator().isCollapsed = true
            }
        }
    }

    func isPanelVisible(_ p: Panel) -> Bool {
        switch p {
        case .transcript: return !rightItem.isCollapsed && !transcriptItem.isCollapsed
        case .comments: return !rightItem.isCollapsed && !commentsItem.isCollapsed
        case .share: return !share.view.isHidden
        }
    }

    // MARK: PlayerDelegate

    func player(_ player: PlayerViewController, didUpdateTime time: Double, duration: Double) {
        transcript.update(time: time)
        share.update(time: time)
    }

    func player(_ player: PlayerViewController, requestsOpen url: URL) {
        AppDelegate.shared.route(url)
    }

    // MARK: Prehliadanie vimeo.com

    private func browseURLChanged(_ url: URL) {
        if mode == .browse { addressField.stringValue = url.absoluteString }
        // Vimeo je single-page aplikácia – prechod na video často nevyvolá navigáciu, iba zmenu URL.
        if let ref = VimeoLinks.videoRef(from: url), ref.id != allowedBrowserVideoID {
            browseView.evaluateJavaScript("document.querySelectorAll('video').forEach(function(v){v.pause()})",
                                          completionHandler: nil)
            if browseView.canGoBack { browseView.goBack() }
            openVideo(ref)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow); return
        }
        if ["mailto", "tel", "sms", "facetime"].contains(scheme) {
            decisionHandler(.cancel)
            NSWorkspace.shared.open(url)
            return
        }
        guard scheme == "http" || scheme == "https" else { decisionHandler(.allow); return }

        let isMain = navigationAction.targetFrame?.isMainFrame ?? true
        if isMain {
            if let ref = VimeoLinks.videoRef(from: url) {
                if ref.id != allowedBrowserVideoID {
                    decisionHandler(.cancel)
                    openVideo(ref)
                    return
                }
            } else if VimeoLinks.isVimeoSiteHost(url.host) {
                allowedBrowserVideoID = nil
            }
            if navigationAction.navigationType == .linkActivated && !VimeoLinks.isInAppHost(url.host) {
                decisionHandler(.cancel)
                BrowserForwarder.shared.open([url])
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme?.hasPrefix("http") == true {
            if let ref = VimeoLinks.videoRef(from: url) { openVideo(ref); return nil }
            if VimeoLinks.isVimeoSiteHost(url.host) { browseView.load(URLRequest(url: url)); return nil }
            if !VimeoLinks.isAuthHost(url.host) { BrowserForwarder.shared.open([url]); return nil }
        }
        // Prihlasovacie okná (Google, Apple…) alebo about:blank
        let popup = PopupWindowController(configuration: configuration, features: windowFeatures)
        popup.onClose = { [weak self] p in self?.popups.removeAll { $0 === p } }
        popups.append(popup)
        popup.showWindow(nil)
        return popup.webView
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Zrušiť")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        player.pause()
    }
}
