import AppKit
import CoreServices

/// Posiela odkazy, ktoré nie sú z Vimea, do skutočného webového prehliadača
/// a stará sa o nastavenie aplikácie ako predvoleného prehliadača.
final class BrowserForwarder {
    static let shared = BrowserForwarder()
    private let fallbackKey = "fallbackBrowserBundleID"

    var ownBundleID: String { Bundle.main.bundleIdentifier ?? "sk.local.vimeoviewer" }

    private func isOwn(_ id: String) -> Bool { id.lowercased() == ownBundleID.lowercased() }

    /// Prehliadač, do ktorého idú všetky odkazy mimo Vimea.
    var fallbackBundleID: String {
        get {
            if let v = UserDefaults.standard.string(forKey: fallbackKey), !isOwn(v),
               NSWorkspace.shared.urlForApplication(withBundleIdentifier: v) != nil {
                return v
            }
            return "com.apple.Safari"
        }
        set {
            guard !isOwn(newValue) else { return }
            UserDefaults.standard.set(newValue, forKey: fallbackKey)
        }
    }

    var fallbackBrowserName: String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: fallbackBundleID) else { return "Safari" }
        return BrowserForwarder.appName(url)
    }

    static func appName(_ appURL: URL) -> String {
        var n = FileManager.default.displayName(atPath: appURL.path)
        if n.hasSuffix(".app") { n = String(n.dropLast(4)) }
        return n
    }

    /// Zoznam nainštalovaných aplikácií, ktoré vedia otvoriť https odkazy.
    func installedBrowsers() -> [(id: String, name: String)] {
        var result: [(id: String, name: String)] = []
        guard let probe = URL(string: "https://example.com"),
              let unmanaged = LSCopyApplicationURLsForURL(probe as CFURL, .viewer) else { return result }
        let urls = (unmanaged.takeRetainedValue() as NSArray).compactMap { $0 as? URL }
        for appURL in urls {
            guard let id = Bundle(url: appURL)?.bundleIdentifier, !isOwn(id) else { continue }
            if result.contains(where: { $0.id.lowercased() == id.lowercased() }) { continue }
            result.append((id: id, name: BrowserForwarder.appName(appURL)))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func currentDefaultBrowserID() -> String? {
        guard let u = LSCopyDefaultHandlerForURLScheme("https" as CFString) else { return nil }
        return u.takeRetainedValue() as String
    }

    var isDefaultBrowser: Bool {
        guard let cur = currentDefaultBrowserID() else { return false }
        return isOwn(cur)
    }

    /// macOS zobrazí systémový dialóg „Chcete zmeniť predvolený webový prehliadač?“.
    func makeDefaultBrowser() {
        if let cur = currentDefaultBrowserID(), !isOwn(cur) { fallbackBundleID = cur }
        LSSetDefaultHandlerForURLScheme("http" as CFString, ownBundleID as CFString)
        LSSetDefaultHandlerForURLScheme("https" as CFString, ownBundleID as CFString)
    }

    func restoreDefaultBrowser() {
        let id = fallbackBundleID
        LSSetDefaultHandlerForURLScheme("http" as CFString, id as CFString)
        LSSetDefaultHandlerForURLScheme("https" as CFString, id as CFString)
    }

    /// Otvorí odkazy v záložnom prehliadači (nikdy nie v tejto aplikácii).
    func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let ws = NSWorkspace.shared
        guard let appURL = ws.urlForApplication(withBundleIdentifier: fallbackBundleID)
                ?? ws.urlForApplication(withBundleIdentifier: "com.apple.Safari") else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        ws.open(urls, withApplicationAt: appURL, configuration: cfg) { _, error in
            if let e = error { NSLog("VimeoViewer: nepodarilo sa otvoriť odkaz v prehliadači: \(e)") }
        }
    }
}
