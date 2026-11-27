import AppKit
import WebKit

enum UI {
    static func label(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }

    static func wrappingLabel(_ s: String, size: CGFloat = 12, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: size)
        l.textColor = color
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }

    static func button(_ title: String, symbol: String? = nil, target: AnyObject?, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        if let s = symbol, let img = NSImage(systemSymbolName: s, accessibilityDescription: title) {
            b.image = img
            b.imagePosition = .imageLeading
        }
        return b
    }

    static func iconButton(symbol: String, tooltip: String, target: AnyObject?, action: Selector) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage()
        let b = NSButton(image: img, target: target, action: action)
        b.isBordered = false
        b.toolTip = tooltip
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    static func header(_ title: String, symbol: String, accessories: [NSView], titleLabel: NSTextField? = nil) -> NSStackView {
        var views: [NSView] = []
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let iv = NSImageView(image: img)
            iv.contentTintColor = .secondaryLabelColor
            iv.setContentHuggingPriority(.required, for: .horizontal)
            views.append(iv)
        }
        let t = titleLabel ?? label(title, size: 13, weight: .semibold)
        t.stringValue = title
        t.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        views.append(t)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        views.append(spacer)
        views.append(contentsOf: accessories)
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 6
        s.alignment = .centerY
        return s
    }

    static func scrollingTextView() -> (NSScrollView, NSTextView) {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.textContainerInset = NSSize(width: 6, height: 10)
        tv.font = .systemFont(ofSize: 13)
        tv.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        tv.isAutomaticLinkDetectionEnabled = false
        sv.borderType = .noBorder
        sv.hasVerticalScroller = true
        sv.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        sv.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)
        return (sv, tv)
    }

    static func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    /// Vertikálny stack, ktorého položky sa roztiahnu na celú šírku.
    static func vstack(_ views: [NSView], spacing: CGFloat = 8,
                       insets: NSEdgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)) -> NSStackView {
        let s = NSStackView()
        s.orientation = .vertical
        s.alignment = .leading
        s.distribution = .fill
        s.spacing = spacing
        s.edgeInsets = insets
        s.translatesAutoresizingMaskIntoConstraints = false
        for v in views {
            s.addArrangedSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
            v.leadingAnchor.constraint(equalTo: s.leadingAnchor, constant: insets.left).isActive = true
            v.trailingAnchor.constraint(equalTo: s.trailingAnchor, constant: -insets.right).isActive = true
        }
        return s
    }

    static func pin(_ v: NSView, to container: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// Nájde časové značky typu 1:23 alebo 1:02:03 v texte.
    static let timestampRegex = try! NSRegularExpression(pattern: "\\b(?:\\d{1,2}:)?\\d{1,2}:\\d{2}\\b")
}

enum WebKitFactory {
    static let processPool = WKProcessPool()

    /// Verzia Safari nainštalovaného na Macu – web sa potom správa ako v Safari.
    static let safariVersion: String = {
        for path in ["/Applications/Safari.app", "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"] {
            if let v = Bundle(path: path)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { return v }
        }
        return "14.1.2"
    }()

    static func configuration() -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.processPool = processPool
        c.websiteDataStore = .default()
        c.mediaTypesRequiringUserActionForPlayback = []
        c.applicationNameForUserAgent = "Version/\(safariVersion) Safari/605.1.15"
        c.allowsAirPlayForMediaPlayback = true
        c.preferences.javaScriptCanOpenWindowsAutomatically = true
        // Povolí celoobrazovkový režim prehrávača (súkromné, ale bežne používané nastavenie WebKitu).
        if c.preferences.responds(to: Selector(("_setFullScreenEnabled:"))) {
            c.preferences.setValue(true, forKey: "fullScreenEnabled")
        }
        return c
    }
}

/// Zabraňuje cyklu silných referencií medzi WKUserContentController a kontrolérom.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}

/// Okno pre vyskakovacie okná (napr. prihlásenie cez Google/Apple).
final class PopupWindowController: NSWindowController, WKUIDelegate, NSWindowDelegate {
    let webView: WKWebView
    var onClose: ((PopupWindowController) -> Void)?
    private var titleObservation: NSKeyValueObservation?

    init(configuration: WKWebViewConfiguration, features: WKWindowFeatures) {
        let wv = WKWebView(frame: .zero, configuration: configuration)
        webView = wv
        let w = CGFloat(features.width?.doubleValue ?? 560)
        let h = CGFloat(features.height?.doubleValue ?? 680)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = wv
        win.center()
        super.init(window: win)
        win.delegate = self
        webView.uiDelegate = self
        titleObservation = webView.observe(\.title, options: [.new]) { [weak win] wv, _ in
            win?.title = wv.title ?? ""
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func webViewDidClose(_ webView: WKWebView) { window?.close() }

    func windowWillClose(_ notification: Notification) {
        titleObservation = nil
        onClose?(self)
    }
}
