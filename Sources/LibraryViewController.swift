import AppKit

/// Uzol stromu v bočnom paneli: knižnica (vlastná / tímová) alebo priečinok.
final class FolderNode {
    let title: String
    let owner: String          // "/me" alebo "/users/123"
    let folderURI: String?     // nil = koreň knižnice
    weak var parent: FolderNode?
    var children: [FolderNode]?    // nil = ešte nenačítané
    var loading = false

    init(title: String, owner: String, folderURI: String?, parent: FolderNode?) {
        self.title = title
        self.owner = owner
        self.folderURI = folderURI
        self.parent = parent
    }

    var path: [FolderNode] {
        var p: [FolderNode] = [self]
        var n = parent
        while let x = n { p.insert(x, at: 0); n = x.parent }
        return p
    }
}

/// Hlavička skupiny v bočnom paneli.
final class SidebarHeader {
    let title: String
    init(_ t: String) { title = t }
}

/// Obľúbený priečinok – uložená celá cesta, aby sa dal otvoriť hneď po spustení.
struct FavoriteFolder: Codable, Equatable {
    let owner: String
    let path: [[String: String]]   // [{title, uri}], prvá položka = knižnica (uri "")
    var title: String { path.last?["title"] ?? "Priečinok" }
    var uri: String { path.last?["uri"] ?? "" }
}

/// Natívna knižnica: strom priečinkov v bočnom paneli + mriežka priečinkov a videí (ako na Vimeu).
final class LibraryViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                   NSCollectionViewDataSource, NSCollectionViewDelegate, NSMenuDelegate {
    var onOpenVideo: ((VimeoVideoRef) -> Void)?
    var onLogin: (() -> Void)?

    struct Level {
        let title: String
        let folderURI: String?
        var node: FolderNode?
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

    private var roots: [FolderNode] = []
    private let favHeader = SidebarHeader("OBĽÚBENÉ")
    private let libHeader = SidebarHeader("KNIŽNICE")
    private var favorites: [FavoriteFolder] = []
    private let favoritesKey = "favoriteFolders"
    private var starButton: NSButton!

    /// Položky najvyššej úrovne bočného panela.
    private var topItems: [Any] {
        var items: [Any] = []
        if !favorites.isEmpty {
            items.append(favHeader)
            items.append(contentsOf: favorites.map { box(for: $0) })
            items.append(libHeader)
        }
        items.append(contentsOf: roots)
        return items
    }
    private var favBoxes: [String: FavoriteBox] = [:]

    private func box(for f: FavoriteFolder) -> FavoriteBox {
        let key = f.owner + "|" + f.uri
        if let b = favBoxes[key], b.fav == f { return b }
        let b = FavoriteBox(f)
        favBoxes[key] = b
        return b
    }

    private func loadFavorites() {
        if let d = UserDefaults.standard.data(forKey: favoritesKey),
           let f = try? JSONDecoder().decode([FavoriteFolder].self, from: d) { favorites = f }
    }

    private func saveFavorites() {
        if let d = try? JSONEncoder().encode(favorites) { UserDefaults.standard.set(d, forKey: favoritesKey) }
        outline.reloadData()
        syncOutlineSelection()
        updateStar()
    }

    private func isFavorite(owner: String, uri: String) -> Bool {
        favorites.contains { $0.owner == owner && $0.uri == uri }
    }

    /// Pridá/odoberie priečinok z obľúbených (cesta = aktuálna cesta + priečinok).
    private func toggleFavorite(owner: String, path: [[String: String]]) {
        guard let uri = path.last?["uri"], !uri.isEmpty else { return }
        if let i = favorites.firstIndex(where: { $0.owner == owner && $0.uri == uri }) {
            favorites.remove(at: i)
        } else {
            favorites.append(FavoriteFolder(owner: owner, path: path))
        }
        saveFavorites()
    }

    private var currentPath: [[String: String]] {
        stack.map { ["title": $0.title, "uri": $0.folderURI ?? ""] }
    }

    @objc private func toggleCurrentFavorite() {
        guard stack.count > 1, searchQuery == nil else { NSSound.beep(); return }
        toggleFavorite(owner: currentOwner, path: currentPath)
    }

    private func updateStar() {
        guard let b = starButton else { return }
        let canStar = stack.count > 1 && searchQuery == nil
        b.isHidden = !canStar
        let fav = canStar && isFavorite(owner: currentOwner, uri: stack.last?.folderURI ?? "")
        b.image = NSImage(systemSymbolName: fav ? "star.fill" : "star", accessibilityDescription: "Obľúbené")
        b.contentTintColor = fav ? .systemYellow : .secondaryLabelColor
        b.toolTip = fav ? "Odobrať z obľúbených" : "Pridať priečinok medzi obľúbené"
    }

    private func openFavorite(_ f: FavoriteFolder) {
        UserDefaults.standard.set(f.owner, forKey: lastOwnerKey)
        let rootNode = roots.first(where: { $0.owner == f.owner })
        stack = f.path.enumerated().map { (i, p) in
            Level(title: p["title"] ?? "", folderURI: (p["uri"] ?? "").isEmpty ? nil : p["uri"], node: i == 0 ? rootNode : nil)
        }
        searchQuery = nil
        searchField.stringValue = ""
        loadLevel()
    }

    /// Obal pre NSOutlineView (potrebuje stabilné objekty).
    final class FavoriteBox {
        let fav: FavoriteFolder
        init(_ f: FavoriteFolder) { fav = f }
    }
    private var stack: [Level] = []
    private var rows: [Row] = []
    private var nextPage: String?
    private var nextIsItems = true
    private var loading = false
    private var requestID = UUID()
    private var thumbCache: [URL: NSImage] = [:]
    private var loadedOnce = false
    private var searchQuery: String?
    private var programmaticSelection = false
    private let lastOwnerKey = "libraryOwner"
    private let lastFolderKey = "libraryFolderPath"

    private let outline = NSOutlineView()
    private var collection: NSCollectionView!
    private let searchField = NSSearchField()
    private let statusLabel = UI.wrappingLabel("", size: 13, color: .secondaryLabelColor)
    private var loginButton: NSButton!
    private let pathBar = NSStackView()
    private static let gridID = NSUserInterfaceItemIdentifier("GridItem")

    private static let videoFields = "uri,name,duration,created_time,modified_time,link,pictures.sizes,privacy.view"
    private static let itemFields = "type,folder.uri,folder.name,folder.modified_time,video.uri,video.name,video.duration,video.created_time,video.modified_time,video.link,video.pictures.sizes,video.privacy.view"
    private static let folderOnlyFields = "type,folder.uri,folder.name"

    override func loadView() {
        let root = NSView()

        // Bočný panel – strom priečinkov
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tree"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowHeight = 24
        outline.indentationPerLevel = 14
        outline.dataSource = self
        outline.delegate = self
        let treeMenu = NSMenu()
        treeMenu.delegate = self
        outline.menu = treeMenu
        let treeScroll = NSScrollView()
        treeScroll.documentView = outline
        treeScroll.hasVerticalScroller = true
        treeScroll.drawsBackground = false

        // Mriežka
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 230, height: 196)
        layout.minimumInteritemSpacing = 18
        layout.minimumLineSpacing = 22
        layout.sectionInset = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        collection = NSCollectionView()
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.backgroundColors = [.controlBackgroundColor]
        collection.register(GridItem.self, forItemWithIdentifier: LibraryViewController.gridID)
        let gridScroll = NSScrollView()
        gridScroll.documentView = collection
        gridScroll.hasVerticalScroller = true
        gridScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification, object: gridScroll.contentView)

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
        starButton = UI.iconButton(symbol: "star", tooltip: "Pridať priečinok medzi obľúbené", target: self, action: #selector(toggleCurrentFavorite))
        starButton.isHidden = true
        let top = NSStackView(views: [pathBar, starButton, NSView(), loginButton, uploadButton, searchField, refresh])
        top.orientation = .horizontal
        top.spacing = 10
        top.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

        statusLabel.alignment = .center
        statusLabel.isHidden = true
        let right = NSView()
        right.addSubview(gridScroll)
        right.addSubview(statusLabel)
        UI.pin(gridScroll, to: right)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: right.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: right.topAnchor, constant: 60),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: right.widthAnchor, multiplier: 0.8),
        ])

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(treeScroll)
        split.addArrangedSubview(right)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        treeScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        treeScroll.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true

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
        DispatchQueue.main.async { split.setPosition(260, ofDividerAt: 0) }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func showIfNeeded() {
        _ = view
        if !loadedOnce {
            loadFavorites()
            reloadAll()
        }
    }

    // MARK: Knižnice

    @objc func reloadAll() {
        loadedOnce = true
        roots = []
        outline.reloadData()
        rows = []
        collection.reloadData()
        showStatus("Načítavam knižnicu…")

        VimeoAPI.shared.apiRequest("/me?fields=name,uri") { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let j):
                self.loginButton.isHidden = true
                let me = FolderNode(title: j["name"] as? String ?? "Moja knižnica", owner: "/me", folderURI: nil, parent: nil)
                self.roots = [me]
                self.outline.reloadData()
                self.loadTeams(myURI: j["uri"] as? String ?? "/me")
            case .failure(let e):
                Diagnostics.shared.log("Knižnica", "/me → \(e.localizedDescription)")
                self.loginButton.isHidden = false
                self.showStatus("Na zobrazenie knižnice sa prihláste do Vimea.")
            }
        }
    }

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
                    self.roots.append(FolderNode(title: name, owner: uri, folderURI: nil, parent: nil))
                }
            } else if case .failure(let e) = r {
                Diagnostics.shared.log("Knižnica", "/me/teams → \(e.localizedDescription)")
            }
            self.outline.reloadData()
            let saved = UserDefaults.standard.string(forKey: self.lastOwnerKey)
            let rootNode = self.roots.first(where: { $0.owner == saved }) ?? self.roots[0]
            self.outline.expandItem(rootNode)
            self.openNode(rootNode, restoreSaved: true)
        }
    }

    // MARK: Strom priečinkov (bočný panel)

    private func loadChildren(_ node: FolderNode, completion: (() -> Void)? = nil) {
        guard node.children == nil, !node.loading else { completion?(); return }
        node.loading = true
        let path = node.folderURI.map { "\($0)/items" } ?? "\(node.owner)/folders/root"
        loadFolderPage("\(path)?per_page=100&fields=\(LibraryViewController.folderOnlyFields)", node: node, acc: [], completion: completion)
    }

    private func loadFolderPage(_ path: String, node: FolderNode, acc: [FolderNode], completion: (() -> Void)?) {
        VimeoAPI.shared.apiRequest(path) { [weak self] r in
            guard let self = self else { return }
            var all = acc
            var next: String?
            switch r {
            case .success(let j):
                for d in j["data"] as? [[String: Any]] ?? [] {
                    guard (d["type"] as? String) == "folder", let f = d["folder"] as? [String: Any],
                          let uri = f["uri"] as? String else { continue }
                    all.append(FolderNode(title: f["name"] as? String ?? "Priečinok", owner: node.owner, folderURI: uri, parent: node))
                }
                next = (j["paging"] as? [String: Any])?["next"] as? String
            case .failure(let e):
                Diagnostics.shared.log("Knižnica", "strom \(path) → \(e.localizedDescription)")
            }
            if let n = next {
                self.loadFolderPage(n, node: node, acc: all, completion: completion)
                return
            }
            node.children = all
            node.loading = false
            self.programmaticSelection = true
            self.outline.reloadItem(node, reloadChildren: true)
            self.programmaticSelection = false
            self.syncOutlineSelection()
            completion?()
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return topItems.count }
        guard let n = item as? FolderNode else { return 0 }
        return n.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let n = item as? FolderNode else { return topItems[index] }
        return n.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is SidebarHeader }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { !(item is SidebarHeader) }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let n = item as? FolderNode else { return false }
        return n.children == nil || !(n.children!.isEmpty)
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        if let n = notification.userInfo?["NSObject"] as? FolderNode { loadChildren(n) }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let h = item as? SidebarHeader {
            let cell = NSTableCellView()
            let l = NSTextField(labelWithString: h.title)
            l.font = .systemFont(ofSize: 11, weight: .semibold)
            l.textColor = .secondaryLabelColor
            cell.addSubview(l)
            l.translatesAutoresizingMaskIntoConstraints = false
            l.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
            l.centerYAnchor.constraint(equalTo: cell.centerYAnchor).isActive = true
            return cell
        }
        let n: FolderNode
        var favIcon = false
        if let fb = item as? FavoriteBox {
            n = FolderNode(title: fb.fav.title, owner: fb.fav.owner, folderURI: fb.fav.uri, parent: nil)
            favIcon = true
        } else if let fn = item as? FolderNode {
            n = fn
        } else {
            return nil
        }
        let cell = NSTableCellView()
        let symbol = favIcon ? "star.fill" : (n.folderURI == nil ? (n.owner == "/me" ? "film" : "person.3") : "folder")
        let iv = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        iv.contentTintColor = favIcon ? .systemYellow : .controlAccentColor
        iv.setContentHuggingPriority(.required, for: .horizontal)
        let label = NSTextField(labelWithString: n.title)
        label.lineBreakMode = .byTruncatingTail
        label.font = n.folderURI == nil ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 13)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let st = NSStackView(views: [iv, label])
        st.orientation = .horizontal
        st.spacing = 6
        cell.addSubview(st)
        st.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            st.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            st.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            st.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.toolTip = n.title
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !programmaticSelection else { return }
        let item = outline.item(atRow: outline.selectedRow)
        if let fb = item as? FavoriteBox { openFavorite(fb.fav); return }
        guard let n = item as? FolderNode else { return }
        openNode(n, restoreSaved: false)
    }

    // Kontextové menu stromu (pridať/odobrať obľúbené)
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let item = outline.item(atRow: outline.clickedRow)
        if let fb = item as? FavoriteBox {
            let mi = NSMenuItem(title: "Odobrať z obľúbených", action: #selector(treeToggleFavorite(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = ["owner": fb.fav.owner, "uri": fb.fav.uri]
            menu.addItem(mi)
        } else if let n = item as? FolderNode, let uri = n.folderURI {
            let fav = isFavorite(owner: n.owner, uri: uri)
            let mi = NSMenuItem(title: fav ? "Odobrať z obľúbených" : "Pridať medzi obľúbené",
                                action: #selector(treeToggleFavorite(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = n
            menu.addItem(mi)
        }
    }

    @objc private func treeToggleFavorite(_ sender: NSMenuItem) {
        if let n = sender.representedObject as? FolderNode {
            toggleFavorite(owner: n.owner, path: n.path.map { ["title": $0.title, "uri": $0.folderURI ?? ""] })
        } else if let d = sender.representedObject as? [String: String], let owner = d["owner"], let uri = d["uri"] {
            favorites.removeAll { $0.owner == owner && $0.uri == uri }
            saveFavorites()
        }
    }

    /// Otvorí knižnicu alebo priečinok zo stromu.
    private func openNode(_ node: FolderNode, restoreSaved: Bool) {
        stack = node.path.map { Level(title: $0.title, folderURI: $0.folderURI, node: $0) }
        if restoreSaved, node.folderURI == nil, let data = UserDefaults.standard.data(forKey: lastFolderKey),
           let saved = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]],
           saved.first?["owner"] == node.owner {
            for l in saved.dropFirst() {
                if let uri = l["uri"], !uri.isEmpty, let t = l["title"] { stack.append(Level(title: t, folderURI: uri, node: nil)) }
            }
        }
        searchQuery = nil
        searchField.stringValue = ""
        loadLevel()
    }

    /// Označí v strome aktuálny priečinok (ak je už načítaný) a rozbalí cestu k nemu.
    private func syncOutlineSelection() {
        // Ak je otvorený obľúbený priečinok, označ ho v Obľúbených.
        if stack.count > 1, let uri = stack.last?.folderURI,
           let fav = favorites.first(where: { $0.owner == currentOwner && $0.uri == uri }) {
            let row = outline.row(forItem: box(for: fav))
            if row >= 0 && row != outline.selectedRow {
                programmaticSelection = true
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                programmaticSelection = false
            }
            return
        }
        guard let rootNode = roots.first(where: { $0.owner == currentOwner }) else { return }
        var node = rootNode
        for level in stack.dropFirst() {
            guard let kids = node.children, let child = kids.first(where: { $0.folderURI == level.folderURI }) else { break }
            outline.expandItem(node)
            node = child
        }
        let row = outline.row(forItem: node)
        if row >= 0 && row != outline.selectedRow {
            programmaticSelection = true
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
            programmaticSelection = false
        }
    }

    private var currentOwner: String {
        return stack.first?.node?.owner ?? UserDefaults.standard.string(forKey: lastOwnerKey) ?? "/me"
    }

    private func saveStack() {
        let owner = currentOwner
        UserDefaults.standard.set(owner, forKey: lastOwnerKey)
        var arr: [[String: String]] = [["owner": owner]]
        for l in stack.dropFirst() { arr.append(["uri": l.folderURI ?? "", "title": l.title]) }
        if let d = try? JSONSerialization.data(withJSONObject: arr) { UserDefaults.standard.set(d, forKey: lastFolderKey) }
    }

    // MARK: Obsah (mriežka)

    private func loadLevel() {
        guard let level = stack.last else { return }
        let owner = currentOwner
        saveStack()
        updatePathBar()
        updateStar()
        syncOutlineSelection()
        let id = UUID()
        requestID = id
        rows = []
        nextPage = nil
        collection.reloadData()
        showStatus("Načítavam…")
        if let q = searchQuery, let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            fetch("\(owner)/videos?per_page=50&query=\(enc)&fields=\(LibraryViewController.videoFields)", id: id, itemsFormat: false)
        } else if let folder = level.folderURI {
            fetch("\(folder)/items?per_page=100&fields=\(LibraryViewController.itemFields)", id: id, itemsFormat: true)
        } else {
            fetch("\(owner)/folders/root?per_page=100&fields=\(LibraryViewController.itemFields)", id: id, itemsFormat: true)
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
                var newRows: [Row] = []
                for d in j["data"] as? [[String: Any]] ?? [] {
                    if itemsFormat {
                        if (d["type"] as? String) == "folder", let f = d["folder"] as? [String: Any], let uri = f["uri"] as? String {
                            let date = (f["modified_time"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                            newRows.append(.folder(uri: uri, name: f["name"] as? String ?? "Priečinok", date: date))
                        } else if let v = d["video"] as? [String: Any], let item = LibraryViewController.parse(v) {
                            newRows.append(.video(item))
                        }
                    } else if let item = LibraryViewController.parse(d) {
                        newRows.append(.video(item))
                    }
                }
                var folders: [Row] = []
                var videos: [Row] = []
                for row in self.rows + newRows {
                    if case .folder = row { folders.append(row) } else { videos.append(row) }
                }
                self.rows = folders + videos
                self.nextPage = (j["paging"] as? [String: Any])?["next"] as? String
                self.collection.reloadData()
                if self.rows.isEmpty { self.showStatus(self.searchQuery == nil ? "Prázdny priečinok." : "Nič sa nenašlo.") }
                else { self.statusLabel.isHidden = true }
            case .failure(let e):
                Diagnostics.shared.log("Knižnica", "\(path) → \(e.localizedDescription)")
                if self.rows.isEmpty {
                    if self.stack.count > 1 && self.searchQuery == nil && self.stack.last?.node == nil {
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
        let name = (j["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(bez názvu)"
        return Item(ref: r, title: name, duration: (j["duration"] as? NSNumber)?.doubleValue ?? 0,
                    date: date, thumb: thumb, privacy: privacy)
    }

    @objc private func scrolled() {
        guard let next = nextPage, !loading, let sv = collection.enclosingScrollView else { return }
        let visible = sv.contentView.bounds
        if visible.maxY > collection.frame.height - 500 {
            nextPage = nil
            fetch(next, id: requestID, itemsFormat: nextIsItems)
        }
    }

    // MARK: Mriežka – dáta

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        return rows.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: LibraryViewController.gridID, for: indexPath)
        guard let g = item as? GridItem, indexPath.item < rows.count else { return item }
        let idx = indexPath.item
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        switch rows[idx] {
        case .folder(_, let name, let date):
            var meta = "Priečinok"
            if let d = date { meta += "  ·  " + f.string(from: d) }
            if case .folder(let uri, _, _) = rows[idx], isFavorite(owner: currentOwner, uri: uri) { meta = "★ " + meta }
            g.configure(title: name, meta: meta, image: nil, isFolder: true)
        case .video(let v):
            var meta: [String] = []
            if v.duration > 0 { meta.append(VimeoLinks.formatTime(v.duration)) }
            if let d = v.date { meta.append(f.string(from: d)) }
            switch v.privacy {
            case "anybody": meta.append("Verejné")
            case "unlisted": meta.append("Nezverejnené")
            case "nobody", "password", "disable", "users", "contacts", "team": meta.append("Súkromné")
            default: break
            }
            var img: NSImage?
            if let u = v.thumb {
                if let c = thumbCache[u] { img = c } else { loadThumb(u, index: idx) }
            }
            g.configure(title: v.title, meta: meta.joined(separator: "  ·  "), image: img, isFolder: false)
        }
        g.menuProvider = { [weak self] in self?.contextMenu(for: idx) }
        return g
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let ip = indexPaths.first, ip.item < rows.count else { return }
        collectionView.deselectAll(nil)
        open(rows[ip.item])
    }

    private func loadThumb(_ url: URL, index: Int) {
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let d = data, let img = NSImage(data: d) else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.thumbCache[url] = img
                if index < self.rows.count, case .video(let v) = self.rows[index], v.thumb == url {
                    self.collection.reloadItems(at: [IndexPath(item: index, section: 0)])
                }
            }
        }.resume()
    }

    // MARK: Navigácia

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

    private func open(_ row: Row) {
        switch row {
        case .folder(let uri, let name, _):
            let node = stack.last?.node?.children?.first(where: { $0.folderURI == uri })
            stack.append(Level(title: name, folderURI: uri, node: node))
            searchQuery = nil
            searchField.stringValue = ""
            if let parent = stack[stack.count - 2].node, parent.children == nil {
                loadChildren(parent)   // načítaj strom, aby sa dal označiť
            }
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
        if roots.isEmpty { reloadAll(); return }
        if let n = stack.last?.node {
            n.children = nil
            outline.reloadItem(n, reloadChildren: true)
        }
        loadLevel()
    }

    @objc private func login() { onLogin?() }

    private func showStatus(_ s: String) {
        statusLabel.stringValue = s
        statusLabel.isHidden = false
    }

    // MARK: Kontextové menu, nahrávanie, sťahovanie

    private var menuIndex = -1

    private func contextMenu(for index: Int) -> NSMenu? {
        guard index < rows.count else { return nil }
        menuIndex = index
        let m = NSMenu()
        m.addItem(withTitle: "Otvoriť", action: #selector(contextOpen), keyEquivalent: "").target = self
        if case .folder(let uri, _, _) = rows[index] {
            let fav = isFavorite(owner: currentOwner, uri: uri)
            m.addItem(withTitle: fav ? "Odobrať z obľúbených" : "Pridať medzi obľúbené",
                      action: #selector(contextToggleFavorite), keyEquivalent: "").target = self
        }
        if case .video = rows[index] {
            m.addItem(withTitle: "Stiahnuť…", action: #selector(contextDownload), keyEquivalent: "").target = self
            m.addItem(withTitle: "Kopírovať odkaz", action: #selector(contextCopyLink), keyEquivalent: "").target = self
        }
        return m
    }

    private var menuItem: Item? {
        guard menuIndex >= 0, menuIndex < rows.count, case .video(let item) = rows[menuIndex] else { return nil }
        return item
    }

    @objc private func contextOpen() {
        guard menuIndex >= 0, menuIndex < rows.count else { return }
        open(rows[menuIndex])
    }

    @objc private func contextToggleFavorite() {
        guard menuIndex >= 0, menuIndex < rows.count, case .folder(let uri, let name, _) = rows[menuIndex] else { return }
        toggleFavorite(owner: currentOwner, path: currentPath + [["title": name, "uri": uri]])
        collection.reloadData()
    }

    @objc private func contextDownload() {
        guard let i = menuItem else { NSSound.beep(); return }
        let anchor = collection.item(at: IndexPath(item: menuIndex, section: 0))?.view ?? collection!
        TransferManager.shared.chooseDownload(ref: i.ref, title: i.title, from: anchor)
    }

    @objc private func contextCopyLink() {
        guard let i = menuItem else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(i.ref.pageURL.absoluteString, forType: .string)
    }

    @objc func uploadVideo() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["public.movie", "mp4", "mov", "m4v", "avi", "mkv", "mxf", "webm"]
        panel.message = "Vyberte videá na nahratie do: \(stack.map { $0.title }.joined(separator: " › "))"
        panel.prompt = "Nahrať"
        let owner = currentOwner
        let folder = stack.last?.folderURI
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK else { return }
            for f in panel.urls {
                TransferManager.shared.upload(file: f, ownerPath: owner, folderURI: folder) { [weak self] in
                    self?.loadLevel()
                }
            }
        }
    }
}

// MARK: - Dlaždica mriežky

final class GridItemView: NSView {
    var menuProvider: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

final class GridItem: NSCollectionViewItem {
    private let thumb = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    var menuProvider: (() -> NSMenu?)? {
        get { (view as? GridItemView)?.menuProvider }
        set { (view as? GridItemView)?.menuProvider = newValue }
    }

    override func loadView() {
        let v = GridItemView()
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 8
        thumb.layer?.masksToBounds = true
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 2
        title.cell?.wraps = true
        title.cell?.truncatesLastVisibleLine = true
        meta.font = .systemFont(ofSize: 11)
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingTail
        for s in [thumb, title, meta] as [NSView] {
            s.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(s)
        }
        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: v.topAnchor),
            thumb.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            thumb.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            thumb.heightAnchor.constraint(equalTo: thumb.widthAnchor, multiplier: 9.0 / 16.0),
            title.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 7),
            title.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            title.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -2),
            meta.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            meta.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            meta.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -2),
        ])
        view = v
    }

    func configure(title t: String, meta m: String, image: NSImage?, isFolder: Bool) {
        _ = view
        title.stringValue = t
        title.toolTip = t
        meta.stringValue = m
        if isFolder {
            thumb.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Priečinok")
            thumb.contentTintColor = NSColor(red: 0.30, green: 0.72, blue: 0.82, alpha: 1)
            thumb.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
            thumb.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 56, weight: .regular)
            thumb.imageScaling = .scaleNone
        } else {
            thumb.symbolConfiguration = nil
            thumb.contentTintColor = nil
            thumb.imageScaling = .scaleProportionallyUpOrDown
            thumb.image = image
            thumb.layer?.backgroundColor = NSColor.black.cgColor
        }
    }

    override var isSelected: Bool {
        didSet { view.layer?.opacity = isSelected ? 0.7 : 1 }
    }
}
