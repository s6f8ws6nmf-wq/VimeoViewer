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

        let stack = UI.vstack([header, trackPopup, searchField, UI.separator(), scrollView, bottom], spacing: 6)
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

    private func showCues(_ c: [Cue]) {
        cues = c
        statusLabel.stringValue = "\(c.count) úsekov"
        if c.isEmpty { showMessage("Prepis je prázdny.") } else { render() }
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
