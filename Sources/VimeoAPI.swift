import Foundation
import Security

struct VideoInfo {
    var title: String
    var author: String
    var authorURL: URL?
    var description: String
    var duration: Double
    var thumbnailURL: URL?
}

struct TextTrack {
    let label: String
    let lang: String
    let url: URL
}

struct Cue {
    let start: Double
    let end: Double
    let text: String
}

final class Comment {
    let uri: String
    let text: String
    let author: String
    let authorURL: URL?
    let date: Date?
    var replyCount: Int
    let isReply: Bool
    var replies: [Comment]?

    init(uri: String, text: String, author: String, authorURL: URL?, date: Date?, replyCount: Int, isReply: Bool) {
        self.uri = uri; self.text = text; self.author = author; self.authorURL = authorURL
        self.date = date; self.replyCount = replyCount; self.isReply = isReply
    }
}

struct CommentPage {
    let items: [Comment]
    let next: String?
    let total: Int
}

enum APIError: LocalizedError {
    case noToken
    case http(Int, String)
    case parse

    var errorDescription: String? {
        switch self {
        case .noToken: return "Chýba Vimeo API token (Nastavenia)."
        case .http(let code, let msg): return "HTTP \(code): \(msg)"
        case .parse: return "Neočakávaná odpoveď servera."
        }
    }
}

final class VimeoAPI {
    static let shared = VimeoAPI()
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.1.2 Safari/605.1.15"
    static let commentFields = "uri,text,created_on,user.name,user.link,metadata.connections.replies"

    private let session: URLSession
    private var cachedToken: String??

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg)
    }

    // MARK: Token

    var token: String? {
        get {
            if let c = cachedToken { return c }
            let t = Keychain.read()
            cachedToken = .some(t)
            return t
        }
        set {
            let v = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let clean = (v?.isEmpty ?? true) ? nil : v
            Keychain.save(clean)
            cachedToken = .some(clean)
            NotificationCenter.default.post(name: .vimeoTokenChanged, object: nil)
        }
    }

    // MARK: Základ

    private func fetchData(_ req: URLRequest, completion: @escaping (Result<Data, Error>) -> Void) {
        session.dataTask(with: req) { data, resp, err in
            let done: (Result<Data, Error>) -> Void = { r in DispatchQueue.main.async { completion(r) } }
            if let err = err { done(.failure(err)); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data else { done(.failure(APIError.parse)); return }
            if !(200..<300).contains(code) {
                var msg = HTTPURLResponse.localizedString(forStatusCode: code)
                if let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    if let e = j["developer_message"] as? String { msg = e }
                    else if let e = j["error"] as? String { msg = e }
                }
                done(.failure(APIError.http(code, msg)))
                return
            }
            done(.success(data))
        }.resume()
    }

    private func json(_ req: URLRequest, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        fetchData(req) { r in
            switch r {
            case .success(let d):
                if d.isEmpty { completion(.success([:])); return }
                if let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                    completion(.success(o))
                } else {
                    completion(.failure(APIError.parse))
                }
            case .failure(let e):
                completion(.failure(e))
            }
        }
    }

    private func webRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(VimeoAPI.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://vimeo.com/", forHTTPHeaderField: "Referer")
        return req
    }

    func apiRequest(_ pathOrURL: String, method: String = "GET", body: [String: Any]? = nil,
                    completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let tok = token, !tok.isEmpty else {
            DispatchQueue.main.async { completion(.failure(APIError.noToken)) }
            return
        }
        let urlStr = pathOrURL.hasPrefix("http") ? pathOrURL : "https://api.vimeo.com" + pathOrURL
        guard let url = URL(string: urlStr) else {
            DispatchQueue.main.async { completion(.failure(APIError.parse)) }
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.vimeo.*+json;version=3.4", forHTTPHeaderField: "Accept")
        if let b = body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: b)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        json(req, completion: completion)
    }

    // MARK: Informácie o videu (oEmbed – bez tokenu)

    func videoInfo(_ ref: VimeoVideoRef, completion: @escaping (Result<VideoInfo, Error>) -> Void) {
        var c = URLComponents(string: "https://vimeo.com/api/oembed.json")!
        c.queryItems = [URLQueryItem(name: "url", value: ref.pageURL.absoluteString)]
        json(webRequest(c.url!)) { r in
            completion(r.map { (j: [String: Any]) -> VideoInfo in
                VideoInfo(title: j["title"] as? String ?? "Video \(ref.id)",
                          author: j["author_name"] as? String ?? "",
                          authorURL: (j["author_url"] as? String).flatMap { URL(string: $0) },
                          description: j["description"] as? String ?? "",
                          duration: (j["duration"] as? NSNumber)?.doubleValue ?? 0,
                          thumbnailURL: (j["thumbnail_url"] as? String).flatMap { URL(string: $0) })
            })
        }
    }

    // MARK: Titulky / prepis

    func textTracks(_ ref: VimeoVideoRef, completion: @escaping (Result<[TextTrack], Error>) -> Void) {
        var c = URLComponents(string: "https://player.vimeo.com/video/\(ref.id)/config")!
        if let h = ref.hash { c.queryItems = [URLQueryItem(name: "h", value: h)] }
        json(webRequest(c.url!)) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let j):
                let request = j["request"] as? [String: Any]
                let arr = request?["text_tracks"] as? [[String: Any]] ?? []
                let base = URL(string: "https://player.vimeo.com")!
                let tracks: [TextTrack] = arr.compactMap { (t: [String: Any]) -> TextTrack? in
                    guard let u = t["url"] as? String,
                          let url = URL(string: u, relativeTo: base)?.absoluteURL else { return nil }
                    let lang = t["lang"] as? String ?? ""
                    return TextTrack(label: t["label"] as? String ?? lang, lang: lang, url: url)
                }
                if tracks.isEmpty && self.token != nil {
                    self.apiTextTracks(ref, completion: completion)
                } else {
                    completion(.success(tracks))
                }
            case .failure(let e):
                if self.token != nil { self.apiTextTracks(ref, completion: completion) }
                else { completion(.failure(e)) }
            }
        }
    }

    private func apiTextTracks(_ ref: VimeoVideoRef, completion: @escaping (Result<[TextTrack], Error>) -> Void) {
        apiRequest(ref.apiPath + "/texttracks") { r in
            completion(r.map { (j: [String: Any]) -> [TextTrack] in
                let arr = j["data"] as? [[String: Any]] ?? []
                return arr.compactMap { (t: [String: Any]) -> TextTrack? in
                    guard let link = t["link"] as? String, let url = URL(string: link) else { return nil }
                    let lang = t["language"] as? String ?? ""
                    let name = t["name"] as? String ?? lang
                    return TextTrack(label: name.isEmpty ? lang : name, lang: lang, url: url)
                }
            })
        }
    }

    func cues(for track: TextTrack, completion: @escaping (Result<[Cue], Error>) -> Void) {
        fetchData(webRequest(track.url)) { r in
            completion(r.map { VTT.parse(String(decoding: $0, as: UTF8.self)) })
        }
    }

    // MARK: Komentáre (Vimeo API – vyžaduje token)

    func comments(path: String, completion: @escaping (Result<CommentPage, Error>) -> Void) {
        apiRequest(path) { r in
            completion(r.map { (j: [String: Any]) -> CommentPage in
                let data = j["data"] as? [[String: Any]] ?? []
                let isReply = path.contains("/replies")
                let items = data.compactMap { VimeoAPI.parseComment($0, isReply: isReply) }
                let paging = j["paging"] as? [String: Any]
                let next = paging?["next"] as? String
                let total = (j["total"] as? NSNumber)?.intValue ?? items.count
                return CommentPage(items: items, next: next, total: total)
            })
        }
    }

    func commentsPath(for ref: VimeoVideoRef) -> String {
        return "\(ref.apiPath)/comments?per_page=30&fields=\(VimeoAPI.commentFields)"
    }

    func repliesPath(for comment: Comment) -> String {
        return "\(comment.uri)/replies?per_page=100&fields=\(VimeoAPI.commentFields)"
    }

    func postComment(path: String, text: String, isReply: Bool, completion: @escaping (Result<Comment, Error>) -> Void) {
        apiRequest(path, method: "POST", body: ["text": text]) { r in
            switch r {
            case .success(let j):
                if let c = VimeoAPI.parseComment(j, isReply: isReply) { completion(.success(c)) }
                else { completion(.failure(APIError.parse)) }
            case .failure(let e):
                completion(.failure(e))
            }
        }
    }

    static func parseComment(_ j: [String: Any], isReply: Bool) -> Comment? {
        guard let uri = j["uri"] as? String else { return nil }
        let user = j["user"] as? [String: Any]
        let metadata = j["metadata"] as? [String: Any]
        let connections = metadata?["connections"] as? [String: Any]
        let replies = connections?["replies"] as? [String: Any]
        let created = j["created_on"] as? String
        return Comment(uri: uri,
                       text: j["text"] as? String ?? "",
                       author: user?["name"] as? String ?? "Neznámy",
                       authorURL: (user?["link"] as? String).flatMap { URL(string: $0) },
                       date: created.flatMap { ISO8601DateFormatter().date(from: $0) },
                       replyCount: (replies?["total"] as? NSNumber)?.intValue ?? 0,
                       isReply: isReply)
    }
}

extension Notification.Name {
    static let vimeoTokenChanged = Notification.Name("VimeoTokenChanged")
}

// MARK: - WebVTT

enum VTT {
    static func parse(_ s: String) -> [Cue] {
        let normalized = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let idx = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timing = lines[idx].components(separatedBy: "-->")
            guard timing.count == 2, let st = parseStamp(timing[0]), let en = parseStamp(timing[1]) else { continue }
            let text = clean(lines[(idx + 1)...].joined(separator: " "))
            if text.isEmpty { continue }
            if let last = cues.last, last.text == text {
                cues[cues.count - 1] = Cue(start: last.start, end: en, text: text)
                continue
            }
            cues.append(Cue(start: st, end: en, text: text))
        }
        return cues
    }

    static func parseStamp(_ raw: String) -> Double? {
        let first = raw.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let parts = first.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        if parts.isEmpty { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p) else { return nil }
            total = total * 60 + v
        }
        return total
    }

    static func clean(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities: [(String, String)] = [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                                            ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")]
        for (k, v) in entities { out = out.replacingOccurrences(of: k, with: v) }
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "VimeoViewer.APIToken"
    private static let account = "vimeo"

    static func read() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func save(_ value: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let v = value, !v.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(v.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
