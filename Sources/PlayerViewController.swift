import AppKit
import WebKit

protocol PlayerDelegate: AnyObject {
    func player(_ player: PlayerViewController, didUpdateTime time: Double, duration: Double)
    func player(_ player: PlayerViewController, requestsOpen url: URL)
}

/// Stredný panel – samotné video (oficiálny Vimeo prehrávač + Player.js API).
final class PlayerViewController: NSViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    weak var delegate: PlayerDelegate?

    private(set) var webView: WKWebView!
    private let titleLabel = UI.label("", size: 15, weight: .semibold)
    private let authorButton = NSButton(title: "", target: nil, action: nil)
    private let timeLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    private let placeholder = UI.wrappingLabel(
        "Otvorte Vimeo video: kliknite na odkaz v prezentácii či PDF, vložte odkaz do adresného riadku hore, alebo si video nájdite v režime „Prehliadať“.",
        size: 14, color: .secondaryLabelColor)
    private let errorLabel = UI.wrappingLabel("", size: 12, color: .systemRed)

    private(set) var currentRef: VimeoVideoRef?
    private(set) var info: VideoInfo?
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private var allowNextMainFrameLoad = false

    override func loadView() {
        let root = NSView()

        let config = WebKitFactory.configuration()
        config.userContentController.add(WeakScriptHandler(self), name: "vimeo")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")

        authorButton.isBordered = false
        authorButton.contentTintColor = .secondaryLabelColor
        authorButton.font = .systemFont(ofSize: 12)
        authorButton.target = self
        authorButton.action = #selector(openAuthor)
        authorButton.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.alignment = .right
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        let headerRow = NSStackView(views: [titleLabel, NSView(), timeLabel])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let header = UI.vstack([headerRow, authorButton], spacing: 0,
                               insets: NSEdgeInsets(top: 8, left: 12, bottom: 6, right: 12))
        authorButton.alignment = .left

        let videoBox = NSView()
        videoBox.wantsLayer = true
        videoBox.layer?.backgroundColor = NSColor.black.cgColor
        videoBox.addSubview(webView)
        UI.pin(webView, to: videoBox)

        placeholder.alignment = .center
        placeholder.textColor = NSColor(white: 0.75, alpha: 1)
        videoBox.addSubview(placeholder)
        errorLabel.alignment = .center
        errorLabel.isHidden = true
        videoBox.addSubview(errorLabel)
        for l in [placeholder, errorLabel] {
            l.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                l.centerXAnchor.constraint(equalTo: videoBox.centerXAnchor),
                l.widthAnchor.constraint(lessThanOrEqualTo: videoBox.widthAnchor, multiplier: 0.8),
            ])
        }
        placeholder.centerYAnchor.constraint(equalTo: videoBox.centerYAnchor).isActive = true
        errorLabel.bottomAnchor.constraint(equalTo: videoBox.bottomAnchor, constant: -16).isActive = true

        root.addSubview(header)
        root.addSubview(videoBox)
        videoBox.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            videoBox.topAnchor.constraint(equalTo: header.bottomAnchor),
            videoBox.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            videoBox.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            videoBox.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
        ])
        titleLabel.stringValue = "Žiadne video"
        authorButton.title = ""
        view = root
    }

    // MARK: Načítanie

    func load(_ ref: VimeoVideoRef) {
        _ = view
        currentRef = ref
        info = nil
        currentTime = ref.startTime ?? 0
        duration = 0
        placeholder.isHidden = true
        errorLabel.isHidden = true
        titleLabel.stringValue = "Načítavam…"
        authorButton.title = ""
        timeLabel.stringValue = ""
        allowNextMainFrameLoad = true
        webView.loadHTMLString(PlayerViewController.html(for: ref), baseURL: URL(string: "https://vimeo.com/"))
    }

    func setInfo(_ i: VideoInfo) {
        info = i
        titleLabel.stringValue = i.title
        titleLabel.toolTip = i.description.isEmpty ? i.title : i.description
        authorButton.title = i.author.isEmpty ? "" : i.author
    }

    @objc private func openAuthor() {
        if let u = info?.authorURL { delegate?.player(self, requestsOpen: u) }
    }

    // MARK: Ovládanie

    private func js(_ script: String) {
        guard isViewLoaded, currentRef != nil, let wv = webView else { return }
        wv.evaluateJavaScript(script, completionHandler: nil)
    }

    func seek(to seconds: Double) { js("window.vvSeek && window.vvSeek(\(max(0, seconds)))") }
    func togglePlay() { js("window.vvToggle && window.vvToggle()") }
    func pause() { js("window.vvPause && window.vvPause()") }
    func skip(_ delta: Double) { js("window.vvSkip && window.vvSkip(\(delta))") }
    func setRate(_ rate: Double) { js("window.vvRate && window.vvRate(\(rate))") }

    // MARK: Správy z JavaScriptu

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "time":
            currentTime = (body["seconds"] as? NSNumber)?.doubleValue ?? 0
            duration = (body["duration"] as? NSNumber)?.doubleValue ?? duration
            timeLabel.stringValue = "\(VimeoLinks.formatTime(currentTime)) / \(VimeoLinks.formatTime(duration))"
            delegate?.player(self, didUpdateTime: currentTime, duration: duration)
        case "ready":
            errorLabel.isHidden = true
        case "error":
            let msg = body["message"] as? String ?? "Chyba prehrávača"
            errorLabel.stringValue = "⚠︎ \(msg) – video môže byť súkromné alebo jeho vkladanie zakázané. Skúste ho otvoriť v režime Prehliadať."
            errorLabel.isHidden = false
        default:
            break
        }
    }

    // MARK: Navigácia – všetko mimo prehrávača sa smeruje cez router aplikácie

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let isMain = navigationAction.targetFrame?.isMainFrame ?? true
        if isMain {
            if allowNextMainFrameLoad {
                allowNextMainFrameLoad = false
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if let u = navigationAction.request.url, u.scheme?.hasPrefix("http") == true {
                delegate?.player(self, requestsOpen: u)
            }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = navigationAction.request.url, u.scheme?.hasPrefix("http") == true {
            delegate?.player(self, requestsOpen: u)
        }
        return nil
    }

    // MARK: HTML s prehrávačom

    static func html(for ref: VimeoVideoRef) -> String {
        var src = "https://player.vimeo.com/video/\(ref.id)?autoplay=1&title=0&byline=0&portrait=0&pip=1"
        if let h = ref.hash { src += "&h=\(h)" }
        if let t = ref.startTime, t >= 1 { src += "#t=\(Int(t))s" }
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style>
          html,body{margin:0;padding:0;height:100%;background:#000;overflow:hidden}
          iframe{position:absolute;top:0;left:0;width:100%;height:100%;border:0}
        </style>
        <script src="https://player.vimeo.com/api/player.js"></script>
        </head><body>
        <iframe id="player" src="\(src)" allow="autoplay; fullscreen; picture-in-picture; clipboard-write" allowfullscreen></iframe>
        <script>
        (function(){
          function post(m){ try { window.webkit.messageHandlers.vimeo.postMessage(m); } catch(e){} }
          if (typeof Vimeo === 'undefined') { post({type:'error', message:'Nepodarilo sa načítať Vimeo Player API'}); return; }
          var player = new Vimeo.Player(document.getElementById('player'));
          player.on('timeupdate', function(d){ post({type:'time', seconds:d.seconds, duration:d.duration}); });
          player.on('error', function(e){ post({type:'error', message:(e && (e.message || e.name)) || 'Chyba prehrávača'}); });
          player.ready().then(function(){ post({type:'ready'}); })
                        .catch(function(e){ post({type:'error', message:String((e && e.message) || e)}); });
          window.vvSeek = function(s){ player.setCurrentTime(s).then(function(){ return player.play(); }).catch(function(){}); };
          window.vvToggle = function(){ player.getPaused().then(function(p){ return p ? player.play() : player.pause(); }).catch(function(){}); };
          window.vvPause = function(){ player.pause().catch(function(){}); };
          window.vvSkip = function(d){ player.getCurrentTime().then(function(t){ return player.setCurrentTime(Math.max(0, t + d)); }).catch(function(){}); };
          window.vvRate = function(r){ player.setPlaybackRate(r).catch(function(){ post({type:'error', message:'Rýchlosť prehrávania pre toto video nie je dostupná'}); }); };
        })();
        </script>
        </body></html>
        """
    }
}
