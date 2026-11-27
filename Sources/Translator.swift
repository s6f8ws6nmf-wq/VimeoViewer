import Foundation
import NaturalLanguage

/// Preklad prepisu. Predvolene Google Prekladač (bez nastavenia), voliteľne DeepL (kľúč v Nastaveniach).
enum Translator {
    static let languages: [(name: String, code: String)] = [
        ("Slovenčina", "sk"), ("Čeština", "cs"), ("English", "en"), ("Deutsch", "de"), ("Italiano", "it"),
        ("Español", "es"), ("Français", "fr"), ("Magyar", "hu"), ("Polski", "pl"), ("Українська", "uk"),
        ("Русский", "ru"), ("Português", "pt"), ("Nederlands", "nl"), ("Hrvatski", "hr"), ("Română", "ro"),
    ]

    /// Názov jazyka po slovensky (napr. „taliančina“).
    static func localName(_ code: String) -> String {
        let base = String(code.prefix(2)).lowercased()
        return Locale(identifier: "sk").localizedString(forLanguageCode: base) ?? code
    }

    /// Rozpozná jazyk textu (vráti napr. „it“).
    static func detect(_ texts: [String]) -> String? {
        let r = NLLanguageRecognizer()
        r.processString(texts.prefix(120).joined(separator: " "))
        return r.dominantLanguage?.rawValue
    }

    static var deeplKey: String? {
        get {
            let k = UserDefaults.standard.string(forKey: "deeplKey")?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (k?.isEmpty ?? true) ? nil : k
        }
        set { UserDefaults.standard.set(newValue, forKey: "deeplKey") }
    }

    static var engineName: String { deeplKey == nil ? "Google Prekladač" : "DeepL" }

    /// Preloží texty (poradie zostane zachované). Volá progress 0…1 a completion na hlavnom vlákne.
    static func translate(_ texts: [String], to target: String,
                          progress: @escaping (Double) -> Void,
                          completion: @escaping (Result<[String], Error>) -> Void) {
        var batches: [[Int]] = []
        var current: [Int] = []
        var chars = 0
        let limit = deeplKey == nil ? 1500 : 20000
        let maxItems = deeplKey == nil ? 200 : 50
        for (i, t) in texts.enumerated() {
            if !current.isEmpty && (chars + t.count > limit || current.count >= maxItems) {
                batches.append(current)
                current = []
                chars = 0
            }
            current.append(i)
            chars += t.count + 1
        }
        if !current.isEmpty { batches.append(current) }

        var result = texts
        func run(_ b: Int) {
            guard b < batches.count else {
                DispatchQueue.main.async { completion(.success(result)) }
                return
            }
            let idx = batches[b]
            let part = idx.map { texts[$0] }
            translateBatch(part, to: target) { r in
                switch r {
                case .success(let out):
                    for (k, i) in idx.enumerated() where k < out.count { result[i] = out[k] }
                    DispatchQueue.main.async { progress(Double(b + 1) / Double(batches.count)) }
                    run(b + 1)
                case .failure(let e):
                    DispatchQueue.main.async { completion(.failure(e)) }
                }
            }
        }
        run(0)
    }

    private static func translateBatch(_ texts: [String], to target: String, completion: @escaping (Result<[String], Error>) -> Void) {
        if let key = deeplKey { deepl(texts, to: target, key: key, completion: completion) }
        else { google(texts, to: target, completion: completion) }
    }

    // MARK: Google (bez kľúča)

    private static func google(_ texts: [String], to target: String, completion: @escaping (Result<[String], Error>) -> Void) {
        let joined = texts.map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n")
        googleRaw(joined, to: target) { r in
            switch r {
            case .success(let out):
                let lines = out.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                if lines.count == texts.count {
                    completion(.success(lines))
                } else {
                    // Riadky sa nezhodujú – prelož po jednom.
                    oneByOne(texts, to: target, completion: completion)
                }
            case .failure(let e):
                completion(.failure(e))
            }
        }
    }

    private static func oneByOne(_ texts: [String], to target: String, completion: @escaping (Result<[String], Error>) -> Void) {
        var out = texts
        func step(_ i: Int) {
            guard i < texts.count else { completion(.success(out)); return }
            googleRaw(texts[i], to: target) { r in
                if case .success(let t) = r { out[i] = t.trimmingCharacters(in: .whitespacesAndNewlines) }
                step(i + 1)
            }
        }
        step(0)
    }

    private static func googleRaw(_ text: String, to target: String, completion: @escaping (Result<String, Error>) -> Void) {
        var c = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        c.queryItems = [URLQueryItem(name: "client", value: "gtx"), URLQueryItem(name: "sl", value: "auto"),
                        URLQueryItem(name: "tl", value: target), URLQueryItem(name: "dt", value: "t"),
                        URLQueryItem(name: "q", value: text)]
        guard let url = c.url else { completion(.failure(APIError.parse)); return }
        URLSession.shared.dataTask(with: url) { data, resp, err in
            if let e = err { completion(.failure(e)); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code), let d = data,
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [Any],
                  let segs = j.first as? [Any] else {
                completion(.failure(APIError.http(code, "Prekladač neodpovedal správne")))
                return
            }
            let out = segs.compactMap { ($0 as? [Any])?.first as? String }.joined()
            completion(.success(out))
        }.resume()
    }

    // MARK: DeepL (s kľúčom)

    private static func deepl(_ texts: [String], to target: String, key: String, completion: @escaping (Result<[String], Error>) -> Void) {
        let host = key.hasSuffix(":fx") ? "https://api-free.deepl.com" : "https://api.deepl.com"
        var req = URLRequest(url: URL(string: host + "/v2/translate")!)
        req.httpMethod = "POST"
        req.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var t = target.uppercased()
        if t == "EN" { t = "EN-GB" }
        if t == "PT" { t = "PT-PT" }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": texts, "target_lang": t])
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let e = err { completion(.failure(e)); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code), let d = data,
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let arr = j["translations"] as? [[String: Any]] else {
                completion(.failure(APIError.http(code, code == 403 ? "Neplatný DeepL kľúč" : "DeepL neodpovedal správne")))
                return
            }
            completion(.success(arr.map { $0["text"] as? String ?? "" }))
        }.resume()
    }
}
