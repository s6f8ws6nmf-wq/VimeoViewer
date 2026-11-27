import AppKit

/// Aktualizácie z GitHub Releases priamo v aplikácii.
/// Súbor sa sťahuje bez karantény, takže nová verzia sa otvorí aj na najnovšom macOS bez Terminálu.
final class Updater: NSObject {
    static let shared = Updater()
    private let latestAPI = URL(string: "https://api.github.com/repos/s6f8ws6nmf-wq/VimeoViewer/releases/latest")!
    private let lastCheckKey = "lastUpdateCheck"

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// Tichá kontrola pri spustení (najviac raz za 6 hodín).
    func checkInBackground() {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 6 * 3600 else { return }
        check(userInitiated: false)
    }

    @objc func checkNow(_ sender: Any?) { check(userInitiated: true) }

    private func check(userInitiated: Bool) {
        var req = URLRequest(url: latestAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("VimeoViewer", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, error in
            DispatchQueue.main.async {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.lastCheckKey)
                guard let d = data, let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                      let tag = j["tag_name"] as? String else {
                    if userInitiated { self.alert("Aktualizácie sa nepodarilo overiť", error?.localizedDescription ?? "Skúste to neskôr.") }
                    return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let assets = j["assets"] as? [[String: Any]] ?? []
                let dmg = assets.first(where: { ($0["name"] as? String) == "VimeoViewer.dmg" })?["browser_download_url"] as? String
                if Updater.isNewer(latest, than: self.currentVersion), let s = dmg, let url = URL(string: s) {
                    self.offer(version: latest, url: url)
                } else if userInitiated {
                    self.alert("Máte najnovšiu verziu", "Vimeo Viewer \(self.currentVersion) je aktuálny.")
                }
            }
        }.resume()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func offer(version: String, url: URL) {
        let a = NSAlert()
        a.messageText = "Je dostupná nová verzia \(version)"
        a.informativeText = "Máte verziu \(currentVersion). Aktualizovať teraz? Aplikácia sa po aktualizácii sama znova spustí."
        a.addButton(withTitle: "Aktualizovať")
        a.addButton(withTitle: "Neskôr")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { download(url, version: version) }
    }

    private var progressWindow: NSWindow?

    private func download(_ url: URL, version: String) {
        let bar = NSProgressIndicator()
        bar.isIndeterminate = true
        bar.style = .bar
        bar.startAnimation(nil)
        let label = NSTextField(labelWithString: "Sťahujem Vimeo Viewer \(version)…")
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        bar.widthAnchor.constraint(equalToConstant: 320).isActive = true
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = "Aktualizácia"
        w.contentView = stack
        w.center()
        w.makeKeyAndOrderFront(nil)
        progressWindow = w

        URLSession.shared.downloadTask(with: url) { tmp, resp, error in
            var dmgPath: String?
            if let t = tmp, (resp as? HTTPURLResponse)?.statusCode ?? 0 < 400 {
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("VimeoViewer-update.dmg")
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.moveItem(at: t, to: dest)) != nil { dmgPath = dest.path }
            }
            DispatchQueue.main.async {
                self.progressWindow?.close()
                guard let dmg = dmgPath else {
                    self.alert("Aktualizácia zlyhala", error?.localizedDescription ?? "Súbor sa nepodarilo stiahnuť.")
                    return
                }
                self.install(dmg: dmg)
            }
        }.resume()
    }

    /// Po ukončení aplikácie pomocný skript nahradí aplikáciu novou verziou a znova ju spustí.
    private func install(dmg: String) {
        let appPath = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let mnt = FileManager.default.temporaryDirectory.appendingPathComponent("vv-update-mnt").path
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        mkdir -p \(q(mnt))
        hdiutil attach -nobrowse -noautoopen -quiet -mountpoint \(q(mnt)) \(q(dmg)) || exit 1
        NEW=\(q(mnt))/"Vimeo Viewer.app"
        if [ -d "$NEW" ]; then
          rm -rf \(q(appPath)).old
          mv \(q(appPath)) \(q(appPath)).old && ditto "$NEW" \(q(appPath)) && rm -rf \(q(appPath)).old || mv \(q(appPath)).old \(q(appPath))
          xattr -cr \(q(appPath)) 2>/dev/null
        fi
        hdiutil detach -quiet \(q(mnt))
        rm -f \(q(dmg))
        open \(q(appPath))
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script]
        do {
            try p.run()
            NSApp.terminate(nil)
        } catch {
            alert("Aktualizáciu sa nepodarilo spustiť", error.localizedDescription)
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
