import Foundation

/// Odkaz na konkrétne Vimeo video (ID + prípadný hash pre nezverejnené videá + čas začiatku).
struct VimeoVideoRef: Equatable {
    let id: String
    let hash: String?
    var startTime: Double?

    func isSameVideo(_ other: VimeoVideoRef?) -> Bool {
        guard let o = other else { return false }
        return o.id == id && o.hash == hash
    }

    var pageURL: URL {
        if let h = hash { return URL(string: "https://vimeo.com/\(id)/\(h)")! }
        return URL(string: "https://vimeo.com/\(id)")!
    }

    func pageURL(at seconds: Double?) -> URL {
        guard let s = seconds, s >= 1 else { return pageURL }
        return URL(string: pageURL.absoluteString + "#t=\(Int(s))s")!
    }

    func playerURL(at seconds: Double? = nil) -> URL {
        var s = "https://player.vimeo.com/video/\(id)"
        if let h = hash { s += "?h=\(h)" }
        if let t = seconds, t >= 1 { s += "#t=\(Int(t))s" }
        return URL(string: s)!
    }

    /// Cesta pre Vimeo API (nezverejnené videá používajú zápis ID:HASH).
    var apiPath: String {
        if let h = hash { return "/videos/\(id):\(h)" }
        return "/videos/\(id)"
    }
}

enum VimeoLinks {

    // MARK: Hosty

    static func isVimeoSiteHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "vimeo.com" || h.hasSuffix(".vimeo.com")
    }

    /// Hosty, ktoré smú zostať vo vnútri aplikácie (Vimeo + prihlasovanie).
    static func isInAppHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        if isVimeoSiteHost(h) { return true }
        if h == "vimeocdn.com" || h.hasSuffix(".vimeocdn.com") { return true }
        return isAuthHost(h)
    }

    static func isAuthHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        let auth = ["accounts.google.com", "appleid.apple.com", "idmsa.apple.com",
                    "login.microsoftonline.com", "login.live.com", "www.facebook.com", "m.facebook.com"]
        return auth.contains(h) || h.hasSuffix(".okta.com") || h.hasSuffix(".auth0.com")
    }

    // MARK: Rozpoznanie videa

    static func isNumeric(_ s: String) -> Bool {
        return !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func isHash(_ s: String) -> Bool {
        let hex = "0123456789abcdef"
        return s.count >= 6 && s.count <= 24 && s.lowercased().allSatisfy { hex.contains($0) }
    }

    /// Vráti odkaz na video, ak URL smeruje na konkrétne Vimeo video.
    static func videoRef(from url: URL) -> VimeoVideoRef? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard let host = url.host?.lowercased(), isVimeoSiteHost(host) else { return nil }
        let comps = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        var id: String? = nil
        var hash: String? = nil

        if host == "player.vimeo.com" {
            if comps.count >= 2, comps[0] == "video", isNumeric(comps[1]) {
                id = comps[1]
                if comps.count >= 3, isHash(comps[2]) { hash = comps[2] }
            }
        } else if host == "vimeo.com" || host == "www.vimeo.com" {
            if let first = comps.first, isNumeric(first) {
                // vimeo.com/123456789 alebo vimeo.com/123456789/abcdef1234
                id = first
                if comps.count >= 2, isHash(comps[1]) { hash = comps[1] }
            } else if comps.count >= 3, comps[0] == "channels", isNumeric(comps[2]) {
                // vimeo.com/channels/staffpicks/123456
                id = comps[2]
            } else {
                // vimeo.com/showcase/1/video/2, /album/1/video/2, /groups/x/videos/2, /manage/videos/2
                for (i, c) in comps.enumerated() where (c == "video" || c == "videos") && i + 1 < comps.count && isNumeric(comps[i + 1]) {
                    id = comps[i + 1]
                    if i + 2 < comps.count, isHash(comps[i + 2]) { hash = comps[i + 2] }
                    break
                }
            }
        }

        guard let videoID = id else { return nil }
        if hash == nil, let h = query.first(where: { $0.name == "h" })?.value, isHash(h) { hash = h }

        var start: Double? = nil
        if let t = query.first(where: { $0.name == "t" })?.value { start = parseTime(t) }
        if let frag = url.fragment {
            for part in frag.split(separator: "&") where part.hasPrefix("t=") {
                start = parseTime(String(part.dropFirst(2)))
            }
        }
        return VimeoVideoRef(id: videoID, hash: hash, startTime: start)
    }

    // MARK: Normalizácia (vlastná schéma, presmerovania Outlook/Google/Facebook)

    static func normalize(_ url: URL) -> URL {
        var u = url
        if u.scheme?.lowercased() == "vimeoviewer" {
            if let c = URLComponents(url: u, resolvingAgainstBaseURL: false),
               let inner = c.queryItems?.first(where: { $0.name == "url" })?.value,
               let iu = URL(string: inner) {
                u = iu
            } else {
                var rest = u.absoluteString
                if let r = rest.range(of: "://") { rest = String(rest[r.upperBound...]) }
                else if let r = rest.range(of: ":") { rest = String(rest[r.upperBound...]) }
                if isNumeric(rest), let iu = URL(string: "https://vimeo.com/\(rest)") { u = iu }
                else if let iu = URL(string: "https://" + rest) { u = iu }
            }
        }
        for _ in 0..<4 {
            let n = unwrapRedirect(u)
            if n == u { break }
            u = n
        }
        return u
    }

    static func unwrapRedirect(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let items = comps.queryItems ?? []
        func param(_ names: [String]) -> URL? {
            for n in names {
                if let v = items.first(where: { $0.name == n })?.value, let u = URL(string: v), u.scheme != nil { return u }
            }
            return nil
        }
        if host.hasSuffix("safelinks.protection.outlook.com") { return param(["url"]) ?? url }
        if host.hasPrefix("www.google.") || host.hasPrefix("google."), comps.path == "/url" { return param(["q", "url"]) ?? url }
        if host == "l.facebook.com" || host == "lm.facebook.com" { return param(["u"]) ?? url }
        if host == "www.linkedin.com", comps.path.hasPrefix("/redir") { return param(["url"]) ?? url }
        return url
    }

    // MARK: Čas

    /// Podporuje "90", "90s", "1m30s", "1h2m3s", "01:30", "1:02:03".
    static func parseTime(_ s: String) -> Double? {
        let str = s.trimmingCharacters(in: .whitespaces).lowercased()
        if str.isEmpty { return nil }
        if str.contains(":") {
            var total = 0.0
            for p in str.split(separator: ":") {
                guard let v = Double(p) else { return nil }
                total = total * 60 + v
            }
            return total
        }
        if let v = Double(str) { return v }
        var total = 0.0
        var num = ""
        for ch in str {
            if ch.isNumber || ch == "." {
                num.append(ch)
            } else {
                guard let v = Double(num) else { return nil }
                switch ch {
                case "h": total += v * 3600
                case "m": total += v * 60
                case "s": total += v
                default: return nil
                }
                num = ""
            }
        }
        if !num.isEmpty, let v = Double(num) { total += v }
        return total
    }

    static func formatTime(_ t: Double) -> String {
        let s = max(0, Int(t.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}
