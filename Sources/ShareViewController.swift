import AppKit
import CoreImage

/// Pravý dolný panel – možnosti zdieľania.
final class ShareViewController: NSViewController {
    var currentTime: () -> Double = { 0 }
    var onOpenInBrowser: ((URL) -> Void)?

    private var ref: VimeoVideoRef?
    private var info: VideoInfo?
    private let linkField = NSTextField()
    private let timeCheckbox = NSButton(checkboxWithTitle: "Začať od 0:00", target: nil, action: nil)
    private let qrView = NSImageView()
    private let feedback = UI.label("", size: 11, color: .systemGreen)
    private var controls: [NSControl] = []
    private var lastSecond = -1
    private var shareButton: NSButton!

    override func loadView() {
        let root = NSView()
        let header = UI.header("Zdieľanie", symbol: "square.and.arrow.up", accessories: [feedback])

        linkField.isEditable = false
        linkField.isSelectable = true
        linkField.font = .systemFont(ofSize: 12)
        linkField.lineBreakMode = .byTruncatingMiddle
        linkField.cell?.usesSingleLineMode = true
        linkField.placeholderString = "Odkaz na video"

        timeCheckbox.target = self
        timeCheckbox.action = #selector(refreshLink)
        timeCheckbox.controlSize = .small
        timeCheckbox.font = .systemFont(ofSize: 11)

        let copyLinkBtn = UI.button("Kopírovať odkaz", symbol: "link", target: self, action: #selector(copyLink))
        let copyEmbedBtn = UI.button("Embed kód", symbol: "chevron.left.slash.chevron.right", target: self, action: #selector(copyEmbed))
        let copyMd = UI.button("Markdown", symbol: "doc.on.doc", target: self, action: #selector(copyMarkdown))
        shareButton = UI.button("Zdieľať…", symbol: "square.and.arrow.up", target: self, action: #selector(showPicker(_:)))
        let mail = UI.button("E-mail", symbol: "envelope", target: self, action: #selector(email))
        let messages = UI.button("Správy", symbol: "message", target: self, action: #selector(message))
        let x = UI.button("X / Twitter", target: self, action: #selector(shareX))
        let fb = UI.button("Facebook", target: self, action: #selector(shareFacebook))
        let li = UI.button("LinkedIn", target: self, action: #selector(shareLinkedIn))
        let browser = UI.button("V prehliadači", symbol: "safari", target: self, action: #selector(openBrowser))

        let buttons: [NSButton] = [copyLinkBtn, copyEmbedBtn, copyMd, shareButton!, mail, messages, x, fb, li, browser]
        for b in buttons { b.controlSize = .small; b.font = .systemFont(ofSize: 11) }
        let grid = NSGridView(views: stride(from: 0, to: buttons.count, by: 2).map { i -> [NSView] in
            let second: NSView = i + 1 < buttons.count ? buttons[i + 1] : NSGridCell.emptyContentView
            return [buttons[i], second]
        })
        grid.rowSpacing = 4
        grid.columnSpacing = 6
        for i in 0..<grid.numberOfColumns { grid.column(at: i).xPlacement = .fill }

        qrView.imageScaling = .scaleProportionallyUpOrDown
        qrView.translatesAutoresizingMaskIntoConstraints = false
        qrView.widthAnchor.constraint(equalToConstant: 96).isActive = true
        qrView.heightAnchor.constraint(equalToConstant: 96).isActive = true
        qrView.toolTip = "QR kód – naskenujte telefónom"
        let qrLabel = UI.wrappingLabel("Naskenujte QR kód telefónom a pozerajte ďalej na mobile.", size: 11)
        let qrRow = NSStackView(views: [qrView, qrLabel])
        qrRow.orientation = .horizontal
        qrRow.alignment = .centerY
        qrRow.spacing = 10

        let stack = UI.vstack([header, UI.separator(), linkField, timeCheckbox, grid, qrRow], spacing: 7)
        // Grid a QR riadok nech sa neroztiahnu na výšku.
        grid.setContentHuggingPriority(.required, for: .vertical)
        let filler = NSView()
        filler.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        stack.addArrangedSubview(filler)
        root.addSubview(stack)
        UI.pin(stack, to: root)

        controls = buttons.map { $0 as NSControl } + [timeCheckbox]
        view = root
        setEnabled(false)
    }

    // MARK: Stav

    func load(_ ref: VimeoVideoRef, info: VideoInfo?) {
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
        timeCheckbox.title = "Začať od \(VimeoLinks.formatTime(time))"
        if timeCheckbox.state == .on && sec % 2 == 0 { refreshLink() }
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
        qrView.image = ShareViewController.qrImage(u.absoluteString)
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

    @objc private func openBrowser() {
        guard let u = shareURL else { return }
        onOpenInBrowser?(u)
    }
}
