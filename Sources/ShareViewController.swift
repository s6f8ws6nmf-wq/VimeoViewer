import AppKit
import CoreImage

/// Pravý dolný panel – možnosti zdieľania.
final class ShareViewController: NSViewController {
    var currentTime: () -> Double = { 0 }
    var onOpenInBrowser: ((URL) -> Void)?

    private var ref: VimeoVideoRef?
    private var info: VideoInfo?
    private let linkField = NSTextField()
    private let timeCheckbox = NSButton(checkboxWithTitle: "od 0:00", target: nil, action: nil)
    private let qrView = NSImageView()
    private let feedback = UI.label("", size: 11, color: .systemGreen)
    private var controls: [NSControl] = []
    private var lastSecond = -1
    private var shareButton: NSButton!
    private var reviewButton: NSButton!
    var onAddComment: (() -> Void)?
    var onReplace: (() -> Void)?
    var onUploadSubtitles: (() -> Void)?
    private var controlsExtra: [NSControl] = []

    @objc private func menuReplace() { onReplace?() }
    @objc private func menuSubtitles() { onUploadSubtitles?() }
    @objc private func menuDownload() { download(nil) }
    private var reviewLink: URL?

    override func loadView() {
        let root = NSView()

        let headIcon = NSImageView(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Zdieľanie") ?? NSImage())
        headIcon.contentTintColor = .secondaryLabelColor
        headIcon.setContentHuggingPriority(.required, for: .horizontal)

        linkField.isEditable = false
        linkField.isSelectable = true
        linkField.font = .systemFont(ofSize: 12)
        linkField.lineBreakMode = .byTruncatingMiddle
        linkField.cell?.usesSingleLineMode = true
        linkField.placeholderString = "Odkaz na video"
        linkField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        linkField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        linkField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true

        timeCheckbox.target = self
        timeCheckbox.action = #selector(refreshLink)
        timeCheckbox.controlSize = .small
        timeCheckbox.font = .systemFont(ofSize: 11)
        timeCheckbox.setContentHuggingPriority(.required, for: .horizontal)

        func icon(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
            let b = NSButton(image: img, target: self, action: action)
            b.bezelStyle = .texturedRounded
            b.toolTip = tip
            b.setContentHuggingPriority(.required, for: .horizontal)
            return b
        }
        let copyLinkBtn = UI.button("Kopírovať odkaz", symbol: "link", target: self, action: #selector(copyLink))
        copyLinkBtn.bezelStyle = .texturedRounded
        copyLinkBtn.setContentHuggingPriority(.required, for: .horizontal)
        shareButton = icon("square.and.arrow.up", "Zdieľať… (AirDrop, Poznámky, …)", #selector(showPicker(_:)))
        let buttons: [NSButton] = [
            copyLinkBtn,
            icon("chevron.left.slash.chevron.right", "Kopírovať embed kód", #selector(copyEmbed)),
            icon("doc.on.doc", "Kopírovať ako Markdown", #selector(copyMarkdown)),
            shareButton,
            icon("envelope", "Poslať e-mailom", #selector(email)),
            icon("message", "Poslať cez Správy", #selector(message)),
            icon("qrcode", "QR kód", #selector(showQR(_:))),
            icon("safari", "Otvoriť vo webovom prehliadači", #selector(openBrowser)),
            icon("arrow.down.circle", "Stiahnuť video", #selector(download(_:))),
        ]

        let social = NSPopUpButton(frame: .zero, pullsDown: true)
        social.bezelStyle = .texturedRounded
        social.setContentHuggingPriority(.required, for: .horizontal)
        let menu = NSMenu()
        menu.addItem(withTitle: "Sociálne siete", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "X / Twitter", action: #selector(shareX), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Facebook", action: #selector(shareFacebook), keyEquivalent: "").target = self
        menu.addItem(withTitle: "LinkedIn", action: #selector(shareLinkedIn), keyEquivalent: "").target = self
        social.menu = menu
        social.toolTip = "Zdieľať na sociálnych sieťach"

        feedback.setContentHuggingPriority(.required, for: .horizontal)

        // Výrazné tlačidlo – review odkaz Vimea (komentáre s časom pre kohokoľvek s odkazom)
        reviewButton = NSButton(title: "Review link", image: NSImage(systemSymbolName: "text.bubble.fill",
                                accessibilityDescription: "Review link") ?? NSImage(), target: self, action: #selector(reviewTapped(_:)))
        reviewButton.imagePosition = .imageLeading
        reviewButton.bezelStyle = .rounded
        reviewButton.font = .systemFont(ofSize: 13, weight: .semibold)
        reviewButton.keyEquivalent = ""
        reviewButton.toolTip = "Zdieľať review odkaz – ľudia s ním môžu pridávať komentáre s časom vo videu"
        reviewButton.setContentHuggingPriority(.required, for: .horizontal)
        // Menu „Video ▾“ – nahradenie videa, sťahovanie, titulky…
        let videoMenu = NSPopUpButton(frame: .zero, pullsDown: true)
        videoMenu.bezelStyle = .rounded
        videoMenu.font = .systemFont(ofSize: 13, weight: .semibold)
        videoMenu.setContentHuggingPriority(.required, for: .horizontal)
        let vm = NSMenu()
        let head = NSMenuItem(title: "Video", action: nil, keyEquivalent: "")
        head.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
        vm.addItem(head)
        for (title, symbol, sel) in [("Nahradiť video novým súborom (Replace)…", "arrow.triangle.2.circlepath", #selector(menuReplace)),
                                     ("Stiahnuť video…", "arrow.down.circle", #selector(menuDownload)),
                                     ("Nahrať titulky (.srt, .vtt…)…", "captions.bubble", #selector(menuSubtitles))] {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            vm.addItem(i)
        }
        vm.addItem(.separator())
        for (title, symbol, sel) in [("Otvoriť na vimeo.com", "safari", #selector(openBrowser)),
                                     ("Kopírovať odkaz", "link", #selector(copyLink))] {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            vm.addItem(i)
        }
        videoMenu.menu = vm
        videoMenu.toolTip = "Nahradiť video, stiahnuť, nahrať titulky…"
        controlsExtra.append(videoMenu)
        let row = NSStackView(views: [videoMenu, reviewButton, headIcon, linkField, timeCheckbox] + buttons + [social, feedback])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        row.setCustomSpacing(12, after: timeCheckbox)
        row.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            root.heightAnchor.constraint(equalToConstant: 44),
        ])

        qrView.imageScaling = .scaleProportionallyUpOrDown
        controls = buttons.map { $0 as NSControl } + [timeCheckbox, social, reviewButton] + controlsExtra
        view = root
        setEnabled(false)
    }

    @objc private func showQR(_ sender: NSButton) {
        guard let u = shareURL else { return }
        let vc = NSViewController()
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 250))
        let iv = NSImageView(frame: NSRect(x: 20, y: 40, width: 180, height: 180))
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.image = ShareViewController.qrImage(u.absoluteString)
        let l = NSTextField(labelWithString: "Naskenujte telefónom")
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.alignment = .center
        l.frame = NSRect(x: 0, y: 12, width: 220, height: 18)
        box.addSubview(iv)
        box.addSubview(l)
        vc.view = box
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = vc
        pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    // MARK: Stav

    @objc private func addCommentTapped() { onAddComment?() }

    // MARK: Review link (Vimeo review stránka)

    @objc private func reviewTapped(_ sender: NSButton) {
        guard let r = ref else { NSSound.beep(); return }
        if let link = reviewLink { showReviewMenu(link, from: sender); return }
        // Review link = odkaz na video aj s kódom (napr. vimeo.com/1250016642/6d1f7867e3), presne podľa Vimea.
        sender.isEnabled = false
        VimeoAPI.shared.apiRequest("\(r.apiPath)?fields=link") { [weak self] res in
            guard let self = self else { return }
            sender.isEnabled = true
            var link = r.pageURL
            if case .success(let j) = res, let s = j["link"] as? String, let u = URL(string: s) {
                link = u
            } else if case .failure(let e) = res {
                Diagnostics.shared.log("Review", "link → \(e.localizedDescription)")
            }
            self.reviewLink = link
            self.showReviewMenu(link, from: sender)
        }
    }

    private func showReviewMenu(_ link: URL, from sender: NSButton) {
        let m = NSMenu()
        let header = NSMenuItem(title: link.absoluteString, action: nil, keyEquivalent: "")
        header.isEnabled = false
        m.addItem(header)
        m.addItem(.separator())
        for (title, sel) in [("Kopírovať review link", #selector(reviewCopy)),
                             ("Zdieľať review link…", #selector(reviewShare)),
                             ("Poslať e-mailom", #selector(reviewMail)),
                             ("Otvoriť v prehliadači", #selector(reviewOpen))] {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            m.addItem(i)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func reviewCopy() {
        guard let u = reviewLink else { return }
        copyToPasteboard(u.absoluteString, "✓ Review link skopírovaný")
    }

    @objc private func reviewShare() {
        guard let u = reviewLink else { return }
        NSSharingServicePicker(items: [u]).show(relativeTo: reviewButton.bounds, of: reviewButton, preferredEdge: .minY)
    }

    @objc private func reviewMail() {
        guard let u = reviewLink, let s = NSSharingService(named: .composeEmail) else { return }
        s.subject = "Review: \(videoTitle)"
        s.perform(withItems: ["Prosím o komentáre k videu „\(videoTitle)“ (komentáre sa dajú písať priamo k času vo videu):\n\(u.absoluteString)"])
    }

    @objc private func reviewOpen() {
        guard let u = reviewLink else { return }
        BrowserForwarder.shared.open([u])
    }

    private func reviewError(_ msg: String) {
        let a = NSAlert()
        a.messageText = "Review link nie je dostupný"
        a.informativeText = msg
        if let w = view.window { a.beginSheetModal(for: w, completionHandler: nil) } else { a.runModal() }
    }

    func load(_ ref: VimeoVideoRef, info: VideoInfo?) {
        reviewLink = nil
        _ = view
        self.ref = ref
        self.info = info
        timeCheckbox.state = .off
        lastSecond = -1
        setEnabled(true)
        refreshLink()
    }

    func setInfo(_ info: VideoInfo) { self.info = info }

    func update(time: Double) {
        let sec = Int(time)
        guard sec != lastSecond else { return }
        lastSecond = sec
        timeCheckbox.title = "od \(VimeoLinks.formatTime(time))"
        if timeCheckbox.state == .on { refreshLink() }
    }

    private func setEnabled(_ on: Bool) {
        for c in controls { c.isEnabled = on }
    }

    private var videoTitle: String { info?.title ?? "Video na Vimeo" }

    private var shareURL: URL? {
        guard let r = ref else { return nil }
        return r.pageURL(at: timeCheckbox.state == .on ? currentTime() : nil)
    }

    @objc private func refreshLink() {
        guard let u = shareURL else { return }
        linkField.stringValue = u.absoluteString
    }

    static func qrImage(_ s: String) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(s.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }

    private func flash(_ s: String) {
        feedback.stringValue = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.feedback.stringValue == s { self?.feedback.stringValue = "" }
        }
    }

    private func copyToPasteboard(_ s: String, _ msg: String = "✓ Skopírované") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        flash(msg)
    }

    // MARK: Akcie

    @objc func copyLink() {
        guard let u = shareURL else { NSSound.beep(); return }
        copyToPasteboard(u.absoluteString, "✓ Odkaz skopírovaný")
    }

    @objc private func copyEmbed() {
        guard let r = ref else { return }
        let t = timeCheckbox.state == .on ? currentTime() : nil
        let safeTitle = videoTitle.replacingOccurrences(of: "\"", with: "&quot;")
        let code = "<div style=\"padding:56.25% 0 0 0;position:relative;\"><iframe src=\"\(r.playerURL(at: t).absoluteString)\" style=\"position:absolute;top:0;left:0;width:100%;height:100%;\" frameborder=\"0\" allow=\"autoplay; fullscreen; picture-in-picture\" allowfullscreen title=\"\(safeTitle)\"></iframe></div>"
        copyToPasteboard(code, "✓ Embed kód skopírovaný")
    }

    @objc private func copyMarkdown() {
        guard let u = shareURL else { return }
        let t = videoTitle.replacingOccurrences(of: "]", with: "\\]")
        copyToPasteboard("[\(t)](\(u.absoluteString))", "✓ Markdown skopírovaný")
    }

    @objc private func showPicker(_ sender: NSButton) {
        guard let u = shareURL else { return }
        let picker = NSSharingServicePicker(items: [u])
        picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc private func email() {
        guard let u = shareURL, let s = NSSharingService(named: .composeEmail) else { NSSound.beep(); return }
        s.subject = videoTitle
        s.perform(withItems: ["\(videoTitle)\n\(u.absoluteString)"])
    }

    @objc private func message() {
        guard let u = shareURL, let s = NSSharingService(named: .composeMessage) else { NSSound.beep(); return }
        s.perform(withItems: [u])
    }

    private func openShare(_ base: String, _ params: [String: String]) {
        var c = URLComponents(string: base)!
        c.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        if let u = c.url { BrowserForwarder.shared.open([u]) }
    }

    @objc private func shareX() {
        guard let u = shareURL else { return }
        openShare("https://twitter.com/intent/tweet", ["url": u.absoluteString, "text": videoTitle])
    }

    @objc private func shareFacebook() {
        guard let u = shareURL else { return }
        openShare("https://www.facebook.com/sharer/sharer.php", ["u": u.absoluteString])
    }

    @objc private func shareLinkedIn() {
        guard let u = shareURL else { return }
        openShare("https://www.linkedin.com/sharing/share-offsite/", ["url": u.absoluteString])
    }

    @objc func download(_ sender: NSButton?) {
        guard let r = ref else { NSSound.beep(); return }
        TransferManager.shared.chooseDownload(ref: r, title: info?.title, from: sender ?? view)
    }

    @objc private func openBrowser() {
        guard let u = shareURL else { return }
        onOpenInBrowser?(u)
    }
}
