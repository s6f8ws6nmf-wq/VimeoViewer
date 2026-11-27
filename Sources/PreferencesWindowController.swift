import AppKit

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let browserPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let defaultStatus = UI.label("", size: 12)
    private let defaultButton = NSButton(title: "", target: nil, action: nil)
    private let tokenField = NSSecureTextField()
    private let tokenStatus = UI.label("", size: 11, color: .secondaryLabelColor)
    private var browsers: [(id: String, name: String)] = []

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.title = "Nastavenia"
        super.init(window: win)
        win.delegate = self
        build()
        win.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func section(_ s: String) -> NSTextField { UI.label(s, size: 13, weight: .semibold) }

    private func build() {
        // Odkazy
        let linksInfo = UI.wrappingLabel("Aby sa odkazy na Vimeo z Keynote, PowerPointu, PDF, Mailu či iných aplikácií otvárali v tejto aplikácii, nastavte ju ako predvolený webový prehliadač. Všetky ostatné odkazy aplikácia okamžite pošle do prehliadača vybraného nižšie.")
        defaultButton.bezelStyle = .rounded
        defaultButton.target = self
        defaultButton.action = #selector(toggleDefault)
        let defaultRow = NSStackView(views: [defaultStatus, NSView(), defaultButton])
        defaultRow.orientation = .horizontal

        browserPopup.target = self
        browserPopup.action = #selector(browserChanged)
        let browserRow = NSStackView(views: [UI.label("Ostatné odkazy otvárať v:"), browserPopup, NSView()])
        browserRow.orientation = .horizontal

        // Token
        let tokenInfo = UI.wrappingLabel("Komentáre (a prepis súkromných videí) sa načítavajú cez Vimeo API. Na developer.vimeo.com/apps vytvorte aplikáciu → „Generate an access token“ → Authenticated (you), s oprávneniami Public, Private a Interact. Token sa uloží do Kľúčenky.")
        tokenField.placeholderString = "Vimeo osobný prístupový token"
        let save = UI.button("Uložiť", target: self, action: #selector(saveToken))
        let remove = UI.button("Odstrániť", target: self, action: #selector(removeToken))
        let tokenRow = NSStackView(views: [tokenField, save, remove])
        tokenRow.orientation = .horizontal
        save.setContentHuggingPriority(.required, for: .horizontal)
        remove.setContentHuggingPriority(.required, for: .horizontal)
        let getToken = UI.button("Otvoriť developer.vimeo.com", symbol: "safari", target: self, action: #selector(openDeveloper))
        let tokenBottom = NSStackView(views: [getToken, NSView(), tokenStatus])
        tokenBottom.orientation = .horizontal

        let stack = UI.vstack([section("Odkazy na Vimeo"), linksInfo, defaultRow, browserRow,
                               UI.separator(),
                               section("Vimeo API token"), tokenInfo, tokenRow, tokenBottom],
                              spacing: 10, insets: NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20))
        let root = NSView()
        root.addSubview(stack)
        UI.pin(stack, to: root)
        root.widthAnchor.constraint(equalToConstant: 560).isActive = true
        window?.contentView = root
        refresh()
    }

    func refresh() {
        let fw = BrowserForwarder.shared
        if fw.isDefaultBrowser {
            defaultStatus.stringValue = "✓ Vimeo Viewer je predvolený prehliadač"
            defaultStatus.textColor = .systemGreen
            defaultButton.title = "Vrátiť \(fw.fallbackBrowserName)"
        } else {
            defaultStatus.stringValue = "Vimeo odkazy sa zatiaľ otvárajú v inom prehliadači"
            defaultStatus.textColor = .secondaryLabelColor
            defaultButton.title = "Nastaviť ako predvolený prehliadač"
        }
        browsers = fw.installedBrowsers()
        if !browsers.contains(where: { $0.id.lowercased() == "com.apple.safari" }) {
            browsers.insert((id: "com.apple.Safari", name: "Safari"), at: 0)
        }
        browserPopup.removeAllItems()
        browserPopup.addItems(withTitles: browsers.map { $0.name })
        let cur = fw.fallbackBundleID.lowercased()
        if let i = browsers.firstIndex(where: { $0.id.lowercased() == cur }) { browserPopup.selectItem(at: i) }
        tokenStatus.stringValue = VimeoAPI.shared.token == nil ? "Token nie je nastavený" : "✓ Token je uložený"
    }

    @objc private func toggleDefault() {
        let fw = BrowserForwarder.shared
        if fw.isDefaultBrowser { fw.restoreDefaultBrowser() } else { fw.makeDefaultBrowser() }
        // macOS sa pýta cez systémový dialóg – stav overíme o chvíľu.
        for delay in [1.0, 3.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
        }
    }

    @objc private func browserChanged() {
        let i = browserPopup.indexOfSelectedItem
        guard i >= 0, i < browsers.count else { return }
        BrowserForwarder.shared.fallbackBundleID = browsers[i].id
    }

    @objc private func saveToken() {
        VimeoAPI.shared.token = tokenField.stringValue
        tokenField.stringValue = ""
        refresh()
    }

    @objc private func removeToken() {
        VimeoAPI.shared.token = nil
        refresh()
    }

    @objc private func openDeveloper() {
        BrowserForwarder.shared.open([URL(string: "https://developer.vimeo.com/apps")!])
    }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }
}
