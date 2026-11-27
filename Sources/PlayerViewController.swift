import AppKit
import WebKit

protocol PlayerDelegate: AnyObject {
    func player(_ player: PlayerViewController, didUpdateTime time: Double, duration: Double)
    func player(_ player: PlayerViewController, requestsOpen url: URL)
}

/// Hlavná časť okna – samotné video (oficiálny Vimeo prehrávač + Player.js API).
/// Titulky pre prepis sa načítavajú priamo vnútri prehrávača (rovnaké prihlásenie a prístup ako video).
final class PlayerViewController: NSViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, WebAPIBridge {
    weak var delegate: PlayerDelegate?
    /// Zoznam titulkov z prehrávača (alebo chyba).
    var onTracks: (([TextTrack]?, String?) -> Void)?
    /// Obsah VTT súboru (url, text, chyba).
    var onVTT: ((String, String?, String?) -> Void)?
    /// Zoznam titulkov z Player API (bez adries) alebo chyba.
    var onPlayerTrackList: (([TextTrack], String?) -> Void)?
    /// Zachytený celý prepis (úseky) z prehrávača.
    var onCaptured: (([Cue]) -> Void)?
    var onCaptureError: ((String) -> Void)?
    private var capturing = false

    private(set) var webView: WKWebView!
    private let placeholder = UI.wrappingLabel(
        "Otvorte Vimeo video: kliknite na odkaz v prezentácii či PDF, vložte odkaz do adresného riadku hore, alebo si video nájdite v režime „Prehliadať“.",
        size: 14, color: .secondaryLabelColor)
    private let errorLabel = UI.wrappingLabel("", size: 12, color: .systemRed)

    private(set) var currentRef: VimeoVideoRef?
    private(set) var info: VideoInfo?
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private var allowNextMainFrameLoad = false
    private var playerFrame: WKFrameInfo?
    private var pendingAPI: [String: (Int, Data?, String?) -> Void] = [:]

    // MARK: WebAPIBridge – Vimeo API cez reláciu vimeo.com (JWT), bez osobného tokenu

    func webAPIRequest(method: String, path: String, body: [String: Any]?,
                       completion: @escaping (Int, Data?, String?) -> Void) {
        let id = UUID().uuidString
        pendingAPI[id] = completion
        var bodyJS = "null"
        if let b = body, let d = try? JSONSerialization.data(withJSONObject: b), let s = String(data: d, encoding: .utf8) { bodyJS = s }
        let script = "typeof window.vvApi === 'function' ? (window.vvApi(\(PlayerViewController.jsString(id)), \(PlayerViewController.jsString(method)), \(PlayerViewController.jsString(path)), \(bodyJS)), 1) : 0"
        attemptAPI(script, id: id, triesLeft: 40)
    }

    private func attemptAPI(_ script: String, id: String, triesLeft: Int) {
        guard isViewLoaded, currentRef != nil, let wv = webView else {
            pendingAPI.removeValue(forKey: id)?(0, nil, "Najprv otvorte video.")
            return
        }
        wv.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self = self else { return }
            if (result as? NSNumber)?.intValue == 1 { return }
            if triesLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.attemptAPI(script, id: id, triesLeft: triesLeft - 1)
                }
            } else {
                self.pendingAPI.removeValue(forKey: id)?(0, nil, "Prehrávač sa nenačítal.")
            }
        }
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor

        let config = WebKitFactory.configuration()
        config.userContentController.add(WeakScriptHandler(self), name: "vimeo")
        config.userContentController.addUserScript(
            WKUserScript(source: PlayerViewController.captureScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.addUserScript(
            WKUserScript(source: PlayerViewController.frameScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        root.addSubview(webView)
        UI.pin(webView, to: root)

        placeholder.alignment = .center
        placeholder.textColor = NSColor(white: 0.75, alpha: 1)
        root.addSubview(placeholder)
        errorLabel.alignment = .center
        errorLabel.isHidden = true
        errorLabel.drawsBackground = true
        errorLabel.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        root.addSubview(errorLabel)
        for l in [placeholder, errorLabel] {
            l.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                l.centerXAnchor.constraint(equalTo: root.centerXAnchor),
                l.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, multiplier: 0.8),
            ])
        }
        placeholder.centerYAnchor.constraint(equalTo: root.centerYAnchor).isActive = true
        errorLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16).isActive = true
        root.widthAnchor.constraint(greaterThanOrEqualToConstant: 480).isActive = true
        view = root
    }

    // MARK: Načítanie

    func load(_ ref: VimeoVideoRef) {
        _ = view
        currentRef = ref
        info = nil
        playerFrame = nil
        capturing = false
        for (_, cb) in pendingAPI { cb(0, nil, "Video bolo zmenené.") }
        pendingAPI = [:]
        currentTime = ref.startTime ?? 0
        duration = 0
        placeholder.isHidden = true
        errorLabel.isHidden = true
        allowNextMainFrameLoad = true
        webView.loadHTMLString(PlayerViewController.html(for: ref), baseURL: URL(string: "https://vimeo.com/"))
    }

    func setInfo(_ i: VideoInfo) { info = i }

    /// Stiahne VTT súbor z vnútra prehrávača (s jeho prihlásením a oprávneniami).
    func loadTrack(url: URL) {
        guard let frame = playerFrame, let wv = webView else {
            onVTT?(url.absoluteString, nil, "Prehrávač ešte nie je pripravený")
            return
        }
        let arg = PlayerViewController.jsString(url.absoluteString)
        wv.evaluateJavaScript("window.vvLoadTrack && window.vvLoadTrack(\(arg))", in: frame, in: .page) { [weak self] result in
            if case .failure(let e) = result {
                self?.onVTT?(url.absoluteString, nil, e.localizedDescription)
            }
        }
    }

    // MARK: Zachytenie titulkov cez samotný prehrávač

    func listPlayerTracks() { jsWhenReady("vvListTracks", "window.vvListTracks()", triesLeft: 40) }

    /// Spustí JS, až keď je daná funkcia v stránke dostupná.
    private func jsWhenReady(_ fn: String, _ call: String, triesLeft: Int) {
        guard isViewLoaded, currentRef != nil, let wv = webView else { return }
        wv.evaluateJavaScript("typeof window.\(fn) === 'function' ? (\(call), 1) : 0") { [weak self] result, _ in
            if (result as? NSNumber)?.intValue == 1 || triesLeft <= 0 { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.jsWhenReady(fn, call, triesLeft: triesLeft - 1)
            }
        }
    }

    /// Zapne titulky v prehrávači, zachytí súbor, ktorý si prehrávač stiahne, a potom ich vráti späť.
    func captureTrack(lang: String, kind: String) {
        capturing = true
        js("window.vvEnableTrack && window.vvEnableTrack(\(PlayerViewController.jsString(lang)), \(PlayerViewController.jsString(kind)))")
        pollCues(triesLeft: 25)
    }

    private func pollCues(triesLeft: Int) {
        guard capturing else { return }
        if triesLeft <= 0 {
            capturing = false
            js("window.vvRestoreTrack && window.vvRestoreTrack()")
            onCaptureError?("Prehrávač titulky neposkytol.")
            return
        }
        if let frame = playerFrame, let wv = webView {
            wv.evaluateJavaScript("window.vvReadCues && window.vvReadCues()", in: frame, in: .page) { _ in }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.pollCues(triesLeft: triesLeft - 1)
        }
    }

    private func captured(_ cues: [Cue]) {
        guard !cues.isEmpty else { return }
        let wasCapturing = capturing
        capturing = false
        if wasCapturing { js("window.vvRestoreTrack && window.vvRestoreTrack()") }
        onCaptured?(cues)
    }

    static func jsString(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]),
              let json = String(data: d, encoding: .utf8) else { return "''" }
        return String(json.dropFirst().dropLast())
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
        // Správy z rámca prehrávača musia patriť aktuálnemu videu.
        if let vid = body["videoId"] as? String, vid != currentRef?.id { return }
        switch type {
        case "time":
            currentTime = (body["seconds"] as? NSNumber)?.doubleValue ?? 0
            duration = (body["duration"] as? NSNumber)?.doubleValue ?? duration
            delegate?.player(self, didUpdateTime: currentTime, duration: duration)
        case "ready":
            errorLabel.isHidden = true
        case "error":
            let msg = body["message"] as? String ?? "Chyba prehrávača"
            errorLabel.stringValue = "⚠︎ \(msg)"
            errorLabel.isHidden = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.errorLabel.isHidden = true }
        case "tracks":
            playerFrame = message.frameInfo
            let arr = body["tracks"] as? [[String: Any]] ?? []
            let tracks: [TextTrack] = arr.compactMap { (t: [String: Any]) -> TextTrack? in
                guard let s = t["url"] as? String, let u = URL(string: s) else { return nil }
                let lang = t["lang"] as? String ?? ""
                let label = t["label"] as? String ?? lang
                return TextTrack(label: label.isEmpty ? lang : label, lang: lang, url: u, viaPlayer: true)
            }
            onTracks?(tracks, nil)
        case "api":
            guard let id = body["reqId"] as? String, let cb = pendingAPI.removeValue(forKey: id) else { return }
            let status = (body["status"] as? NSNumber)?.intValue ?? 0
            let text = body["body"] as? String ?? ""
            cb(status, text.data(using: .utf8), body["error"] as? String)
        case "frameHello":
            if playerFrame == nil { playerFrame = message.frameInfo }
        case "ptracks":
            let arr = body["tracks"] as? [[String: Any]] ?? []
            let placeholder = URL(string: "https://player.vimeo.com/")!
            let list: [TextTrack] = arr.compactMap { (t: [String: Any]) -> TextTrack? in
                guard let lang = t["language"] as? String, !lang.isEmpty else { return nil }
                let kind = t["kind"] as? String ?? "captions"
                let label = (t["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? lang
                return TextTrack(label: label, lang: lang, url: placeholder, viaPlayer: true, captureLang: lang, captureKind: kind)
            }
            onPlayerTrackList?(list, body["error"] as? String)
        case "trackEnableError":
            capturing = false
            onCaptureError?(body["message"] as? String ?? "Titulky sa nepodarilo zapnúť")
        case "vttCaptured":
            if playerFrame == nil { playerFrame = message.frameInfo }
            captured(VTT.parse(body["text"] as? String ?? ""))
        case "cuesCaptured":
            let arr = body["cues"] as? [[String: Any]] ?? []
            var cues: [Cue] = []
            for c in arr {
                let text = VTT.clean((c["t"] as? String ?? "").replacingOccurrences(of: "\n", with: " "))
                guard !text.isEmpty else { continue }
                let st = (c["s"] as? NSNumber)?.doubleValue ?? 0
                let en = (c["e"] as? NSNumber)?.doubleValue ?? st
                if let last = cues.last, last.text == text { cues[cues.count - 1] = Cue(start: last.start, end: en, text: text); continue }
                cues.append(Cue(start: st, end: en, text: text))
            }
            captured(cues)
        case "tracksError":
            playerFrame = message.frameInfo
            onTracks?(nil, body["message"] as? String ?? "Neznáma chyba")
        case "vtt":
            onVTT?(body["url"] as? String ?? "", body["text"] as? String ?? "", nil)
        case "vttError":
            onVTT?(body["url"] as? String ?? "", nil, body["message"] as? String ?? "Neznáma chyba")
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

    // MARK: Skript vložený do rámca player.vimeo.com (na začiatku – zachytáva stiahnuté titulky)

    static let captureScript = """
    (function(){
      if (location.hostname !== 'player.vimeo.com') return;
      var m = location.pathname.match(/\\/video\\/(\\d+)/);
      var videoId = m ? m[1] : null;
      function post(msg){ msg.videoId = videoId; try { window.webkit.messageHandlers.vimeo.postMessage(msg); } catch(e){} }
      function isTrack(u){ return /texttrack|\\.vtt|caption|subtitle/i.test(String(u || '')); }
      function looksVTT(t){ return typeof t === 'string' && t.indexOf('-->') !== -1; }
      var origFetch = window.fetch;
      if (origFetch) {
        window.fetch = function(input, init){
          var url = (input && input.url) || input;
          var p = origFetch.apply(this, arguments);
          if (isTrack(url)) {
            p.then(function(r){ return r.clone().text(); })
             .then(function(t){ if (looksVTT(t)) post({ type: 'vttCaptured', url: String(url), text: t }); })
             .catch(function(){});
          }
          return p;
        };
      }
      var origOpen = XMLHttpRequest.prototype.open, origSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method, url){ this.__vvUrl = url; return origOpen.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function(){
        var x = this;
        if (isTrack(x.__vvUrl)) {
          x.addEventListener('load', function(){
            try {
              var t = (x.responseType === '' || x.responseType === 'text') ? x.responseText : null;
              if (looksVTT(t)) post({ type: 'vttCaptured', url: String(x.__vvUrl), text: t });
            } catch(e) {}
          });
        }
        return origSend.apply(this, arguments);
      };
      window.vvReadCues = function(){
        var vids = document.querySelectorAll('video');
        for (var i = 0; i < vids.length; i++) {
          var tts = vids[i].textTracks || [];
          for (var j = 0; j < tts.length; j++) {
            var tt = tts[j];
            if (tt.mode !== 'disabled' && tt.cues && tt.cues.length) {
              var out = [];
              for (var k = 0; k < tt.cues.length; k++) { var c = tt.cues[k]; out.push({ s: c.startTime, e: c.endTime, t: c.text || '' }); }
              post({ type: 'cuesCaptured', cues: out });
              return true;
            }
          }
        }
        return false;
      };
      document.addEventListener('DOMContentLoaded', function(){ post({ type: 'frameHello' }); });
    })();
    """

    // MARK: Skript vložený do rámca player.vimeo.com

    static let frameScript = """
    (function(){
      if (location.hostname !== 'player.vimeo.com') return;
      var m = location.pathname.match(/\\/video\\/(\\d+)/);
      var videoId = m ? m[1] : null;
      function post(msg){ msg.videoId = videoId; try { window.webkit.messageHandlers.vimeo.postMessage(msg); } catch(e){} }
      function tracksFrom(cfg){
        var tt = (cfg && cfg.request && cfg.request.text_tracks) || [];
        return tt.map(function(t){
          return { label: t.label || t.lang || '', lang: t.lang || '', url: new URL(t.url, location.origin).href };
        });
      }
      function getConfig(){
        if (window.playerConfig && window.playerConfig.request) return Promise.resolve(window.playerConfig);
        if (!videoId) return Promise.reject(new Error('Neznáme ID videa'));
        return fetch('/video/' + videoId + '/config' + location.search, { credentials: 'include' })
          .then(function(r){ if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); });
      }
      window.vvLoadTrack = function(url){
        fetch(url, { credentials: 'include' })
          .then(function(r){ if (!r.ok) throw new Error('HTTP ' + r.status); return r.text(); })
          .then(function(text){ post({ type: 'vtt', url: url, text: text }); })
          .catch(function(e){ post({ type: 'vttError', url: url, message: String((e && e.message) || e) }); });
      };
      function run(){
        getConfig()
          .then(function(cfg){ post({ type: 'tracks', tracks: tracksFrom(cfg) }); })
          .catch(function(e){ post({ type: 'tracksError', message: String((e && e.message) || e) }); });
      }
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run); else run();
    })();
    """

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
        <script>
        (function(){
          function post(m){ try { window.webkit.messageHandlers.vimeo.postMessage(m); } catch(e){} }
          var jwt = null, jwtTime = 0;
          function getJwt(){
            if (jwt && Date.now() - jwtTime < 240000) return Promise.resolve(jwt);
            return fetch('/_next/viewer', { credentials: 'include', headers: { 'Accept': 'application/json' } })
              .then(function(r){ if (!r.ok) throw new Error('Vimeo relácia: HTTP ' + r.status); return r.json(); })
              .then(function(j){ if (!j || !j.jwt) throw new Error('Vimeo nevrátilo prístupový kľúč'); jwt = j.jwt; jwtTime = Date.now(); return jwt; });
          }
          window.vvApi = function(reqId, method, path, body){
            getJwt().then(function(token){
              var opt = { method: method, headers: { 'Authorization': 'jwt ' + token, 'Accept': 'application/vnd.vimeo.*+json;version=3.4' } };
              if (body) { opt.headers['Content-Type'] = 'application/json'; opt.body = JSON.stringify(body); }
              return fetch('https://api.vimeo.com' + path, opt).then(function(r){
                return r.text().then(function(t){ post({ type: 'api', reqId: reqId, status: r.status, body: t }); });
              });
            }).catch(function(e){ post({ type: 'api', reqId: reqId, status: 0, body: '', error: String((e && e.message) || e) }); });
          };
        })();
        </script>
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
          var prevTrack = null;
          window.vvListTracks = function(){
            player.ready().then(function(){ return player.getTextTracks(); }).then(function(t){ post({type:'ptracks', tracks:t}); })
              .catch(function(e){ post({type:'ptracks', tracks:[], error:String((e && e.message) || e)}); });
          };
          window.vvEnableTrack = function(lang, kind){
            player.getTextTracks().then(function(ts){
              var a = ts.filter(function(t){ return t.mode === 'showing'; })[0];
              prevTrack = a ? { l: a.language, k: a.kind } : null;
              return player.enableTextTrack(lang, kind);
            }).catch(function(e){ post({type:'trackEnableError', message:String((e && e.message) || e)}); });
          };
          window.vvRestoreTrack = function(){
            if (prevTrack) player.enableTextTrack(prevTrack.l, prevTrack.k).catch(function(){});
            else player.disableTextTrack().catch(function(){});
          };
          window.vvRate = function(r){ player.setPlaybackRate(r).catch(function(){ post({type:'error', message:'Rýchlosť prehrávania pre toto video nie je dostupná'}); }); };
        })();
        </script>
        </body></html>
        """
    }
}
