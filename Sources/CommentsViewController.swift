import AppKit

/// Pravý horný panel – komentáre k videu (čítanie, odpovede, pridávanie).
final class CommentsViewController: NSViewController, NSTextViewDelegate {
    var onSeek: ((Double) -> Void)?
    var onOpenURL: ((URL) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenOnWeb: (() -> Void)?

    private let titleLabel = UI.label("Komentáre", size: 13, weight: .semibold)
    private var scrollView: NSScrollView!
    private var textView: NSTextView!
    private let noTokenBox = NSStackView()
    private let inputField = NSTextField()
    private let sendButton = NSButton(title: "Odoslať", target: nil, action: nil)
    private let replyLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    private let cancelReplyButton = NSButton(title: "Zrušiť odpoveď", target: nil, action: nil)
    private var inputRow: NSStackView!
    private var replyRow: NSStackView!

    private var ref: VimeoVideoRef?
    private var comments: [Comment] = []
    private var byURI: [String: Comment] = [:]
    private var nextPage: String?
    private var total = 0
    private var replyTarget: Comment?
    private var requestID = UUID()

    private lazy var dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    override func loadView() {
        let root = NSView()

        let refresh = UI.iconButton(symbol: "arrow.clockwise", tooltip: "Obnoviť komentáre", target: self, action: #selector(reload))
        let web = UI.iconButton(symbol: "safari", tooltip: "Zobraziť komentáre na vimeo.com", target: self, action: #selector(openOnWeb))
        let header = UI.header("Komentáre", symbol: "bubble.left.and.bubble.right", accessories: [web, refresh],
                               titleLabel: titleLabel)

        let (sv, tv) = UI.scrollingTextView()
        scrollView = sv
        textView = tv
        textView.delegate = self

        // Box zobrazený, keď chýba API token.
        let msg = UI.wrappingLabel("Na zobrazenie alebo pridávanie komentárov k tomuto videu sa prihláste do Vimea.", size: 12)
        let setBtn = UI.button("Prihlásiť sa", symbol: "person.crop.circle", target: self, action: #selector(openSettings))
        let webBtn = UI.button("Zobraziť na vimeo.com", symbol: "safari", target: self, action: #selector(openOnWeb))
        let btnRow = NSStackView(views: [setBtn, webBtn])
        btnRow.orientation = .horizontal
        noTokenBox.orientation = .vertical
        noTokenBox.alignment = .leading
        noTokenBox.spacing = 8
        noTokenBox.addArrangedSubview(msg)
        noTokenBox.addArrangedSubview(btnRow)
        msg.translatesAutoresizingMaskIntoConstraints = false
        msg.widthAnchor.constraint(equalTo: noTokenBox.widthAnchor).isActive = true
        noTokenBox.isHidden = true

        cancelReplyButton.bezelStyle = .inline
        cancelReplyButton.controlSize = .small
        cancelReplyButton.target = self
        cancelReplyButton.action = #selector(cancelReply)
        replyRow = NSStackView(views: [replyLabel, NSView(), cancelReplyButton])
        replyRow.orientation = .horizontal
        replyRow.isHidden = true

        inputField.placeholderString = "Napíšte komentár…"
        inputField.target = self
        inputField.action = #selector(send)
        inputField.lineBreakMode = .byWordWrapping
        inputField.usesSingleLineMode = false
        inputField.cell?.wraps = true
        inputField.cell?.isScrollable = false
        sendButton.bezelStyle = .rounded
        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        inputRow = NSStackView(views: [inputField, sendButton])
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY

        let stack = UI.vstack([header, UI.separator(), noTokenBox, scrollView, replyRow, inputRow], spacing: 6)
        root.addSubview(stack)
        UI.pin(stack, to: root)
        view = root

        NotificationCenter.default.addObserver(self, selector: #selector(tokenChanged),
                                               name: .vimeoTokenChanged, object: nil)
        showMessage("Komentáre sa zobrazia po otvorení videa.")
        updateInputState()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Načítanie

    func load(_ ref: VimeoVideoRef) {
        _ = view
        self.ref = ref
        reload()
    }

    @objc func reload() {
        guard let ref = ref else { return }
        let id = UUID()
        requestID = id
        comments = []
        byURI = [:]
        nextPage = nil
        total = 0
        replyTarget = nil
        replyRow.isHidden = true
        titleLabel.stringValue = "Komentáre"

        noTokenBox.isHidden = true
        updateInputState()
        showMessage("Načítavam komentáre…")
        VimeoAPI.shared.comments(path: VimeoAPI.shared.commentsPath(for: ref)) { [weak self] r in
            guard let self = self, self.requestID == id else { return }
            switch r {
            case .success(let page):
                self.append(page)
            case .failure(let e):
                Diagnostics.shared.log("Komentáre", e.localizedDescription)
                if let api = e as? APIError, case .http(let code, _) = api, code == 401 || code == 403 {
                    self.noTokenBox.isHidden = false
                    self.showMessage("")
                } else {
                    self.showMessage("Komentáre sa nepodarilo načítať.\n\(e.localizedDescription)\n\nAutor videa ich mohol vypnúť.")
                }
            }
        }
    }

    private func append(_ page: CommentPage) {
        for c in page.items { comments.append(c); byURI[c.uri] = c }
        nextPage = page.next
        total = page.total
        titleLabel.stringValue = "Komentáre (\(total))"
        render(keepScroll: true)
    }

    /// Po prihlásení (návrat z prehliadania) skús komentáre znova.
    func reloadIfNeedsLogin() { if !noTokenBox.isHidden { reload() } }

    @objc private func tokenChanged() { reload(); updateInputState() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openOnWeb() { onOpenOnWeb?() }

    private func updateInputState() {
        let enabled = ref != nil
        inputRow?.isHidden = !enabled
    }

    // MARK: Vykreslenie

    private func showMessage(_ s: String) {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        textView.textStorage?.setAttributedString(NSAttributedString(string: s.isEmpty ? "" : "\n" + s, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p]))
    }

    private func render(keepScroll: Bool) {
        let origin = scrollView.contentView.bounds.origin
        let out = NSMutableAttributedString()
        if comments.isEmpty {
            showMessage("Zatiaľ žiadne komentáre.")
            return
        }
        for c in comments {
            appendComment(c, to: out)
            if let reps = c.replies {
                for r in reps { appendComment(r, to: out) }
            } else if c.replyCount > 0 {
                appendLink("▸ Zobraziť odpovede (\(c.replyCount))", link: "c-replies:\(c.uri)", indent: 18, to: out)
            }
            out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
        }
        if nextPage != nil {
            appendLink("Načítať ďalšie komentáre…", link: "c-more", indent: 0, to: out)
        }
        textView.textStorage?.setAttributedString(out)
        if keepScroll {
            scrollView.contentView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func paragraph(indent: CGFloat, spacing: CGFloat = 2) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = indent
        p.headIndent = indent
        p.paragraphSpacing = spacing
        return p
    }

    private func appendComment(_ c: Comment, to out: NSMutableAttributedString) {
        let indent: CGFloat = c.isReply ? 18 : 0
        let head = NSMutableAttributedString()
        var nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                                        .foregroundColor: NSColor.labelColor]
        if let u = c.authorURL { nameAttrs[.link] = u }
        head.append(NSAttributedString(string: c.author, attributes: nameAttrs))
        if let d = c.date {
            head.append(NSAttributedString(string: "  ·  " + dateFormatter.localizedString(for: d, relativeTo: Date()),
                                           attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                        .foregroundColor: NSColor.secondaryLabelColor]))
        }
        head.append(NSAttributedString(string: "\n"))
        head.addAttribute(.paragraphStyle, value: paragraph(indent: indent, spacing: 1), range: NSRange(location: 0, length: head.length))
        out.append(head)

        let body = linkified(c.text)
        body.append(NSAttributedString(string: "\n"))
        body.addAttribute(.paragraphStyle, value: paragraph(indent: indent, spacing: 2), range: NSRange(location: 0, length: body.length))
        out.append(body)

        if !c.isReply {
            appendLink("Odpovedať", link: "c-reply:\(c.uri)", indent: indent, to: out, size: 11)
        }
        out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4)]))
    }

    private func appendLink(_ title: String, link: String, indent: CGFloat, to out: NSMutableAttributedString, size: CGFloat = 12) {
        let s = NSMutableAttributedString(string: title + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: NSColor.controlAccentColor])
        s.addAttribute(.link, value: link, range: NSRange(location: 0, length: (title as NSString).length))
        s.addAttribute(.paragraphStyle, value: paragraph(indent: indent), range: NSRange(location: 0, length: s.length))
        out.append(s)
    }

    /// Text komentára s klikateľnými časmi (1:23) a odkazmi.
    private func linkified(_ text: String) -> NSMutableAttributedString {
        let s = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13),
                                                                     .foregroundColor: NSColor.labelColor])
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for m in detector.matches(in: text, options: [], range: full) {
                if let u = m.url {
                    s.addAttributes([.link: u, .foregroundColor: NSColor.linkColor], range: m.range)
                }
            }
        }
        for m in UI.timestampRegex.matches(in: text, options: [], range: full) {
            if let t = VimeoLinks.parseTime(ns.substring(with: m.range)) {
                s.addAttributes([.link: "seek:\(t)", .foregroundColor: NSColor.controlAccentColor], range: m.range)
            }
        }
        return s
    }

    // MARK: Kliknutia

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let u = link as? URL, u.scheme?.hasPrefix("http") == true {
            onOpenURL?(u)
            return true
        }
        let s: String
        if let u = link as? URL { s = u.absoluteString } else if let str = link as? String { s = str } else { return false }

        if s.hasPrefix("seek:"), let t = Double(s.dropFirst(5)) {
            onSeek?(t)
        } else if s == "c-more" {
            loadMore()
        } else if s.hasPrefix("c-replies:") {
            loadReplies(uri: String(s.dropFirst("c-replies:".count)))
        } else if s.hasPrefix("c-reply:") {
            if let c = byURI[String(s.dropFirst("c-reply:".count))] { startReply(to: c) }
        } else if let u = URL(string: s), u.scheme?.hasPrefix("http") == true {
            onOpenURL?(u)
        } else {
            return false
        }
        return true
    }

    private func loadMore() {
        guard let next = nextPage else { return }
        let id = requestID
        nextPage = nil
        VimeoAPI.shared.comments(path: next) { [weak self] r in
            guard let self = self, self.requestID == id else { return }
            switch r {
            case .success(let page): self.append(page)
            case .failure(let e): self.nextPage = next; self.showError(e)
            }
        }
    }

    private func loadReplies(uri: String) {
        guard let c = byURI[uri] else { return }
        let id = requestID
        VimeoAPI.shared.comments(path: VimeoAPI.shared.repliesPath(for: c)) { [weak self] r in
            guard let self = self, self.requestID == id else { return }
            switch r {
            case .success(let page):
                c.replies = page.items
                self.render(keepScroll: true)
            case .failure(let e):
                self.showError(e)
            }
        }
    }

    private func startReply(to c: Comment) {
        replyTarget = c
        replyLabel.stringValue = "Odpoveď pre: \(c.author)"
        replyRow.isHidden = false
        inputField.placeholderString = "Napíšte odpoveď…"
        view.window?.makeFirstResponder(inputField)
    }

    @objc private func cancelReply() {
        replyTarget = nil
        replyRow.isHidden = true
        inputField.placeholderString = "Napíšte komentár…"
    }

    // MARK: Odoslanie

    @objc private func send() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let ref = ref else { return }
        let target = replyTarget
        let path = target.map { "\($0.uri)/replies" } ?? "\(ref.apiPath)/comments"
        sendButton.isEnabled = false
        inputField.isEnabled = false
        VimeoAPI.shared.postComment(path: path, text: text, isReply: target != nil) { [weak self] r in
            guard let self = self else { return }
            self.sendButton.isEnabled = true
            self.inputField.isEnabled = true
            switch r {
            case .success(let c):
                self.inputField.stringValue = ""
                self.byURI[c.uri] = c
                if let t = target {
                    t.replies = (t.replies ?? []) + [c]
                    t.replyCount += 1
                } else {
                    self.comments.insert(c, at: 0)
                    self.total += 1
                    self.titleLabel.stringValue = "Komentáre (\(self.total))"
                }
                self.cancelReply()
                self.render(keepScroll: target != nil)
            case .failure(let e):
                self.showError(e, hint: "Na pridávanie komentárov musíte byť prihlásený do Vimea (tlačidlo „Prihlásiť sa“).")
            }
        }
    }

    private func showError(_ e: Error, hint: String? = nil) {
        let a = NSAlert()
        a.messageText = "Operácia s komentármi zlyhala"
        a.informativeText = e.localizedDescription + (hint.map { "\n\n" + $0 } ?? "")
        if let w = view.window { a.beginSheetModal(for: w, completionHandler: nil) } else { a.runModal() }
    }
}
