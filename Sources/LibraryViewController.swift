import AppKit

/// Natívna knižnica s rovnakou štruktúrou ako na Vimeu: knižnica (vlastná / tímová) → priečinky → podpriečinky a videá.
/// Údaje idú priamo z Vimeo API cez prihlásenie (nezávisí od webu vimeo.com).
final class LibraryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onOpenVideo: ((VimeoVideoRef) -> Void)?
    var onLogin: (() -> Void)?

    /// Knižnica v ľavom stĺpci (vlastník videí).
    struct LibrarySource {
        let title: String
        let owner: String        // "/me" alebo "/users/123"
        let symbol: String
    }

    /// Úroveň v navigácii: koreň knižnice alebo priečinok.
    struct Level {
        let title: String
        let folderURI: String?   // nil = koreň knižnice
    }

    enum Row {
        case folder(uri: String, name: String, date: Date?)
        case video(Item)
    }

    struct Item {
        let ref: VimeoVideoRef
        let title: String
        let duration: Double
        let date: Date?
        let thumb: URL?
        let privacy: String
    }

    private var libraries: [LibrarySource] = []
    private var stack: [Level] = []
    private var rows: [Row] = []
    private var nextPage: String?
    private var loading = false
    private var requestID = UUID()
    private var thumbCache: [URL: NSImage] = [:]
    private var loadedOnce = false
    private var searchQuery: String?
    private var nextIsItems = true
    private let lastOwnerKey = "libraryOwner"
    private let lastFolderKey = "libraryFolderPath"

    private let sourceTable = NSTableView()
    private let videoTable = NSTableView()
    private let searchField = NSSearchField()
    private let statusLabel = UI.wrappingLabel("", size: 13, color: .secondaryLabelColor)
    private var loginButton: NSButton!
    private let pathBar = NSStackView()

    private static let videoFields = "uri,name,duration,created_time,modified_time,link,pictures.sizes,privacy.view"
    private static let itemFields = "type,folder.uri,folder.name,folder.modified_time,video.uri,video.name,video.duration,video.created_time,video.modified_time,video.link,video.pictures.sizes,video.privacy.view"

    override func loadView() {
        let root = NSView()

        let sc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("src"))
        sourceTable.addTableColumn(sc)
        sourceTable.headerView = nil
        sourceTable.style = .sourceList
        sourceTable.rowHeight = 28
        sourceTable.dataSource = self
        sourceTable.delegate = self
        let sourceScroll = NSScrollView()
        sourceScroll.documentView = sourceTable
        sourceScroll.hasVerticalScroller = true
        sourceScroll.drawsBackground = false

        let vc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        videoTable.addTableColumn(vc)
        videoTable.headerView = nil
        videoTable.rowHeight = 78
        videoTable.intercellSpacing = NSSize(width: 0, height: 2)
        videoTable.dataSource = self
        videoTable.delegate = self
        videoTable.target = self
        videoTable.action = #selector(rowClicked)
        let ctx = NSMenu()
        ctx.addItem(withTitle: "Otvoriť", action: #selector(contextOpen), keyEquivalent: "").target = self
        ctx.addItem(withTitle: "Stiahnuť…", action: #selector(contextDownload), keyEquivalent: "").target = self
        ctx.addItem(withTitle: "Kopírovať odkaz", action: #selector(contextCopyLink), keyEquivalent: "").target = self
        videoTable.menu = ctx
        let videoScroll = NSScrollView()
        videoScroll.documentView = videoTable
        videoScroll.hasVerticalScroller = true
        videoScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification, object: videoScroll.contentView)

        searchField.placeholderString = "Hľadať videá"
        searchField.target = self
        searchField.action = #selector(search)
        searchField.sendsWholeSearchString = true
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let refresh = UI.iconButton(symbol: "arrow.clockwise", tooltip: "Obnoviť", target: self, action: #selector(refreshCurrent))
        let uploadButton = UI.button("Nahrať video…", symbol: "arrow.up.circle", target: self, action: #selector(uploadVideo))
        loginButton = UI.button("Prihlásiť sa", symbol: "person.crop.circle", target: self, action: #selector(login))
        loginButton.isHidden = true

        pathBar.orientation = .horizontal
        pathBar.spacing = 2
        pathBar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let top = NSStackView(views: [pathBar, NSView(), loginButton, uploadButton, searchField, refresh])
        top.orientation = .horizontal
        top.spacing = 10
        top.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

        statusLabel.alignment = .center
        statusLabel.isHidden = true
        let right = NSView()
        right.addSubview(videoScroll)
        right.addSubview(statusLabel)
        UI.pin(videoScroll, to: right)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: right.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: right.topAnchor, constant: 60),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: right.widthAnchor, multiplier: 0.8),
        ])

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sourceScroll)
        split.addArrangedSubview(right)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        sourceScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        sourceScroll.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true

        let outer = NSStackView()
        outer.orientation = .vertical
        outer.spacing = 0
        outer.alignment = .leading
        outer.distribution = .fill
        root.addSubview(outer)
        UI.pin(outer, to: root)
        for v in [top, UI.separator(), split] as [NSView] {
            outer.addArrangedSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
            v.leadingAnchor.constraint(equalTo: outer.leadingAnchor).isActive = true
            v.trailingAnchor.constraint(equalTo: outer.trailingAnchor).isActive = true
        }
        split.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        view = root
        DispatchQueue.main.async { split.setPosition(220, ofDividerAt: 0) }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func showIfNeeded() {
        _ = view
        if !loadedOnce { reloadAll() }
    }

    // MARK: Knižnice (ľavý stĺpec)

    @objc func reloadAll() {
        loadedOnce = true
        libraries = []
        sourceTable.reloadData()
        rows = []
        videoTable.reloadData()
        showStatus("Načítavam knižnicu…")

        VimeoAPI.shared.apiRequest("/me?fields=name,uri") { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let j):
                self.loginButton.isHidden = true
                let myName = j["name"] as? String ?? "Moja knižnica"
                let myURI = j["uri"] as? String ?? "/me"
                self.libraries = [LibrarySource(title: myName, owner: "/me", symbol: "film")]
                self.sourceTable.reloadData()
                self.loadTeams(myURI: myURI)
            case .failure(let e):
                Diagnostics.shared.log("Knižnica", "/me → \(e.localizedDescription)")
                self.loginButton.isHidden = false
                self.showStatus("Na zobrazenie knižnice sa prihláste do Vimea.")
            }
        }
    }

    /// Tímové knižnice (bez duplicít; vlastný tím = vlastná knižnica).
    private func loadTeams(myURI: String) {
        VimeoAPI.shared.apiRequest("/me/teams?per_page=50") { [weak self] r in
            guard let self = self else { return }
            if case .success(let j) = r {
                var seen = Set<String>([myURI])
                for t in j["data"] as? [[String: Any]] ?? [] {
                    let owner = (t["owner"] as? [String: Any]) ?? (t["user"] as? [String: Any]) ?? t
                    guard let uri = owner["uri"] as? String, uri.hasPrefix("/users/"), !seen.contains(uri) else { continue }
                    seen.insert(uri)
                    let name = (owner["name"] as? String) ?? (t["name"] as? String) ?? "Tím"
                    self.libraries.append(LibrarySource(title: name, owner: uri, symbol: "person.3"))
                }
            } else if case .failure(let e) = r {
                Diagnostics.shared.log("Knižnica", "/me/teams → \(e.localizedDescription)")
            }
            self.sourceTable.reloadData()
            let saved = UserDefaults.standard.string(forKey: self.lastOwnerKey)
            let idx = self.libraries.firstIndex(where: { $0.owner == saved }) ?? 0
            self.stack = []
            self.sourceTable.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            self.openLibrary(self.libraries[idx], restoreFolder: true)
        }
    }

    private var currentLibrary: LibrarySource? {
        let r = sourceTable.selectedRow
        return r >= 0 && r < libraries.count ? libraries[r] : nil
    }

    private func openLibrary(_ lib: LibrarySource, restoreFolder: Bool) {
        UserDefaults.standard.set(lib.owner, forKey: lastOwnerKey)
        stack = [Level(title: lib.title, folderURI: nil)]
        if restoreFolder, let data = UserDefaults.standard.data(forKey: lastFolderKey),
           let saved = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]],
           saved.first?["owner"] == lib.owner {
            for l in saved.dropFirst() {
                if let uri = l["uri"], !uri.isEmpty, let t = l["title"] { stack.append(Level(title: t, folderURI: uri)) }
            }
        }
        searchField.stringValue = ""
        searchQuery = nil
        loadLevel()
    }

    private func saveStack() {
        guard let lib = currentLibrary else { return }
        var arr: [[String: String]] = [["owner": lib.owner]]
        for l in stack.dropFirst() { arr.append(["uri": l.folderURI ?? "", "title": l.title]) }
        if let d = try? JSONSerialization.data(withJSONObject: arr) { UserDefaults.standard.set(d, forKey: lastFolderKey) }
    }

    // MARK: Obsah úrovne (priečinky + videá)

    private func loadLevel() {
        guard let lib = currentLibrary, let level = stack.last else { return }
        saveStack()
        updatePathBar()
        let id = UUID()
        requestID = id
        rows = []
        nextPage = nil
        videoTable.reloadData()
        showStatus("Načítavam…")
        if let q = searchQuery, let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            fetch("\(lib.owner)/videos?per_page=50&query=\(enc)&fields=\(LibraryViewController.videoFields)", id: id, itemsFormat: false)
        } else if let folder = level.folderURI {
            fetch("\(folder)/items?per_page=100&fields=\(LibraryViewController.itemFields)", id: id, itemsFormat: true)
        } else {
            fetch("\(lib.owner)/folders/root?per_page=100&fields=\(LibraryViewController.itemFields)", id: id, itemsFormat: true)
        }
    }

    private func fetch(_ path: String, id: UUID, itemsFormat: Bool) {
        loading = true
        nextIsItems = itemsFormat
        VimeoAPI.shared.apiRequest(path) { [weak self] r in
            guard let self = self, self.requestID == id else { return }
            self.loading = false
            switch r {
            case .success(let j):
                let data = j["data"] as? [[String: Any]] ?? []
                var newRows: [Row] = []
                for d in data {
                    if itemsFormat {
                        let type = d["type"] as? String ?? ""
                        if type == "folder", let f = d["folder"] as? [String: Any], let uri = f["uri"] as? String {
                            let date = (f["modified_time"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                            newRows.append(.folder(uri: uri, name: f["name"] as? String ?? "Priečinok", date: date))
                        } else if let v = d["video"] as? [String: Any], let item = LibraryViewController.parse(v) {
                            newRows.append(.video(item))
                        }
                    } else if let item = LibraryViewController.parse(d) {
                        newRows.append(.video(item))
                    }
                }
                // Priečinky navrchu, inak poradie podľa Vimea.
                let all = self.rows + newRows
                var folders: [Row] = []
                var videos: [Row] = []
                for row in all {
                    if case .folder = row { folders.append(row) } else { videos.append(row) }
                }
                self.rows = folders + videos
                self.nextPage = (j["paging"] as? [String: Any])?["next"] as? String
                self.videoTable.reloadData()
                if self.rows.isEmpty { self.showStatus(self.searchQuery == nil ? "Prázdny priečinok." : "Nič sa nenašlo.") }
                else { self.statusLabel.isHidden = true }
            case .failure(let e):
                Diagnostics.shared.log("Knižnica", "\(path) → \(e.localizedDescription)")
                if self.rows.isEmpty {
                    if self.stack.count > 1 && self.searchQuery == nil {
                        // Uložený priečinok už neexistuje – späť na koreň knižnice.
                        self.stack = [self.stack[0]]
                        self.loadLevel()
                    } else {
                        self.showStatus("Obsah sa nepodarilo načítať.\n\(e.localizedDescription)")
                    }
                }
            }
        }
    }

    static func parse(_ j: [String: Any]) -> Item? {
        var ref: VimeoVideoRef?
        if let link = j["link"] as? String, let url = URL(string: link) { ref = VimeoLinks.videoRef(from: url) }
        if ref == nil, let uri = j["uri"] as? String, let id = uri.split(separator: "/").last.map(String.init), VimeoLinks.isNumeric(id) {
            ref = VimeoVideoRef(id: id, hash: nil, startTime: nil)
        }
        guard var r = ref else { return nil }
        r.startTime = nil
        var thumb: URL?
        if let sizes = (j["pictures"] as? [String: Any])?["sizes"] as? [[String: Any]] {
            let pick = sizes.first(where: { (($0["width"] as? NSNumber)?.intValue ?? 0) >= 295 }) ?? sizes.last
            thumb = (pick?["link"] as? String).flatMap { URL(string: $0) }
        }
        let iso = ISO8601DateFormatter()
        let date = ((j["created_time"] as? String) ?? (j["modified_time"] as? String)).flatMap { iso.date(from: $0) }
        let privacy = ((j["privacy"] as? [String: Any])?["view"] as? String) ?? ""
        // Názov presne tak, ako je na Vimeu.
        let name = (j["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(bez názvu)"
        return Item(ref: r, title: name, duration: (j["duration"] as? NSNumber)?.doubleValue ?? 0,
                    date: date, thumb: thumb, privacy: privacy)
    }

    @objc private func scrolled() {
        guard let next = nextPage, !loading else { return }
        let visible = videoTable.rows(in: videoTable.visibleRect)
        if visible.location + visible.length >= rows.count - 5 {
            nextPage = nil
            fetch(next, id: requestID, itemsFormat: nextIsItems)
        }
    }

    // MARK: Navigačná cesta

    private func updatePathBar() {
        pathBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, level) in stack.enumerated() {
            if i > 0 { pathBar.addArrangedSubview(UI.label("›", size: 15, color: .tertiaryLabelColor)) }
            let isLast = i == stack.count - 1 && searchQuery == nil
            let b = NSButton(title: level.title, target: self, action: #selector(pathClicked(_:)))
            b.isBordered = false
            b.tag = i
            b.font = .systemFont(ofSize: isLast ? 16 : 14, weight: isLast ? .semibold : .regular)
            b.contentTintColor = isLast ? .labelColor : .secondaryLabelColor
            b.lineBreakMode = .byTruncatingTail
            b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            pathBar.addArrangedSubview(b)
        }
        if searchQuery != nil {
            pathBar.addArrangedSubview(UI.label("›  Výsledky hľadania", size: 16, weight: .semibold))
        }
    }

    @objc private func pathClicked(_ sender: NSButton) {
        guard sender.tag < stack.count else { return }
        stack = Array(stack.prefix(sender.tag + 1))
        searchQuery = nil
        searchField.stringValue = ""
        loadLevel()
    }

    /// Krok späť v knižnici (priečinok vyššie). Vráti false, ak už sme na koreni.
    func goUp() -> Bool {
        if searchQuery != nil {
            searchQuery = nil
            searchField.stringValue = ""
        } else if stack.count > 1 {
            stack.removeLast()
        } else {
            return false
        }
        loadLevel()
        return true
    }

    // MARK: Akcie

    @objc private func rowClicked() {
        let r = videoTable.clickedRow
        guard r >= 0, r < rows.count else { return }
        open(rows[r])
    }

    private func open(_ row: Row) {
        switch row {
        case .folder(let uri, let name, _):
            stack.append(Level(title: name, folderURI: uri))
            searchQuery = nil
            searchField.stringValue = ""
            loadLevel()
        case .video(let item):
            onOpenVideo?(item.ref)
        }
    }

    @objc private func search() {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        searchQuery = q.isEmpty ? nil : q
        loadLevel()
    }

    @objc func refreshCurrent() {
        if libraries.isEmpty { reloadAll() } else { loadLevel() }
    }

    @objc private func login() { onLogin?() }

    private func showStatus(_ s: String) {
        statusLabel.stringValue = s
        statusLabel.isHidden = false
    }

    // MARK: Nahrávanie a sťahovanie

    @objc func uploadVideo() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["public.movie", "mp4", "mov", "m4v", "avi", "mkv", "mxf", "webm"]
        panel.message = "Vyberte videá na nahratie do: \(stack.map { $0.title }.joined(separator: " › "))"
        panel.prompt = "Nahrať"
        let owner = currentLibrary?.owner ?? "/me"
        let folder = stack.last?.folderURI
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK else { return }
            for f in panel.urls {
                TransferManager.shared.upload(file: f, ownerPath: owner, folderURI: folder) { [weak self] in
                    self?.loadLevel()
                }
            }
        }
    }

    private var contextItem: Item? {
        let r = videoTable.clickedRow
        guard r >= 0, r < rows.count, case .video(let item) = rows[r] else { return nil }
        return item
    }

    @objc private func contextOpen() {
        let r = videoTable.clickedRow
        guard r >= 0, r < rows.count else { return }
        open(rows[r])
    }

    @objc private func contextDownload() {
        guard let i = contextItem else { NSSound.beep(); return }
        let anchor = videoTable.view(atColumn: 0, row: videoTable.clickedRow, makeIfNecessary: false) ?? videoTable
        TransferManager.shared.chooseDownload(ref: i.ref, title: i.title, from: anchor)
    }

    @objc private func contextCopyLink() {
        guard let i = contextItem else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(i.ref.pageURL.absoluteString, forType: .string)
    }

    // MARK: Tabuľky

    func numberOfRows(in tableView: NSTableView) -> Int {
        return tableView === sourceTable ? libraries.count : rows.count
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === sourceTable, let lib = currentLibrary else { return }
        // Prepnutie knižnice používateľom (pri štarte sa knižnica otvára v loadTeams).
        if !stack.isEmpty && UserDefaults.standard.string(forKey: lastOwnerKey) != lib.owner {
            openLibrary(lib, restoreFolder: false)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === sourceTable {
            let s = libraries[row]
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: s.title)
            label.lineBreakMode = .byTruncatingTail
            label.font = .systemFont(ofSize: 13)
            let iv = NSImageView(image: NSImage(systemSymbolName: s.symbol, accessibilityDescription: nil) ?? NSImage())
            iv.contentTintColor = .controlAccentColor
            iv.setContentHuggingPriority(.required, for: .horizontal)
            let st = NSStackView(views: [iv, label])
            st.orientation = .horizontal
            st.spacing = 6
            cell.addSubview(st)
            st.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                st.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                st.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                st.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        let cell = NSTableCellView()
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 6
        iv.layer?.masksToBounds = true
        var titleText = ""
        var meta: [String] = []
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none

        switch rows[row] {
        case .folder(_, let name, let date):
            iv.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Priečinok")
            iv.contentTintColor = .systemBlue
            titleText = name
            meta.append("Priečinok")
            if let d = date { meta.append(f.string(from: d)) }
        case .video(let item):
            iv.layer?.backgroundColor = NSColor.black.cgColor
            if let u = item.thumb {
                if let img = thumbCache[u] { iv.image = img } else { loadThumb(u, row: row) }
            }
            titleText = item.title
            if item.duration > 0 { meta.append(VimeoLinks.formatTime(item.duration)) }
            if let d = item.date { meta.append(f.string(from: d)) }
            switch item.privacy {
            case "anybody": meta.append("Verejné")
            case "unlisted": meta.append("Nezverejnené")
            case "nobody", "password", "disable", "users", "contacts", "team": meta.append("Súkromné")
            default: break
            }
        }
        let title = UI.label(titleText, size: 13, weight: .semibold)
        let sub = UI.label(meta.joined(separator: "  ·  "), size: 11, color: .secondaryLabelColor)
        let texts = NSStackView(views: [title, sub])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 3
        cell.addSubview(iv)
        cell.addSubview(texts)
        iv.translatesAutoresizingMaskIntoConstraints = false
        texts.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 120),
            iv.heightAnchor.constraint(equalToConstant: 68),
            texts.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 12),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -12),
            texts.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func loadThumb(_ url: URL, row: Int) {
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let d = data, let img = NSImage(data: d) else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.thumbCache[url] = img
                if row < self.rows.count, case .video(let item) = self.rows[row], item.thumb == url {
                    self.videoTable.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
                }
            }
        }.resume()
    }
}
