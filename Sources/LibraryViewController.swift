import AppKit

/// Natívna knižnica: vaše videá, tímové videá a priečinky – načítané priamo z Vimeo API
/// (nezávisí od webu vimeo.com, ktorý na starších verziách Safari nefunguje).
final class LibraryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onOpenVideo: ((VimeoVideoRef) -> Void)?
    var onLogin: (() -> Void)?

    struct Source {
        let title: String
        let path: String      // napr. /me/videos alebo /users/123/projects/456/videos
        let symbol: String
        var isHeader = false
    }

    struct Item {
        let ref: VimeoVideoRef
        let title: String
        let duration: Double
        let date: Date?
        let thumb: URL?
        let privacy: String
    }

    private var sources: [Source] = []
    private var items: [Item] = []
    private var nextPage: String?
    private var loadingMore = false
    private var requestID = UUID()
    private var thumbCache: [URL: NSImage] = [:]
    private var loadedOnce = false
    private let lastSourceKey = "librarySourcePath"

    private let sourceTable = NSTableView()
    private let videoTable = NSTableView()
    private let searchField = NSSearchField()
    private let accountLabel = UI.label("", size: 12, color: .secondaryLabelColor)
    private let statusLabel = UI.wrappingLabel("", size: 13, color: .secondaryLabelColor)
    private var loginButton: NSButton!
    private let headerLabel = UI.label("Knižnica", size: 17, weight: .semibold)

    private static let videoFields = "uri,name,duration,created_time,modified_time,link,pictures.sizes,privacy.view"

    override func loadView() {
        let root = NSView()

        // Zdroje (ľavý stĺpec)
        let sc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("src"))
        sourceTable.addTableColumn(sc)
        sourceTable.headerView = nil
        sourceTable.style = .sourceList
        sourceTable.rowHeight = 26
        sourceTable.dataSource = self
        sourceTable.delegate = self
        let sourceScroll = NSScrollView()
        sourceScroll.documentView = sourceTable
        sourceScroll.hasVerticalScroller = true
        sourceScroll.drawsBackground = false

        // Videá (pravá časť)
        let vc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("video"))
        videoTable.addTableColumn(vc)
        videoTable.headerView = nil
        videoTable.rowHeight = 78
        videoTable.intercellSpacing = NSSize(width: 0, height: 2)
        videoTable.dataSource = self
        videoTable.delegate = self
        videoTable.target = self
        videoTable.action = #selector(videoClicked)
        let videoScroll = NSScrollView()
        videoScroll.documentView = videoTable
        videoScroll.hasVerticalScroller = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification, object: videoScroll.contentView)
        videoScroll.contentView.postsBoundsChangedNotifications = true

        searchField.placeholderString = "Hľadať videá"
        searchField.target = self
        searchField.action = #selector(search)
        searchField.sendsWholeSearchString = true
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let refresh = UI.iconButton(symbol: "arrow.clockwise", tooltip: "Obnoviť", target: self, action: #selector(reloadAll))
        loginButton = UI.button("Prihlásiť sa", symbol: "person.crop.circle", target: self, action: #selector(login))
        loginButton.isHidden = true
        headerLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let top = NSStackView(views: [headerLabel, accountLabel, NSView(), loginButton, searchField, refresh])
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
        sourceScroll.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill
        root.addSubview(stack)
        UI.pin(stack, to: root)
        let sep = UI.separator()
        for v in [top, sep, split] {
            stack.addArrangedSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
            v.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            v.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
        split.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        view = root
        DispatchQueue.main.async { split.setPosition(240, ofDividerAt: 0) }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Volá sa pri zobrazení záložky.
    func showIfNeeded() {
        _ = view
        if !loadedOnce { reloadAll() }
    }

    // MARK: Načítanie zdrojov

    @objc func reloadAll() {
        loadedOnce = true
        userPicked = false
        accountLabel.stringValue = ""
        showStatus("Načítavam knižnicu…")
        sources = [Source(title: "Moje videá", path: "/me/videos", symbol: "film")]
        sourceTable.reloadData()

        VimeoAPI.shared.apiRequest("/me?fields=name,uri") { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let j):
                self.loginButton.isHidden = true
                self.accountLabel.stringValue = "· \(j["name"] as? String ?? "")"
                self.loadFolders(owner: "/me", title: nil)
                self.loadTeams()
                self.selectInitialSource()
            case .failure(let e):
                Diagnostics.shared.log("Knižnica", "/me → \(e.localizedDescription)")
                self.loginButton.isHidden = false
                self.items = []
                self.videoTable.reloadData()
                self.showStatus("Na zobrazenie knižnice sa prihláste do Vimea.")
            }
        }
    }

    private func loadFolders(owner: String, title: String?) {
        VimeoAPI.shared.apiRequest("\(owner)/projects?per_page=100&fields=uri,name") { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let j):
                let data = j["data"] as? [[String: Any]] ?? []
                guard !data.isEmpty else { return }
                var add: [Source] = [Source(title: title.map { "Priečinky – \($0)" } ?? "Priečinky", path: "", symbol: "", isHeader: true)]
                for f in data {
                    guard let uri = f["uri"] as? String else { continue }
                    add.append(Source(title: f["name"] as? String ?? "Priečinok", path: uri + "/videos", symbol: "folder"))
                }
                self.sources.append(contentsOf: add)
                self.sourceTable.reloadData()
                self.selectInitialSource()
            case .failure(let e):
                Diagnostics.shared.log("Knižnica", "\(owner)/projects → \(e.localizedDescription)")
            }
        }
    }

    /// Tímy, v ktorých je používateľ členom (Team library).
    private func loadTeams() {
        VimeoAPI.shared.apiRequest("/me/teams?per_page=50") { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let j):
                let data = j["data"] as? [[String: Any]] ?? []
                for t in data {
                    let owner = (t["owner"] as? [String: Any]) ?? (t["user"] as? [String: Any]) ?? t
                    guard let uri = owner["uri"] as? String, uri.hasPrefix("/users/") else { continue }
                    let name = (t["name"] as? String) ?? (owner["name"] as? String) ?? "Tím"
                    self.sources.append(Source(title: "Tím – \(name)", path: "", symbol: "", isHeader: true))
                    self.sources.append(Source(title: "Team library", path: uri + "/videos", symbol: "person.3"))
                    self.sourceTable.reloadData()
                    self.loadFolders(owner: uri, title: name)
                }
                self.selectInitialSource()
            case .failure(let e):
                Diagnostics.shared.log("Knižnica", "/me/teams → \(e.localizedDescription)")
            }
        }
    }

    private var programmatic = false
    private var userPicked = false

    /// Vyberie naposledy použitý zdroj (napr. Team library), keď sa objaví v zozname.
    private func selectInitialSource() {
        guard !userPicked else { return }
        let saved = UserDefaults.standard.string(forKey: lastSourceKey)
        if let i = sources.firstIndex(where: { $0.path == saved && !$0.isHeader }) {
            if i != sourceTable.selectedRow { select(i) }
            return
        }
        if sourceTable.selectedRow < 0, let i = sources.firstIndex(where: { !$0.isHeader }) { select(i) }
    }

    private func select(_ i: Int) {
        programmatic = true
        sourceTable.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        programmatic = false
    }

    // MARK: Načítanie videí

    private var currentSource: Source? {
        let r = sourceTable.selectedRow
        return r >= 0 && r < sources.count && !sources[r].isHeader ? sources[r] : nil
    }

    private func loadVideos(query: String? = nil) {
        guard let src = currentSource else { return }
        let id = UUID()
        requestID = id
        items = []
        nextPage = nil
        videoTable.reloadData()
        headerLabel.stringValue = src.title
        showStatus("Načítavam videá…")
        var path = "\(src.path)?per_page=50&sort=date&direction=desc&fields=\(LibraryViewController.videoFields)"
        if let q = query, !q.isEmpty, let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&query=\(enc)"
        }
        fetch(path, id: id)
    }

    private func fetch(_ path: String, id: UUID) {
        loadingMore = true
        VimeoAPI.shared.apiRequest(path) { [weak self] r in
            guard let self = self, self.requestID == id else { return }
            self.loadingMore = false
            switch r {
            case .success(let j):
                let data = j["data"] as? [[String: Any]] ?? []
                self.items.append(contentsOf: data.compactMap(LibraryViewController.parse))
                self.nextPage = (j["paging"] as? [String: Any])?["next"] as? String
                self.videoTable.reloadData()
                if self.items.isEmpty { self.showStatus("Žiadne videá.") } else { self.statusLabel.isHidden = true }
            case .failure(let e):
                Diagnostics.shared.log("Knižnica", "\(path) → \(e.localizedDescription)")
                if self.items.isEmpty { self.showStatus("Videá sa nepodarilo načítať.\n\(e.localizedDescription)") }
            }
        }
    }

    static func parse(_ j: [String: Any]) -> Item? {
        guard let link = j["link"] as? String, let url = URL(string: link),
              var ref = VimeoLinks.videoRef(from: url) ?? (j["uri"] as? String).flatMap({ uri -> VimeoVideoRef? in
                  let id = uri.split(separator: "/").last.map(String.init) ?? ""
                  return VimeoLinks.isNumeric(id) ? VimeoVideoRef(id: id, hash: nil, startTime: nil) : nil
              }) else { return nil }
        ref.startTime = nil
        var thumb: URL? = nil
        if let sizes = (j["pictures"] as? [String: Any])?["sizes"] as? [[String: Any]] {
            let pick = sizes.first(where: { ($0["width"] as? NSNumber)?.intValue ?? 0 >= 295 }) ?? sizes.last
            thumb = (pick?["link"] as? String).flatMap { URL(string: $0) }
        }
        let iso = ISO8601DateFormatter()
        let date = ((j["modified_time"] as? String) ?? (j["created_time"] as? String)).flatMap { iso.date(from: $0) }
        let privacy = ((j["privacy"] as? [String: Any])?["view"] as? String) ?? ""
        return Item(ref: ref, title: j["name"] as? String ?? "Video \(ref.id)",
                    duration: (j["duration"] as? NSNumber)?.doubleValue ?? 0, date: date, thumb: thumb, privacy: privacy)
    }

    @objc private func scrolled() {
        guard let next = nextPage, !loadingMore else { return }
        let visible = videoTable.rows(in: videoTable.visibleRect)
        if visible.location + visible.length >= items.count - 5 {
            nextPage = nil
            fetch(next, id: requestID)
        }
    }

    @objc private func search() { loadVideos(query: searchField.stringValue.trimmingCharacters(in: .whitespaces)) }
    @objc private func login() { onLogin?() }

    @objc private func videoClicked() {
        let r = videoTable.clickedRow
        guard r >= 0, r < items.count else { return }
        onOpenVideo?(items[r].ref)
    }

    private func showStatus(_ s: String) {
        statusLabel.stringValue = s
        statusLabel.isHidden = false
    }

    // MARK: Tabuľky

    func numberOfRows(in tableView: NSTableView) -> Int {
        return tableView === sourceTable ? sources.count : items.count
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        return tableView === sourceTable && sources[row].isHeader
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        return tableView === sourceTable ? !sources[row].isHeader : true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === sourceTable, let src = currentSource else { return }
        if !programmatic {
            userPicked = true
            UserDefaults.standard.set(src.path, forKey: lastSourceKey)
        }
        searchField.stringValue = ""
        loadVideos()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === sourceTable {
            let s = sources[row]
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: s.isHeader ? s.title.uppercased() : s.title)
            label.lineBreakMode = .byTruncatingTail
            label.font = s.isHeader ? .systemFont(ofSize: 11, weight: .semibold) : .systemFont(ofSize: 13)
            label.textColor = s.isHeader ? .secondaryLabelColor : .labelColor
            var views: [NSView] = []
            if !s.isHeader, let img = NSImage(systemSymbolName: s.symbol, accessibilityDescription: nil) {
                let iv = NSImageView(image: img)
                iv.contentTintColor = .controlAccentColor
                iv.setContentHuggingPriority(.required, for: .horizontal)
                views.append(iv)
            }
            views.append(label)
            let st = NSStackView(views: views)
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

        let item = items[row]
        let cell = NSTableCellView()
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 6
        iv.layer?.masksToBounds = true
        iv.layer?.backgroundColor = NSColor.black.cgColor
        if let u = item.thumb {
            if let img = thumbCache[u] { iv.image = img } else { loadThumb(u, row: row) }
        }
        let title = UI.label(item.title, size: 13, weight: .semibold)
        var meta: [String] = []
        if item.duration > 0 { meta.append(VimeoLinks.formatTime(item.duration)) }
        if let d = item.date {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            meta.append(f.string(from: d))
        }
        switch item.privacy {
        case "anybody": meta.append("Verejné")
        case "unlisted": meta.append("Nezverejnené")
        case "nobody", "password", "disable", "users", "contacts": meta.append("Súkromné")
        default: break
        }
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
                if row < self.items.count, self.items[row].thumb == url {
                    self.videoTable.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
                }
            }
        }.resume()
    }
}
