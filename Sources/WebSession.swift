import AppKit
import WebKit

/// Skrytá stránka s pôvodom vimeo.com – volá Vimeo API s webovou reláciou (JWT) prihláseného používateľa.
/// Funguje nezávisle od prehrávača (napr. pre Knižnicu).
final class WebSession: NSObject, WebAPIBridge, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = WebSession()

    private var webView: WKWebView!
    private var ready = false
    private var queue: [() -> Void] = []
    private var pending: [String: (Int, Data?, String?) -> Void] = [:]

    override init() {
        super.init()
        let cfg = WebKitFactory.configuration()
        cfg.userContentController.add(WeakScriptHandler(self), name: "session")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), configuration: cfg)
        webView.navigationDelegate = self
        webView.loadHTMLString(WebSession.html, baseURL: URL(string: "https://vimeo.com/"))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        let q = queue
        queue = []
        q.forEach { $0() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        webView.loadHTMLString(WebSession.html, baseURL: URL(string: "https://vimeo.com/"))
    }

    private func run(_ script: String) {
        let work = { [weak self] () -> Void in self?.webView.evaluateJavaScript(script, completionHandler: nil) }
        if ready { work() } else { queue.append(work) }
    }

    /// Po prihlásení/odhlásení treba získať nový kľúč relácie.
    func resetSession() { run("window.vvResetJwt && window.vvResetJwt()") }

    func webAPIRequest(method: String, path: String, body: [String: Any]?,
                       completion: @escaping (Int, Data?, String?) -> Void) {
        let id = UUID().uuidString
        pending[id] = completion
        var bodyJS = "null"
        if let b = body, let d = try? JSONSerialization.data(withJSONObject: b), let s = String(data: d, encoding: .utf8) { bodyJS = s }
        run("window.vvApi(\(PlayerViewController.jsString(id)), \(PlayerViewController.jsString(method)), \(PlayerViewController.jsString(path)), \(bodyJS))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.pending.removeValue(forKey: id)?(0, nil, "Vimeo neodpovedalo včas.")
        }
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let id = body["reqId"] as? String,
              let cb = pending.removeValue(forKey: id) else { return }
        let status = (body["status"] as? NSNumber)?.intValue ?? 0
        let text = body["body"] as? String ?? ""
        cb(status, text.data(using: .utf8), body["error"] as? String)
    }

    static let html = """
    <!doctype html><html><head><meta charset="utf-8"></head><body>
    <script>
    (function(){
      function post(m){ try { window.webkit.messageHandlers.session.postMessage(m); } catch(e){} }
      var jwt = null, jwtTime = 0;
      function getJSON(path){
        return fetch(path, { credentials: 'include', headers: { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest' } })
          .then(function(r){ if (!r.ok) throw new Error(path + ' HTTP ' + r.status); return r.json(); });
      }
      function getJwt(){
        if (jwt && Date.now() - jwtTime < 240000) return Promise.resolve(jwt);
        return getJSON('/_next/viewer').catch(function(){ return getJSON('/_rv/viewer'); }).then(function(v){
          if (!v || !v.jwt) throw new Error('Vimeo nevrátilo prístupový kľúč');
          jwt = v.jwt; jwtTime = Date.now(); return jwt;
        });
      }
      window.vvResetJwt = function(){ jwt = null; };
      window.vvApi = function(reqId, method, path, body){
        getJwt().then(function(token){
          var opt = { method: method, headers: { 'Authorization': 'jwt ' + token, 'Accept': 'application/vnd.vimeo.*+json;version=3.4' } };
          if (body) { opt.headers['Content-Type'] = 'application/json'; opt.body = JSON.stringify(body); }
          return fetch('https://api.vimeo.com' + path, opt).then(function(r){
            if (r.status === 401) jwt = null;
            return r.text().then(function(t){ post({ reqId: reqId, status: r.status, body: t }); });
          });
        }).catch(function(e){ post({ reqId: reqId, status: 0, body: '', error: String((e && e.message) || e) }); });
      };
    })();
    </script></body></html>
    """
}
