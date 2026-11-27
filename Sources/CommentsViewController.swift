import AppKit

/// Pravý horný panel – komentáre k videu (čítanie, odpovede, pridávanie).
final class CommentsViewController: NSViewController, NSTextViewDelegate, NSTextFieldDelegate {
    var onSeek: ((Double) -> Void)?
    var onOpenURL: ((URL) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenOnWeb: (() -> Void)?
    /// Značky komentárov pre časovú os pod videom.
    var onMarkers: (([CommentTimelineView.Marker]) -> Void)?

    private func publishMarkers() {
        var m: [CommentTimelineView.Marker] = []
        for c in collab {
            if let t = c.timecode { m.append(.init(time: t, text: "\(c.author): \(c.text)", collaborator: true)) }
        }
        var all: [Comment] = []
        for c in comments { all.append(c); all.append(contentsOf: c.replies ?? []) }
        for c in all {
            let ns = c.text as NSString
            if let r = UI.timestampRegex.firstMatch(in: c.text, options: [], range: NSRange(location: 0, length: ns.length)),
               let t = VimeoLinks.parseTime(ns.substring(with: r.range)) {
                m.append(.init(time: t, text: "\(c.author): \(c.text)", collaborator: false))
            }
        }
        onMarkers?(m.sorted { $0.time < $1.time })
    }

    private let titleLabel = UI.label("Komentáre", size: 13, weight: .semibold)
    private var scrollView: NSScrollView!
    private var textView: NSTextView!
    private let noTokenBox = NSStackView()
    private let inputField = NSTextField()
    private let sendButton = NSButton(title: "Pridať komentár", target: nil, action: nil)
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
    /// Komentáre kolaborátorov (poznámky s časom, ako v aplikácii Vimeo).
    private var collab: [Comment] = []
    /// Aktuálny čas videa a pozastavenie (nastavuje hlavné okno).
    var currentTime: () -> Double = { 0 }
    var onPause: (() -> Void)?
    /// Čas, ku ktorému sa pridá práve písaný komentár.
    private var commentTime: Double?
    /// Ako Vimeo ukladá komentáre kolaborátorov (zistené pri načítaní).
    private var collabPath: String?
    private var collabTextKey = "text"
    private var collabTimeKey: String?
    private var collabTimeSample: Any?
    private var probing = false
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
        inputField.delegate = self
        inputField.target = self
        inputField.action = #selector(send)
        inputField.lineBreakMode = .byWordWrapping
        inputField.usesSingleLineMode = false
        inputField.cell?.wraps = true
        inputField.cell?.isScrollable = false
        sendButton.bezelStyle = .rounded
        sendButton.bezelColor = .controlAccentColor
        sendButton.font = .systemFont(ofSize: 13, weight: .semibold)
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
        collab = []
        probing = true
        commentTime = nil
        collabPath = nil
        collabTimeKey = nil
        collabTimeSample = nil
        onMarkers?([])
        titleLabel.stringValue = "Komentáre"

        noTokenBox.isHidden = true
        updateInputState()
        showMessage("Načítavam komentáre…")
        VimeoAPI.shared.comments(path: VimeoAPI.shared.commentsPath(for: ref)) { [weak self] r in
            guard let self = self, self.requestID == id else { return }
            switch r {
            case .success(let page):
                self.append(page)
                self.probeCollaborators(ref, id: id)
            case .failure(let e):
                Diagnostics.shared.log("Komentáre", e.localizedDescription)
                self.probeCollaborators(ref, id: id)
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
        updateTitle()
        render(keepScroll: true)
    }

    private func updateTitle() {
        let n = total + collab.count
        titleLabel.stringValue = n > 0 ? "Komentáre (\(n))" : "Komentáre"
    }

    // MARK: Komentáre kolaborátorov

    /// Zistí, aké druhy komentárov/poznámok Vimeo k videu eviduje, a načíta komentáre kolaborátorov.
    private func probeCollaborators(_ ref: VimeoVideoRef, id: UUID) {
        VimeoAPI.shared.apiRequest("\(ref.apiPath)?fields=metadata.connections,review_page") { [weak self] r in
            guard let self = self, self.requestID == id else { return }
            var candidates: [String] = []
            switch r {
            case .success(let j):
                let conns = ((j["metadata"] as? [String: Any])?["connections"] as? [String: Any]) ?? [:]
                let summary = conns.keys.sorted().map { k -> String in
                    let t = ((conns[k] as? [String: Any])?["total"] as? NSNumber).map { "=\($0)" } ?? ""
                    return k + t
                }.joined(separator: ", ")
                Diagnostics.shared.log("Komentáre", "druhy obsahu videa: \(summary)")
                if let rp = j["review_page"] {
                    Diagnostics.shared.log("Komentáre", "review_page: \(String(describing: rp).prefix(300))")
                }
                for (k, v) in conns where k != "comments" {
                    let lk = k.lowercased()
                    if ["comment", "note", "review", "feedback", "annotation", "timecode"].contains(where: { lk.contains($0) }),
                       let uri = (v as? [String: Any])?["uri"] as? String {
                        candidates.append(uri)
                    }
                }
            case .failure(let e):
                Diagnostics.shared.log("Komentáre", "metadata videa → \(e.localizedDescription)")
            }
            let vid = ref.id
            for c in ["/videos/\(vid)/timecoded_comments", "/videos/\(vid)/notes", "/videos/\(vid)/review/notes",
                      "/videos/\(vid)/collaborator_comments", "/videos/\(vid)/annotations"] where !candidates.contains(c) {
                candidates.append(c)
            }
            self.tryCandidates(candidates, id: id)
        }
    }

    private func tryCandidates(_ list: [String], id: UUID) {
        guard let first = list.first else {
            Diagnostics.shared.log("Komentáre", "komentáre kolaborátorov sa nenašli")
            probing = false
            render(keepScroll: true)
            return
        }
        let sep = first.contains("?") ? "&" : "?"
        VimeoAPI.shared.apiRequest(first + sep + "per_page=100") { [weak self] r in
            guard let self = self, self.requestID == id else { return }
            switch r {
            case .success(let j):
                let data = (j["data"] as? [[String: Any]]) ?? []
                let keys = data.first.map { Array($0.keys).sorted().joined(separator: ",") } ?? ""
                Diagnostics.shared.log("Komentáre", "\(first) → OK, \(data.count) položiek [\(keys)]")
                let items = data.compactMap(CommentsViewController.parseGeneric)
                if !items.isEmpty || data.isEmpty == false {
                    self.learnCollabFormat(path: first, sample: data.first)
                }
                if !items.isEmpty {
                    self.collab = items.sorted { ($0.timecode ?? 0) < ($1.timecode ?? 0) }
                    self.probing = false
                    self.updateTitle()
                    self.render(keepScroll: false)
                    return
                }
            case .failure(let e):
                Diagnostics.shared.log("Komentáre", "\(first) → \(e.localizedDescription)")
            }
            self.tryCandidates(Array(list.dropFirst()), id: id)
        }
    }

    /// Zapamätá si adresu a názvy polí komentárov kolaborátorov, aby sa nové dali pridať v rovnakom formáte.
    private func learnCollabFormat(path: String, sample: [String: Any]?) {
        collabPath = path.components(separatedBy: "?").first
        guard let j = sample else { return }
        for k in ["text", "body", "content", "note", "message", "comment"] where j[k] is String { collabTextKey = k; break }
        for k in ["timecode", "time_code", "video_time", "timestamp", "time", "position", "start_time", "seconds", "start"] {
            if let v = j[k], !(v is NSNull) { collabTimeKey = k; collabTimeSample = v; break }
        }
        Diagnostics.shared.log("Komentáre", "kolaborátori: \(collabPath ?? "-"), text=\(collabTextKey), čas=\(collabTimeKey ?? "-")")
    }

    /// Hodnota času v rovnakom formáte, aký používa Vimeo pri existujúcich komentároch.
    private func timeValue(_ t: Double) -> Any {
        if collabTimeSample is String {
            let s = Int(t)
            if let str = collabTimeSample as? String, str.filter({ $0 == ":" }).count >= 2 {
                return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            }
            return VimeoLinks.formatTime(t)
        }
        if let d = collabTimeSample as? [String: Any] {
            var out: [String: Any] = [:]
            for k in d.keys where ["seconds", "start", "time"].contains(k) { out[k] = t }
            if out.isEmpty { out["seconds"] = t }
            return out
        }
        return t
    }

    // MARK: Pridanie komentára k presnému času

    /// Zastaví video, zapamätá si čas a presunie kurzor do poľa na komentár.
    func beginComment() {
        guard ref != nil else { NSSound.beep(); return }
        cancelReply()
        onPause?()
        commentTime = currentTime()
        updateSendTitle()
        view.window?.makeFirstResponder(inputField)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        if replyTarget == nil && commentTime == nil {
            commentTime = currentTime()
            updateSendTitle()
        }
    }

    private func updateSendTitle() {
        if replyTarget != nil {
            sendButton.title = "Odpovedať"
        } else if let t = commentTime {
            sendButton.title = "Pridať v \(VimeoLinks.formatTime(t))"
            inputField.placeholderString = "Komentár k času \(VimeoLinks.formatTime(t))…"
        } else {
            sendButton.title = "Pridať komentár"
            inputField.placeholderString = "Napíšte komentár…"
        }
    }

    private func sendTimed(_ text: String, at t: Double, ref: VimeoVideoRef) {
        let finish: (Comment) -> Void = { [weak self] c in
            guard let self = self else { return }
            if c.timecode == nil { c.timecode = t }
            self.collab.append(c)
            self.collab.sort { ($0.timecode ?? 0) < ($1.timecode ?? 0) }
            self.inputField.stringValue = ""
            self.commentTime = nil
            self.updateSendTitle()
            self.updateTitle()
            self.render(keepScroll: false)
            self.flashSaved(t)
        }
        let fallback: (String?) -> Void = { [weak self] reason in
            // Bežný komentár s časom na začiatku (Vimeo z neho urobí klikateľný čas).
            let prefixed = "\(VimeoLinks.formatTime(t)) \(text)"
            VimeoAPI.shared.postComment(path: "\(ref.apiPath)/comments", text: prefixed, isReply: false) { r in
                guard let self = self else { return }
                self.setSending(false)
                switch r {
                case .success(let c):
                    c.timecode = t
                    if let why = reason { Diagnostics.shared.log("Komentáre", "uložené ako bežný komentár s časom (\(why))") }
                    self.comments.insert(c, at: 0)
                    self.byURI[c.uri] = c
                    self.total += 1
                    self.inputField.stringValue = ""
                    self.commentTime = nil
                    self.updateSendTitle()
                    self.updateTitle()
                    self.render(keepScroll: false)
                    self.flashSaved(t)
                case .failure(let e):
                    self.showError(e, hint: "Na pridávanie komentárov musíte byť prihlásený do Vimea (tlačidlo „Prihlásiť sa“).")
                }
            }
        }
        setSending(true)
        guard let path = collabPath, let timeKey = collabTimeKey else { fallback("adresa komentárov kolaborátorov nie je známa"); return }
        let body: [String: Any] = [collabTextKey: text, timeKey: timeValue(t)]
        VimeoAPI.shared.apiRequest(path, method: "POST", body: body) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let j):
                self.setSending(false)
                let c = CommentsViewController.parseGeneric(j)
                    ?? Comment(uri: UUID().uuidString, text: text, author: "Ja", authorURL: nil, date: Date(), replyCount: 0, isReply: false)
                finish(c)
            case .failure(let e):
                Diagnostics.shared.log("Komentáre", "POST \(path) → \(e.localizedDescription)")
                fallback(e.localizedDescription)
            }
        }
    }

    private func setSending(_ on: Bool) {
        sendButton.isEnabled = !on
        inputField.isEnabled = !on
    }

    private func flashSaved(_ t: Double) {
        let old = titleLabel.stringValue
        titleLabel.stringValue = "✓ Komentár pridaný v \(VimeoLinks.formatTime(t))"
        titleLabel.textColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self = self else { return }
            self.titleLabel.textColor = .labelColor
            if self.titleLabel.stringValue.hasPrefix("✓") { self.titleLabel.stringValue = old; self.updateTitle() }
        }
    }

    /// Všeobecné čítanie položky komentára/poznámky (názvy polí sa v API líšia).
    static func parseGeneric(_ j: [String: Any]) -> Comment? {
        var text: String?
        for k in ["text", "body", "content", "note", "message", "comment"] {
            if let s = j[k] as? String, !s.isEmpty { text = s; break }
        }
        guard let t = text else { return nil }
        var user: [String: Any]?
        for k in ["user", "author", "owner", "created_by", "creator"] {
            if let u = j[k] as? [String: Any] { user = u; break }
        }
        let name = (user?["name"] as? String) ?? (user?["display_name"] as? String) ?? (j["author_name"] as? String) ?? "Kolaborátor"
        var time: Double?
        for k in ["timecode", "time_code", "video_time", "timestamp", "time", "position", "start_time", "seconds", "start"] {
            if let n = j[k] as? NSNumber, n.doubleValue >= 0, n.doubleValue < 100_000 { time = n.doubleValue; break }
            if let s = j[k] as? String, let v = VimeoLinks.parseTime(s), v < 100_000 { time = v; break }
            if let d = j[k] as? [String: Any], let n = (d["seconds"] ?? d["start"] ?? d["time"]) as? NSNumber { time = n.doubleValue; break }
        }
        var date: Date?
        for k in ["created_on", "created_time", "created_at", "modified_time"] {
            if let s = j[k] as? String, let d = ISO8601DateFormatter().date(from: s) { date = d; break }
        }
        let resolved = (j["is_resolved"] as? Bool) ?? (j["resolved"] as? Bool) ?? ((j["status"] as? String)?.lowercased() == "resolved")
        let c = Comment(uri: j["uri"] as? String ?? UUID().uuidString, text: t, author: name,
                        authorURL: (user?["link"] as? String).flatMap { URL(string: $0) }, date: date,
                        replyCount: 0, isReply: false)
        c.timecode = time
        c.resolved = resolved
        return c
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
        publishMarkers()
        let origin = scrollView.contentView.bounds.origin
        let out = NSMutableAttributedString()
        if comments.isEmpty && collab.isEmpty {
            showMessage(probing ? "Hľadám komentáre kolaborátorov…" : "Zatiaľ žiadne komentáre.")
            return
        }
        if !collab.isEmpty {
            appendSection("KOLABORÁTORI (\(collab.count))", to: out)
            for c in collab { appendComment(c, to: out, allowReply: false) }
            if !comments.isEmpty { appendSection("VEREJNÉ KOMENTÁRE (\(total))", to: out) }
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

    private func appendSection(_ title: String, to out: NSMutableAttributedString) {
        out.append(NSAttributedString(string: title + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph(indent: 0, spacing: 6)]))
    }

    private func appendComment(_ c: Comment, to out: NSMutableAttributedString, allowReply: Bool = true) {
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
        if c.resolved {
            head.append(NSAttributedString(string: "  ✓ vyriešené", attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                                              .foregroundColor: NSColor.systemGreen]))
        }
        head.append(NSAttributedString(string: "\n"))
        head.addAttribute(.paragraphStyle, value: paragraph(indent: indent, spacing: 1), range: NSRange(location: 0, length: head.length))
        out.append(head)

        let body = linkified(c.timecode.map { VimeoLinks.formatTime($0) + "  " + c.text } ?? c.text)
        body.append(NSAttributedString(string: "\n"))
        body.addAttribute(.paragraphStyle, value: paragraph(indent: indent, spacing: 2), range: NSRange(location: 0, length: body.length))
        out.append(body)

        appendActions(c, indent: indent, allowReply: !c.isReply && allowReply, to: out)
        out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4)]))
    }

    /// Riadok s akciami pod komentárom: Odpovedať · Upraviť · Zmazať
    private func appendActions(_ c: Comment, indent: CGFloat, allowReply: Bool, to out: NSMutableAttributedString) {
        let line = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        func add(_ title: String, _ link: String, _ color: NSColor) {
            if line.length > 0 {
                line.append(NSAttributedString(string: "   ·   ", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            line.append(NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: color, .link: link]))
        }
        if allowReply { add("Odpovedať", "c-reply:\(c.uri)", .controlAccentColor) }
        if c.uri.hasPrefix("/") {
            add("Upraviť", "c-edit:\(c.uri)", .secondaryLabelColor)
            add("Zmazať", "c-del:\(c.uri)", .systemRed)
        }
        guard line.length > 0 else { return }
        line.append(NSAttributedString(string: "\n"))
        line.addAttribute(.paragraphStyle, value: paragraph(indent: indent), range: NSRange(location: 0, length: line.length))
        out.append(line)
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
        } else if s.hasPrefix("c-edit:") {
            if let c = findComment(String(s.dropFirst("c-edit:".count))) { editComment(c) }
        } else if s.hasPrefix("c-del:") {
            if let c = findComment(String(s.dropFirst("c-del:".count))) { deleteComment(c) }
        } else if s.hasPrefix("c-reply:") {
            if let c = byURI[String(s.dropFirst("c-reply:".count))] { startReply(to: c) }
        } else if let u = URL(string: s), u.scheme?.hasPrefix("http") == true {
            onOpenURL?(u)
        } else {
            return false
        }
        return true
    }

    // MARK: Úprava a mazanie

    private func findComment(_ uri: String) -> Comment? {
        if let c = byURI[uri] { return c }
        if let c = collab.first(where: { $0.uri == uri }) { return c }
        for c in comments { if let r = c.replies?.first(where: { $0.uri == uri }) { return r } }
        return nil
    }

    private func editComment(_ c: Comment) {
        guard let w = view.window else { return }
        let a = NSAlert()
        a.messageText = "Upraviť komentár"
        a.informativeText = c.timecode.map { "Čas vo videu: \(VimeoLinks.formatTime($0))" } ?? ""
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 110))
        tv.string = c.text
        tv.font = .systemFont(ofSize: 13)
        tv.isRichText = false
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 110))
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.borderType = .bezelBorder
        a.accessoryView = sv
        a.addButton(withTitle: "Uložiť")
        a.addButton(withTitle: "Zrušiť")
        a.window.initialFirstResponder = tv
        a.beginSheetModal(for: w) { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let self = self else { return }
            let newText = tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newText.isEmpty, newText != c.text else { return }
            let key = self.collab.contains(where: { $0 === c }) ? self.collabTextKey : "text"
            VimeoAPI.shared.apiRequest(c.uri, method: "PATCH", body: [key: newText]) { r in
                switch r {
                case .success:
                    c.text = newText
                    self.render(keepScroll: true)
                case .failure(let e):
                    Diagnostics.shared.log("Komentáre", "PATCH \(c.uri) → \(e.localizedDescription)")
                    self.showError(e, hint: "Upraviť môžete len vlastné komentáre (alebo všetky, ak ste vlastníkom videa).")
                }
            }
        }
    }

    private func deleteComment(_ c: Comment) {
        guard let w = view.window else { return }
        let a = NSAlert()
        a.messageText = "Zmazať komentár?"
        a.informativeText = "„\(c.text.prefix(140))“\n\nTúto akciu nie je možné vrátiť."
        a.alertStyle = .warning
        a.addButton(withTitle: "Zmazať")
        a.addButton(withTitle: "Zrušiť")
        if #available(macOS 11.0, *) { a.buttons.first?.hasDestructiveAction = true }
        a.beginSheetModal(for: w) { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let self = self else { return }
            VimeoAPI.shared.apiRequest(c.uri, method: "DELETE") { r in
                switch r {
                case .success:
                    if let i = self.collab.firstIndex(where: { $0 === c }) {
                        self.collab.remove(at: i)
                    } else if let i = self.comments.firstIndex(where: { $0 === c }) {
                        self.comments.remove(at: i)
                        self.total = max(0, self.total - 1)
                    } else {
                        for p in self.comments {
                            if let i = p.replies?.firstIndex(where: { $0 === c }) {
                                p.replies?.remove(at: i)
                                p.replyCount = max(0, p.replyCount - 1)
                            }
                        }
                    }
                    self.byURI.removeValue(forKey: c.uri)
                    self.updateTitle()
                    self.render(keepScroll: true)
                case .failure(let e):
                    Diagnostics.shared.log("Komentáre", "DELETE \(c.uri) → \(e.localizedDescription)")
                    self.showError(e, hint: "Zmazať môžete len vlastné komentáre (alebo všetky, ak ste vlastníkom videa).")
                }
            }
        }
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
        updateSendTitle()
        inputField.placeholderString = "Napíšte odpoveď…"
        view.window?.makeFirstResponder(inputField)
    }

    @objc private func cancelReply() {
        replyTarget = nil
        defer { updateSendTitle() }
        replyRow.isHidden = true
        inputField.placeholderString = "Napíšte komentár…"
    }

    // MARK: Odoslanie

    @objc private func send() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let ref = ref else { return }
        if replyTarget == nil {
            sendTimed(text, at: commentTime ?? currentTime(), ref: ref)
            return
        }
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
