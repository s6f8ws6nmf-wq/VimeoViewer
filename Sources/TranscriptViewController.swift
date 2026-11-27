import AppKit

/// Ľavý panel – prepis (titulky) videa, synchronizovaný s prehrávaním.
final class TranscriptViewController: NSViewController, NSTextViewDelegate, NSSearchFieldDelegate {
    var onSeek: ((Double) -> Void)?

    private let trackPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let searchField = NSSearchField()
    private let followCheckbox = NSButton(checkboxWithTitle: "Sledovať prehrávanie", target: nil, action: nil)
    private let statusLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    private var scrollView: NSScrollView!
    private var textView: NSTextView!

    private var ref: VimeoVideoRef?
    private var tracks: [TextTrack] = []
    private var cues: [Cue] = []
    private var displayedRanges: [Int: NSRange] = [:]
    private var highlighted: Int?
    private var requestID = UUID()

    override func loadView() {
        let root = NSView()
        let actions = NSPopUpButton(frame: .zero, pullsDown: true)
        actions.isBordered = false
        actions.setContentHuggingPriority(.required, for: .horizontal)
        let menu = NSMenu()
        let icon = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        icon.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Akcie")
        menu.addItem(icon)
        menu.addItem(withTitle: "Kopírovať prepis s časmi", action: #selector(copyWithTimes), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Kopírovať iba text", action: #selector(copyPlain), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Uložiť prepis ako .txt…", action: #selector(saveTranscript), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Uložiť titulky ako .srt…", action: #selector(saveSRT), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Nahrať titulky na Vimeo (.srt, .vtt…)…", action: #selector(uploadSubtitles), keyEquivalent: "").target = self
        actions.menu = menu
        actions.toolTip = "Kopírovať alebo uložiť prepis"

        let header = UI.header("Prepis", symbol: "text.alignleft", accessories: [actions])

        trackPopup.target = self
        trackPopup.action = #selector(trackChanged)
        trackPopup.controlSize = .small
        trackPopup.font = .systemFont(ofSize: 11)
        trackPopup.isEnabled = false

        searchField.placeholderString = "Hľadať v prepise"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)

        followCheckbox.state = .on
        followCheckbox.controlSize = .small
        followCheckbox.font = .systemFont(ofSize: 11)

        let (sv, tv) = UI.scrollingTextView()
        scrollView = sv
        textView = tv
        textView.delegate = self

        let bottom = NSStackView(views: [followCheckbox, NSView(), statusLabel])
        bottom.orientation = .horizontal

        langPopup.target = self
        langPopup.action = #selector(languageChanged)
        langPopup.controlSize = .small
        langPopup.font = .systemFont(ofSize: 11)
        langPopup.isEnabled = false
        langPopup.toolTip = "Zobraziť prepis v origináli alebo v preklade"
        let langLabel = UI.label("Preklad prepisu do jazyka:", size: 11, color: .secondaryLabelColor)
        langLabel.setContentHuggingPriority(.required, for: .horizontal)
        let langRow = NSStackView(views: [langLabel, langPopup])
        langRow.orientation = .horizontal
        langRow.spacing = 6

        let stack = UI.vstack([header, trackPopup, langRow, searchField, UI.separator(), scrollView, bottom], spacing: 6)
        root.addSubview(stack)
        UI.pin(stack, to: root)
        root.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        view = root
        showMessage("Prepis sa zobrazí po otvorení videa.")
    }

    // MARK: Načítanie

    /// Požiada prehrávač o stiahnutie titulkov (nastavuje hlavné okno).
    var requestPlayerTrack: ((TextTrack) -> Void)?
    /// Požiada prehrávač o zoznam titulkov cez Player API.
    var requestPlayerTrackList: (() -> Void)?
    /// Požiada prehrávač o zachytenie titulkov daného jazyka.
    var requestCapture: ((TextTrack) -> Void)?
    private var capturingTrack = false
    private var triedPlayerAPI = false
    private var waitingForPlayer = false
    private var pendingPlayerURL: String?

    func load(_ ref: VimeoVideoRef) {
        _ = view
        self.ref = ref
        requestID = UUID()
        tracks = []
        cues = []
        originalCues = []
        translations = [:]
        translateID = UUID()
        langPopup.removeAllItems()
        langPopup.isEnabled = false
        pendingPlayerURL = nil
        capturingTrack = false
        triedPlayerAPI = false
        trackPopup.removeAllItems()
        trackPopup.isEnabled = false
        statusLabel.stringValue = ""
        showMessage("Načítavam prepis…")
        waitingForPlayer = true
        let id = requestID
        // Ak prehrávač titulky nepošle, skúsime Vimeo API.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self = self, self.requestID == id, self.waitingForPlayer else { return }
            self.startPlayerAPI(reason: "Prehrávač neposlal titulky")
        }
    }

    /// Zoznam titulkov z prehrávača.
    func playerTracks(_ list: [TextTrack]?, error: String?) {
        guard ref != nil, waitingForPlayer else { return }
        waitingForPlayer = false
        if let l = list, !l.isEmpty {
            setTracks(l)
        } else {
            startPlayerAPI(reason: error)
        }
    }

    /// Obsah VTT súboru stiahnutý prehrávačom.
    func playerVTT(url: String, text: String?, error: String?) {
        guard let p = pendingPlayerURL, p == url else { return }
        pendingPlayerURL = nil
        if let t = text, !VTT.parse(t).isEmpty {
            showCues(VTT.parse(t))
        } else {
            startPlayerAPI(reason: error)
        }
    }

    // MARK: Zachytenie cez prehrávač (rovnako ako tlačidlo CC / Transcript vo Vimeo)

    private func startPlayerAPI(reason: String?) {
        guard ref != nil, !triedPlayerAPI else {
            fallbackToAPI(playerError: reason)
            return
        }
        triedPlayerAPI = true
        waitingForPlayer = false
        showMessage("Načítavam prepis z prehrávača…")
        requestPlayerTrackList?()
    }

    /// Zoznam titulkov z Player API.
    func playerAPITracks(_ list: [TextTrack], error: String?) {
        guard ref != nil, triedPlayerAPI, cues.isEmpty, !capturingTrack else { return }
        if list.isEmpty {
            fallbackToAPI(playerError: error ?? "Video nemá titulky.")
        } else {
            setTracks(list)
        }
    }

    /// Prehrávač zachytil celý prepis.
    func playerCaptured(_ c: [Cue]) {
        guard ref != nil else { return }
        // Prijmi aj vtedy, keď si titulky zapol používateľ sám v prehrávači a prepis ešte nemáme.
        guard capturingTrack || cues.isEmpty else { return }
        capturingTrack = false
        waitingForPlayer = false
        showCues(c)
    }

    func playerCaptureFailed(_ message: String) {
        Diagnostics.shared.log("Prepis", "zachytenie z prehrávača: \(message)")
        guard capturingTrack else { return }
        capturingTrack = false
        fallbackToAPI(playerError: message)
    }

    private func fallbackToAPI(playerError: String?) {
        guard let ref = ref else { return }
        waitingForPlayer = false
        let id = requestID
        VimeoAPI.shared.textTracks(ref) { [weak self] r in
            guard let self = self, self.requestID == id, self.cues.isEmpty, !self.capturingTrack else { return }
            switch r {
            case .success(let tr):
                if tr.isEmpty {
                    self.showMessage("Toto video nemá titulky ani automatický prepis.")
                } else {
                    self.setTracks(tr)
                }
            case .failure:
                if playerError == nil {
                    self.showMessage("Toto video nemá titulky ani automatický prepis.")
                } else {
                    self.showMessage("Prepis nie je k dispozícii.\n\(playerError ?? "")")
                }
            }
        }
    }

    private func setTracks(_ tr: [TextTrack]) {
        tracks = tr
        trackPopup.removeAllItems()
        trackPopup.addItems(withTitles: tr.map { TranscriptViewController.displayName($0) })
        trackPopup.isEnabled = tr.count > 1
        trackPopup.toolTip = tr.count > 1 ? "Vyberte jazyk prepisu" : "Video má na Vimeu iba túto stopu titulkov"
        let idx = preferredTrackIndex(tr)
        trackPopup.selectItem(at: idx)
        loadTrack(idx)
    }

    /// Vimeo pomenuje automatický prepis podľa jazyka nastaveného vlastníkom videa,
    /// nie podľa skutočnej reči – preto ho označíme zrozumiteľne.
    static func displayName(_ t: TextTrack) -> String {
        let l = t.label.lowercased()
        if l.contains("auto") || t.lang.lowercased().contains("autogen") || t.lang.lowercased().contains("x-") {
            let base = t.label.replacingOccurrences(of: "(auto-generated)", with: "")
                .replacingOccurrences(of: "(auto generated)", with: "")
                .trimmingCharacters(in: .whitespaces)
            return "Automatický prepis (Vimeo ho označuje ako „\(base)“)"
        }
        return t.label
    }

    private func preferredTrackIndex(_ tr: [TextTrack]) -> Int {
        let langs = Locale.preferredLanguages.map { String($0.prefix(2)).lowercased() } + ["sk", "cs", "en"]
        for l in langs {
            // Uprednostni ručne vytvorené titulky pred automatickými.
            if let i = tr.firstIndex(where: { $0.lang.lowercased().hasPrefix(l) && !$0.lang.contains("autogen") }) { return i }
            if let i = tr.firstIndex(where: { $0.lang.lowercased().hasPrefix(l) }) { return i }
        }
        return 0
    }

    private func loadTrack(_ index: Int) {
        guard index >= 0, index < tracks.count else { return }
        let track = tracks[index]
        showMessage("Načítavam prepis…")
        if track.captureLang != nil {
            capturingTrack = true
            requestCapture?(track)
            return
        }
        if track.viaPlayer {
            pendingPlayerURL = track.url.absoluteString
            requestPlayerTrack?(track)
            return
        }
        let id = UUID()
        requestID = id
        VimeoAPI.shared.cues(for: track) { [weak self] r in
            guard let self = self, self.requestID == id else { return }
            switch r {
            case .success(let c): self.showCues(c)
            case .failure(let e): self.showMessage("Prepis sa nepodarilo načítať.\n\(e.localizedDescription)")
            }
        }
    }

    // MARK: Jazyk prepisu (originál / preklad)

    private let langPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var originalCues: [Cue] = []
    private var originalLang: String?
    private var translations: [String: [Cue]] = [:]
    private var translateID = UUID()
    private let targetKey = "transcriptTargetLang"   // "" = originál

    /// Nový prepis (originál) – rozpozná jazyk a podľa nastavenia ho prípadne preloží.
    private func showCues(_ c: [Cue]) {
        originalCues = c
        translations = [:]
        translateID = UUID()
        if c.isEmpty { cues = []; showMessage("Prepis je prázdny."); langPopup.isEnabled = false; return }
        originalLang = Translator.detect(c.map { $0.text })
        buildLanguageMenu()
        let target = UserDefaults.standard.string(forKey: targetKey) ?? "sk"
        if !target.isEmpty, let o = originalLang, !o.hasPrefix(target) {
            selectLanguage(target)
            translate(to: target)
        } else {
            selectLanguage("")
            display(c, note: nil)
        }
    }

    private func display(_ c: [Cue], note: String?) {
        cues = c
        statusLabel.stringValue = note ?? "\(c.count) úsekov"
        render()
    }

    private func buildLanguageMenu() {
        langPopup.removeAllItems()
        let orig = originalLang.map { "Originál – \(Translator.localName($0))" } ?? "Originál"
        langPopup.addItem(withTitle: orig)
        langPopup.lastItem?.representedObject = ""
        langPopup.menu?.addItem(.separator())
        for l in Translator.languages where !(originalLang ?? "").hasPrefix(l.code) {
            langPopup.addItem(withTitle: "Preklad: \(l.name)")
            langPopup.lastItem?.representedObject = l.code
        }
        langPopup.isEnabled = true
    }

    private func selectLanguage(_ code: String) {
        if let i = langPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == code }) {
            langPopup.selectItem(at: i)
        }
    }

    @objc private func languageChanged() {
        let code = (langPopup.selectedItem?.representedObject as? String) ?? ""
        UserDefaults.standard.set(code, forKey: targetKey)
        if code.isEmpty {
            translateID = UUID()
            display(originalCues, note: nil)
        } else {
            translate(to: code)
        }
    }

    private func translate(to code: String) {
        if let t = translations[code] {
            display(t, note: "Preklad (\(Translator.engineName))")
            return
        }
        let id = UUID()
        translateID = id
        let source = originalCues
        statusLabel.stringValue = "Prekladám… 0 %"
        if cues.isEmpty { display(source, note: "Prekladám… 0 %") }
        Translator.translate(source.map { $0.text }, to: code, progress: { [weak self] p in
            guard let self = self, self.translateID == id else { return }
            self.statusLabel.stringValue = "Prekladám… \(Int(p * 100)) %"
        }, completion: { [weak self] r in
            guard let self = self, self.translateID == id else { return }
            switch r {
            case .success(let texts):
                let translated = zip(source, texts).map { Cue(start: $0.start, end: $0.end, text: $1) }
                self.translations[code] = translated
                self.display(translated, note: "Preklad (\(Translator.engineName))")
            case .failure(let e):
                Diagnostics.shared.log("Preklad", e.localizedDescription)
                self.statusLabel.stringValue = "Preklad zlyhal"
                self.selectLanguage("")
                self.display(source, note: "Preklad zlyhal – zobrazený originál")
            }
        })
    }

    @objc private func trackChanged() { loadTrack(trackPopup.indexOfSelectedItem) }
    @objc private func searchChanged() { if !cues.isEmpty { render() } }

    func focusSearch() { view.window?.makeFirstResponder(searchField) }

    // MARK: Vykreslenie

    private func showMessage(_ s: String) {
        if s.contains("nepodarilo") || s.contains("nie je k dispozícii") { Diagnostics.shared.log("Prepis", s.replacingOccurrences(of: "\n", with: " ")) }
        displayedRanges = [:]
        highlighted = nil
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        textView.textStorage?.setAttributedString(NSAttributedString(string: "\n" + s, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p]))
    }

    private func render() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        let out = NSMutableAttributedString()
        displayedRanges = [:]
        highlighted = nil

        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 7
        para.lineSpacing = 1.5
        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let textFont = NSFont.systemFont(ofSize: 13)

        for (i, cue) in cues.enumerated() {
            if !query.isEmpty && cue.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil { continue }
            let start = out.length
            let link = "seek:\(cue.start)"
            out.append(NSAttributedString(string: VimeoLinks.formatTime(cue.start), attributes: [
                .font: timeFont, .foregroundColor: NSColor.controlAccentColor, .link: link]))
            out.append(NSAttributedString(string: "  ", attributes: [.font: textFont]))
            let body = NSMutableAttributedString(string: cue.text, attributes: [
                .font: textFont, .foregroundColor: NSColor.labelColor, .link: link])
            if !query.isEmpty {
                var searchRange = cue.text.startIndex..<cue.text.endIndex
                while let r = cue.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
                    body.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.45),
                                      range: NSRange(r, in: cue.text))
                    searchRange = r.upperBound..<cue.text.endIndex
                }
            }
            out.append(body)
            out.append(NSAttributedString(string: "\n", attributes: [.font: textFont]))
            let range = NSRange(location: start, length: out.length - start)
            out.addAttribute(.paragraphStyle, value: para, range: range)
            displayedRanges[i] = NSRange(location: start, length: max(0, out.length - start - 1))
        }
        if out.length == 0 {
            showMessage("Nič sa nenašlo.")
            return
        }
        textView.textStorage?.setAttributedString(out)
        textView.scroll(.zero)
    }

    // MARK: Synchronizácia s prehrávaním

    func update(time: Double) {
        guard !cues.isEmpty else { return }
        var lo = 0, hi = cues.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= time + 0.15 { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        let idx: Int? = found >= 0 ? found : nil
        guard idx != highlighted else { return }
        guard let lm = textView.layoutManager else { return }
        if let old = highlighted, let r = displayedRanges[old] {
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r)
        }
        highlighted = idx
        guard let i = idx, let r = displayedRanges[i] else { return }
        lm.addTemporaryAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.22),
                                 forCharacterRange: r)
        if followCheckbox.state == .on { scrollToRange(r) }
    }

    private func scrollToRange(_ range: NSRange) {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        rect.origin.y += textView.textContainerOrigin.y
        let visible = scrollView.contentView.bounds
        if rect.minY < visible.minY + 20 || rect.maxY > visible.maxY - 20 {
            let maxY = max(0, textView.bounds.height - visible.height)
            let target = min(maxY, max(0, rect.midY - visible.height / 3))
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: target))
            }
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    // MARK: Klik na čas / text

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let s: String
        if let u = link as? URL { s = u.absoluteString } else if let str = link as? String { s = str } else { return false }
        if s.hasPrefix("seek:"), let t = Double(s.dropFirst(5)) {
            onSeek?(t)
            return true
        }
        return false
    }

    // MARK: Export

    private func transcriptText(withTimes: Bool) -> String {
        if withTimes {
            return cues.map { "[\(VimeoLinks.formatTime($0.start))] \($0.text)" }.joined(separator: "\n")
        }
        return cues.map { $0.text }.joined(separator: " ")
    }

    @objc private func copyWithTimes() { copy(transcriptText(withTimes: true)) }
    @objc private func copyPlain() { copy(transcriptText(withTimes: false)) }

    private func copy(_ s: String) {
        guard !cues.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: Nahratie vlastných titulkov na Vimeo

    private static let subtitleTypes = ["srt", "vtt", "webvtt", "dfxp", "ttml", "xml", "scc", "sami", "smi"]
    private static let languages: [(String, String)] = [
        ("Slovenčina", "sk"), ("Čeština", "cs"), ("English", "en"), ("Deutsch", "de"), ("Magyar", "hu"),
        ("Polski", "pl"), ("Українська", "uk"), ("Русский", "ru"), ("Español", "es"), ("Français", "fr"),
        ("Italiano", "it"), ("Português", "pt"), ("Hrvatski", "hr"), ("Srpski", "sr"), ("Slovenščina", "sl"),
    ]

    @objc func uploadSubtitles() {
        guard let ref = ref, let window = view.window else { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = TranscriptViewController.subtitleTypes
        panel.message = "Vyberte súbor s titulkami (.srt, .vtt, .dfxp/.ttml, .scc, .sami)"
        panel.prompt = "Pokračovať"
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let file = panel.url, let self = self else { return }
            DispatchQueue.main.async { self.askSubtitleOptions(file: file, ref: ref) }
        }
    }

    private func askSubtitleOptions(file: URL, ref: VimeoVideoRef) {
        guard let window = view.window else { return }
        let langPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        langPopup.addItems(withTitles: TranscriptViewController.languages.map { $0.0 })
        let kindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        kindPopup.addItems(withTitles: ["Titulky (subtitles)", "Skryté titulky pre nepočujúcich (captions)"])
        let nameField = NSTextField(string: file.deletingPathExtension().lastPathComponent)
        let grid = NSGridView(views: [
            [UI.label("Jazyk:"), langPopup],
            [UI.label("Typ:"), kindPopup],
            [UI.label("Názov:"), nameField],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        nameField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        grid.frame = NSRect(x: 0, y: 0, width: 360, height: 90)

        let a = NSAlert()
        a.messageText = "Nahrať titulky na Vimeo"
        a.informativeText = "Súbor: \(file.lastPathComponent)\nTitulky sa pridajú k videu a dajú sa zapnúť cez CC v prehrávači."
        a.accessoryView = grid
        a.addButton(withTitle: "Nahrať")
        a.addButton(withTitle: "Zrušiť")
        a.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let self = self else { return }
            let lang = TranscriptViewController.languages[max(0, langPopup.indexOfSelectedItem)].1
            let kind = kindPopup.indexOfSelectedItem == 1 ? "captions" : "subtitles"
            let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            self.upload(file: file, ref: ref, language: lang, kind: kind, name: name.isEmpty ? file.lastPathComponent : name)
        }
    }

    private func upload(file: URL, ref: VimeoVideoRef, language: String, kind: String, name: String) {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else {
            uploadAlert("Súbor sa nedá prečítať.", ok: false)
            return
        }
        statusLabel.stringValue = "Nahrávam titulky…"
        // Hneď ukáž titulky v paneli (SRT aj VTT vie aplikácia prečítať sama).
        let text = String(decoding: data, as: UTF8.self)
        let local = VTT.parse(text)
        if !local.isEmpty { showCues(local) }

        let body: [String: Any] = ["type": kind, "language": language, "name": name]
        VimeoAPI.shared.apiRequest("\(ref.apiPath)/texttracks", method: "POST", body: body) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let j):
                guard let link = j["link"] as? String, let url = URL(string: link), let uri = j["uri"] as? String else {
                    self.uploadAlert("Vimeo nevrátilo adresu na nahratie titulkov.", ok: false)
                    return
                }
                var req = URLRequest(url: url)
                req.httpMethod = "PUT"
                req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
                URLSession.shared.uploadTask(with: req, from: data) { _, resp, err in
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    DispatchQueue.main.async {
                        guard err == nil, (200..<300).contains(code) else {
                            Diagnostics.shared.log("Titulky", "PUT → \(code) \(err?.localizedDescription ?? "")")
                            self.uploadAlert("Nahratie súboru zlyhalo (HTTP \(code)).", ok: false)
                            return
                        }
                        // Zapni titulky, aby boli dostupné v prehrávači.
                        VimeoAPI.shared.apiRequest(uri, method: "PATCH", body: ["active": true]) { r2 in
                            if case .failure(let e) = r2 { Diagnostics.shared.log("Titulky", "aktivácia → \(e.localizedDescription)") }
                            self.statusLabel.stringValue = "✓ Titulky nahraté"
                            self.uploadAlert("Titulky „\(name)“ sú nahraté na Vimeo. Vimeo ich môže chvíľu spracúvať.", ok: true)
                            if let r = self.ref { DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.load(r) } }
                        }
                    }
                }.resume()
            case .failure(let e):
                Diagnostics.shared.log("Titulky", "POST texttracks → \(e.localizedDescription)")
                self.uploadAlert("Titulky sa nepodarilo nahrať.\n\(e.localizedDescription)\n\nNahrávať titulky môže vlastník videa alebo člen tímu s oprávnením upravovať.", ok: false)
            }
        }
    }

    private func uploadAlert(_ text: String, ok: Bool) {
        let a = NSAlert()
        a.messageText = ok ? "Hotovo" : "Nahratie titulkov zlyhalo"
        a.informativeText = text
        a.alertStyle = ok ? .informational : .warning
        if let w = view.window { a.beginSheetModal(for: w, completionHandler: nil) } else { a.runModal() }
    }

    @objc private func saveSRT() {
        guard !cues.isEmpty, let window = view.window else { NSSound.beep(); return }
        func stamp(_ t: Double) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        var lines: [String] = []
        for (i, c) in cues.enumerated() {
            lines.append("\(i + 1)\n\(stamp(c.start)) --> \(stamp(max(c.end, c.start + 0.5)))\n\(c.text)\n")
        }
        let text = lines.joined(separator: "\n")
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["srt"]
        panel.nameFieldStringValue = "Titulky \(ref?.id ?? "videa").srt"
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { NSSound.beep() }
        }
    }

    @objc private func saveTranscript() {
        guard !cues.isEmpty, let window = view.window else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["txt"]
        panel.nameFieldStringValue = "Prepis \(ref?.id ?? "videa").txt"
        let text = transcriptText(withTimes: true)
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { NSSound.beep() }
        }
    }
}
