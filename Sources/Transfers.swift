import AppKit

/// Jeden prenos (nahrávanie alebo sťahovanie).
final class Transfer {
    enum Kind { case upload, download }
    let kind: Kind
    let name: String
    var progress: Double = 0
    var status = ""
    var fileURL: URL?
    var finished = false
    var failed = false
    var cancel: (() -> Void)?

    init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }
}

/// Nahrávanie (Vimeo tus upload) a sťahovanie videí s priebehom.
final class TransferManager: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    static let shared = TransferManager()
    private(set) var transfers: [Transfer] = []
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private var downloads: [Int: (Transfer, URL)] = [:]
    private var uploadChunks: [Int: (Transfer, Int64, Int64)] = [:]   // transfer, offset chunku, celková veľkosť
    private static let chunkSize: Int64 = 64 * 1024 * 1024

    private func changed() {
        NotificationCenter.default.post(name: .transfersChanged, object: nil)
    }

    private func add(_ t: Transfer) {
        transfers.insert(t, at: 0)
        changed()
        AppDelegate.shared.showTransfers(nil)
    }

    func clearFinished() {
        transfers.removeAll { $0.finished || $0.failed }
        changed()
    }

    // MARK: - Sťahovanie

    private var menuContext: (title: String, window: NSWindow?)?

    /// Zistí dostupné kvality a ponúkne menu na stiahnutie.
    func chooseDownload(ref: VimeoVideoRef, title: String?, from view: NSView) {
        VimeoAPI.shared.apiRequest("\(ref.apiPath)?fields=name,download") { [weak self, weak view] r in
            guard let self = self else { return }
            switch r {
            case .success(let j):
                let name = (j["name"] as? String) ?? title ?? "Video \(ref.id)"
                let opts = (j["download"] as? [[String: Any]]) ?? []
                guard !opts.isEmpty else {
                    self.alert("Sťahovanie nie je dostupné",
                               "Vimeo k tomuto videu nesprístupnilo súbory na stiahnutie. Sťahovanie môže byť vypnuté vlastníkom videa alebo ho nepovoľuje typ účtu.",
                               window: view?.window)
                    return
                }
                let sorted = opts.sorted { (($0["width"] as? NSNumber)?.intValue ?? 0) > (($1["width"] as? NSNumber)?.intValue ?? 0) }
                let menu = NSMenu()
                let header = NSMenuItem(title: "Stiahnuť v kvalite:", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                for o in sorted {
                    guard let link = o["link"] as? String, let url = URL(string: link) else { continue }
                    let q = (o["public_name"] as? String) ?? (o["rendition"] as? String) ?? (o["quality"] as? String) ?? "?"
                    let size = (o["size_short"] as? String).map { " – \($0)" } ?? ""
                    let item = NSMenuItem(title: "\(q)\(size)", action: #selector(self.downloadPicked(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = [url, q, (o["type"] as? String) ?? "video/mp4"]
                    menu.addItem(item)
                }
                self.menuContext = (name, view?.window)
                if let v = view {
                    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: v.bounds.height + 4), in: v)
                } else if let w = NSApp.keyWindow, let cv = w.contentView {
                    menu.popUp(positioning: nil, at: cv.convert(w.mouseLocationOutsideOfEventStream, from: nil), in: cv)
                }
            case .failure(let e):
                Diagnostics.shared.log("Sťahovanie", e.localizedDescription)
                self.alert("Sťahovanie zlyhalo", e.localizedDescription, window: view?.window)
            }
        }
    }

    @objc private func downloadPicked(_ sender: NSMenuItem) {
        guard let arr = sender.representedObject as? [Any], let url = arr.first as? URL,
              let ctx = menuContext else { return }
        let quality = arr.count > 1 ? (arr[1] as? String ?? "") : ""
        let mime = arr.count > 2 ? (arr[2] as? String ?? "") : ""
        let ext = mime.contains("quicktime") ? "mov" : (url.pathExtension.isEmpty ? "mp4" : url.pathExtension)
        let base = TransferManager.safeFileName("\(ctx.title) \(quality)")
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(base).\(ext)"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let start: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let dest = panel.url else { return }
            self?.startDownload(url, to: dest, name: "\(ctx.title) (\(quality))")
        }
        if let w = ctx.window { panel.beginSheetModal(for: w, completionHandler: start) } else { start(panel.runModal()) }
    }

    static func safeFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
    }

    private func startDownload(_ url: URL, to dest: URL, name: String) {
        let t = Transfer(kind: .download, name: name)
        t.status = "Sťahujem…"
        t.fileURL = dest
        let task = session.downloadTask(with: url)
        downloads[task.taskIdentifier] = (t, dest)
        t.cancel = { [weak task] in task?.cancel() }
        add(t)
        task.resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let entry = downloads[downloadTask.taskIdentifier] else { return }
        let t = entry.0
        if totalBytesExpectedToWrite > 0 {
            t.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            t.status = "\(ByteCountFormatter.string(fromByteCount: totalBytesWritten, countStyle: .file)) z \(ByteCountFormatter.string(fromByteCount: totalBytesExpectedToWrite, countStyle: .file))"
        }
        changed()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let entry = downloads[downloadTask.taskIdentifier] else { return }
        let (t, dest) = entry
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            t.failed = true
            t.status = "Chyba HTTP \(http.statusCode)"
            return
        }
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: location, to: dest)
            t.finished = true
            t.progress = 1
            t.status = "Hotovo"
        } catch {
            t.failed = true
            t.status = "Súbor sa nepodarilo uložiť: \(error.localizedDescription)"
        }
        changed()
    }

    // MARK: - Nahrávanie (tus)

    /// - Parameters:
    ///   - ownerPath: "/me" alebo "/users/123" (tímový účet)
    ///   - folderURI: napr. "/users/123/projects/456" – video sa po nahratí presunie do priečinka
    func upload(file: URL, ownerPath: String, folderURI: String?, onFinished: @escaping () -> Void) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let name = file.deletingPathExtension().lastPathComponent
        let t = Transfer(kind: .upload, name: name)
        t.fileURL = file
        t.status = "Pripravujem nahrávanie…"
        add(t)
        guard size > 0 else {
            t.failed = true
            t.status = "Súbor je prázdny alebo nedostupný."
            changed()
            return
        }
        let body: [String: Any] = ["upload": ["approach": "tus", "size": NSNumber(value: size)], "name": name]
        VimeoAPI.shared.apiRequest("\(ownerPath)/videos", method: "POST", body: body) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let j):
                guard let link = (j["upload"] as? [String: Any])?["upload_link"] as? String, let url = URL(string: link) else {
                    t.failed = true
                    t.status = "Vimeo nevrátilo adresu na nahrávanie."
                    self.changed()
                    return
                }
                let videoURI = j["uri"] as? String
                var cancelled = false
                t.cancel = { cancelled = true; t.failed = true; t.status = "Zrušené"; self.changed() }
                self.sendChunk(t, file: file, to: url, offset: 0, size: size, retries: 3, isCancelled: { cancelled }) {
                    t.finished = true
                    t.progress = 1
                    t.status = "Nahraté – Vimeo video spracúva"
                    self.changed()
                    if let folder = folderURI, let v = videoURI, let vid = v.split(separator: "/").last {
                        VimeoAPI.shared.apiRequest("\(folder)/videos/\(vid)", method: "PUT", body: nil) { r in
                            if case .failure(let e) = r { Diagnostics.shared.log("Nahrávanie", "presun do priečinka → \(e.localizedDescription)") }
                            onFinished()
                        }
                    } else {
                        onFinished()
                    }
                }
            case .failure(let e):
                Diagnostics.shared.log("Nahrávanie", e.localizedDescription)
                t.failed = true
                t.status = "Nahrávanie sa nepodarilo začať: \(e.localizedDescription)"
                self.changed()
            }
        }
    }

    /// Nahradí súbor existujúceho videa novou verziou (odkaz, review link aj komentáre zostanú).
    func replace(ref: VimeoVideoRef, file: URL, title: String, onFinished: @escaping () -> Void) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let t = Transfer(kind: .upload, name: "Nahradenie: \(title) ← \(file.lastPathComponent)")
        t.fileURL = file
        t.status = "Pripravujem nahradenie…"
        add(t)
        guard size > 0 else {
            t.failed = true
            t.status = "Súbor je prázdny alebo nedostupný."
            changed()
            return
        }
        let body: [String: Any] = ["file_name": file.lastPathComponent,
                                   "upload": ["approach": "tus", "size": NSNumber(value: size)]]
        VimeoAPI.shared.apiRequest("/videos/\(ref.id)/versions", method: "POST", body: body) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let j):
                guard let link = (j["upload"] as? [String: Any])?["upload_link"] as? String, let url = URL(string: link) else {
                    t.failed = true
                    t.status = "Vimeo nevrátilo adresu na nahrávanie."
                    self.changed()
                    return
                }
                var cancelled = false
                t.cancel = { cancelled = true; t.failed = true; t.status = "Zrušené"; self.changed() }
                self.sendChunk(t, file: file, to: url, offset: 0, size: size, retries: 3, isCancelled: { cancelled }) {
                    t.finished = true
                    t.progress = 1
                    t.status = "Video nahradené – Vimeo spracúva novú verziu (môže to trvať niekoľko minút)"
                    self.changed()
                    onFinished()
                }
            case .failure(let e):
                Diagnostics.shared.log("Nahradenie", e.localizedDescription)
                t.failed = true
                t.status = "Nahradenie zlyhalo: \(e.localizedDescription) – nahradiť video môže vlastník alebo člen tímu s oprávnením upravovať."
                self.changed()
            }
        }
    }

    private func sendChunk(_ t: Transfer, file: URL, to url: URL, offset: Int64, size: Int64, retries: Int,
                           isCancelled: @escaping () -> Bool, done: @escaping () -> Void) {
        if isCancelled() { return }
        guard let fh = try? FileHandle(forReadingFrom: file) else {
            t.failed = true
            t.status = "Súbor sa nedá otvoriť."
            changed()
            return
        }
        fh.seek(toFileOffset: UInt64(offset))
        let chunk = fh.readData(ofLength: Int(min(TransferManager.chunkSize, size - offset)))
        fh.closeFile()

        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        req.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        req.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
        t.status = "Nahrávam…"
        let task = session.uploadTask(with: req, from: chunk) { [weak self] _, resp, err in
            guard let self = self else { return }
            if isCancelled() { return }
            let http = resp as? HTTPURLResponse
            let newOffset = (http?.value(forHTTPHeaderField: "Upload-Offset")).flatMap { Int64($0) }
            if err == nil, let code = http?.statusCode, (200..<300).contains(code), let no = newOffset {
                if no >= size { done() }
                else { self.sendChunk(t, file: file, to: url, offset: no, size: size, retries: 3, isCancelled: isCancelled, done: done) }
            } else if retries > 0 {
                t.status = "Opakujem…"
                self.changed()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.resumeOffset(url) { off in
                        self.sendChunk(t, file: file, to: url, offset: off ?? offset, size: size, retries: retries - 1,
                                       isCancelled: isCancelled, done: done)
                    }
                }
            } else {
                t.failed = true
                t.status = "Nahrávanie zlyhalo: \(err?.localizedDescription ?? "HTTP \(http?.statusCode ?? 0)")"
                Diagnostics.shared.log("Nahrávanie", t.status)
                self.changed()
            }
        }
        uploadChunks[task.taskIdentifier] = (t, offset, size)
        task.resume()
    }

    /// Zistí, koľko bajtov už Vimeo prijalo (pokračovanie po výpadku).
    private func resumeOffset(_ url: URL, completion: @escaping (Int64?) -> Void) {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        session.dataTask(with: req) { _, resp, _ in
            completion((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Upload-Offset").flatMap { Int64($0) })
        }.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let entry = uploadChunks[task.taskIdentifier], entry.2 > 0 else { return }
        let (t, base, size) = entry
        let sent = base + totalBytesSent
        t.progress = Double(sent) / Double(size)
        t.status = "Nahrávam \(ByteCountFormatter.string(fromByteCount: sent, countStyle: .file)) z \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
        changed()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        uploadChunks.removeValue(forKey: task.taskIdentifier)
        guard let entry = downloads.removeValue(forKey: task.taskIdentifier) else { return }
        let t = entry.0
        if let e = error as NSError?, !t.finished {
            t.failed = true
            t.status = e.code == NSURLErrorCancelled ? "Zrušené" : "Chyba: \(e.localizedDescription)"
            changed()
        }
    }

    private func alert(_ title: String, _ text: String, window: NSWindow?) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        if let w = window { a.beginSheetModal(for: w, completionHandler: nil) } else { a.runModal() }
    }
}

extension Notification.Name {
    static let transfersChanged = Notification.Name("VimeoViewerTransfersChanged")
}

/// Okno s priebehom nahrávania a sťahovania.
final class TransfersWindowController: NSWindowController {
    private let list = NSStackView()
    private let empty = UI.label("Žiadne prenosy.", size: 12, color: .secondaryLabelColor)

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.title = "Prenosy"
        super.init(window: win)

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 12
        list.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        list.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor),
            list.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        let clear = UI.button("Vymazať dokončené", target: self, action: #selector(clearDone))
        let bottom = NSStackView(views: [NSView(), clear])
        bottom.orientation = .horizontal
        bottom.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 10, right: 12)
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 0
        for v in [scroll, bottom] as [NSView] {
            root.addArrangedSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
            v.leadingAnchor.constraint(equalTo: root.leadingAnchor).isActive = true
            v.trailingAnchor.constraint(equalTo: root.trailingAnchor).isActive = true
        }
        scroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        win.contentView = root
        win.center()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .transfersChanged, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private var rows: [ObjectIdentifier: (NSProgressIndicator, NSTextField, NSButton)] = [:]

    @objc func refresh() {
        let transfers = TransferManager.shared.transfers
        // Prestav zoznam len pri zmene počtu, inak len aktualizuj hodnoty.
        if rows.count != transfers.count || transfers.contains(where: { rows[ObjectIdentifier($0)] == nil }) {
            list.arrangedSubviews.forEach { $0.removeFromSuperview() }
            rows = [:]
            if transfers.isEmpty { list.addArrangedSubview(empty) }
            for t in transfers { list.addArrangedSubview(makeRow(t)) }
        }
        for t in transfers {
            guard let row = rows[ObjectIdentifier(t)] else { continue }
            let (bar, status, button) = row
            bar.doubleValue = t.progress
            bar.isHidden = t.finished || t.failed
            status.stringValue = t.status
            status.textColor = t.failed ? .systemRed : (t.finished ? .systemGreen : .secondaryLabelColor)
            if t.finished || t.failed {
                button.title = t.kind == .download && t.finished ? "Zobraziť vo Finderi" : "Zobraziť súbor"
                button.isHidden = t.fileURL == nil
            } else {
                button.title = "Zrušiť"
            }
        }
    }

    private func makeRow(_ t: Transfer) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: t.kind == .upload ? "arrow.up.circle" : "arrow.down.circle",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let name = UI.label(t.name, size: 13, weight: .medium)
        let status = UI.label(t.status, size: 11, color: .secondaryLabelColor)
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        let button = NSButton(title: "Zrušiť", target: self, action: #selector(rowButton(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.identifier = NSUserInterfaceItemIdentifier(String(UInt(bitPattern: ObjectIdentifier(t).hashValue)))
        button.setContentHuggingPriority(.required, for: .horizontal)
        let texts = NSStackView(views: [name, bar, status])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 3
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalTo: texts.widthAnchor).isActive = true
        let row = NSStackView(views: [icon, texts, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 480).isActive = true
        rows[ObjectIdentifier(t)] = (bar, status, button)
        return row
    }

    @objc private func rowButton(_ sender: NSButton) {
        guard let t = TransferManager.shared.transfers.first(where: {
            sender.identifier?.rawValue == String(UInt(bitPattern: ObjectIdentifier($0).hashValue))
        }) else { return }
        if t.finished || t.failed {
            if let u = t.fileURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
        } else {
            t.cancel?()
        }
    }

    @objc private func clearDone() { TransferManager.shared.clearFinished() }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
