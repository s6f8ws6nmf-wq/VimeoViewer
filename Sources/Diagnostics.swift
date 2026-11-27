import AppKit
import WebKit

/// Záznam chýb (JavaScript, sieť, Vimeo API, prihlásenie) – zobrazí sa v menu Pomoc → Diagnostika.
final class Diagnostics: NSObject, WKScriptMessageHandler {
    static let shared = Diagnostics()
    private(set) var lines: [String] = []
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func log(_ source: String, _ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(source): \(message)"
        if lines.last == line { return }
        lines.append(line)
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        NotificationCenter.default.post(name: .diagnosticsChanged, object: nil)
    }

    func clear() {
        lines = []
        NotificationCenter.default.post(name: .diagnosticsChanged, object: nil)
    }

    var report: String {
        let info = Bundle.main.infoDictionary
        let app = "\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))"
        let webkit = Bundle(identifier: "com.apple.WebKit")?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var head = "Vimeo Viewer \(app) · macOS \(os) · Safari \(WebKitFactory.safariVersion) · WebKit \(webkit)\n"
        head += "Jazyky: \(Locale.preferredLanguages.prefix(3).joined(separator: ", ")) · Lokalizácia aplikácie: \(Bundle.main.preferredLocalizations.joined(separator: ", "))\n"
        head += "API token: \(VimeoAPI.shared.token == nil ? "nie" : "áno")\n\n"
        return head + (lines.isEmpty ? "(zatiaľ žiadne záznamy)" : lines.joined(separator: "\n"))
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        if let s = message.body as? String { log("web", s) }
    }

    /// Skript pre všetky stránky Vimea: zachytí chyby JavaScriptu a neúspešné požiadavky.
    static let script = """
    (function(){
      if (!/(^|\\.)vimeo\\.com$/.test(location.hostname)) return;
      function post(m){ try { window.webkit.messageHandlers.vvdiag.postMessage(String(m).slice(0, 600)); } catch(e){} }
      var where = location.host + location.pathname;
      window.addEventListener('error', function(e){
        post('JS chyba: ' + e.message + ' (' + (e.filename || '') + ':' + (e.lineno || '') + ') – ' + where);
      });
      window.addEventListener('unhandledrejection', function(e){
        var r = e.reason; post('Promise chyba: ' + ((r && (r.message || r)) || '?') + ' – ' + where);
      });
      var ce = console.error;
      console.error = function(){
        try {
          post('console.error: ' + Array.prototype.map.call(arguments, function(a){
            try { return (a && a.message) || (typeof a === 'string' ? a : JSON.stringify(a)); } catch(x) { return String(a); }
          }).join(' ') + ' – ' + where);
        } catch(x) {}
        return ce.apply(console, arguments);
      };
      var of = window.fetch;
      if (of) {
        window.fetch = function(input, init){
          var u = String((input && input.url) || input);
          var p = of.apply(this, arguments);
          p.then(function(r){ if (r.status >= 400) post('HTTP ' + r.status + ' ' + u.slice(0, 200) + ' – ' + where); },
                 function(err){ post('Sieťová chyba ' + u.slice(0, 200) + ': ' + (err && err.message) + ' – ' + where); });
          return p;
        };
      }
    })();
    """
}

extension Notification.Name {
    static let diagnosticsChanged = Notification.Name("VimeoViewerDiagnosticsChanged")
}

final class DiagnosticsWindowController: NSWindowController {
    private var textView: NSTextView!

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.title = "Diagnostika"
        super.init(window: win)

        let info = UI.wrappingLabel("Ak niečo nefunguje (prihlásenie, komentáre, prepis), zopakujte to a potom kliknite „Kopírovať všetko“ a text pošlite. Heslá sa nezaznamenávajú.", size: 12)
        let copy = UI.button("Kopírovať všetko", symbol: "doc.on.doc", target: self, action: #selector(copyAll))
        let clear = UI.button("Vymazať", symbol: "trash", target: self, action: #selector(clearAll))
        let row = NSStackView(views: [copy, clear, NSView()])
        row.orientation = .horizontal
        let (sv, tv) = UI.scrollingTextView()
        textView = tv
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        sv.borderType = .bezelBorder
        let stack = UI.vstack([info, row, sv], spacing: 8, insets: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
        let root = NSView()
        root.addSubview(stack)
        UI.pin(stack, to: root)
        win.contentView = root
        win.center()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .diagnosticsChanged, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc func refresh() {
        textView.string = Diagnostics.shared.report
        textView.scrollToEndOfDocument(nil)
    }

    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Diagnostics.shared.report, forType: .string)
    }

    @objc private func clearAll() { Diagnostics.shared.clear() }
}
