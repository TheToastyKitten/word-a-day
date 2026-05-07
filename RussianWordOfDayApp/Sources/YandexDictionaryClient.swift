import Foundation

// MARK: - Shared helpers

private func uniquePreservingOrder(_ items: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    out.reserveCapacity(items.count)
    for s in items {
        if seen.contains(s) { continue }
        seen.insert(s)
        out.append(s)
    }
    return out
}

private func cleanDefinitionHTML(_ s: String) -> String? {
    // Yandex doesn't return HTML, but we keep this normalizer to defend against
    // any future provider sending markup-ish strings.
    let stripped = scrubDictionaryMarkupArtifacts(
        stripHTMLTags(removeStyleAndScriptBlocks(s))
    )
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&#39;", with: "'")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return stripped.isEmpty ? nil : stripped
}

private func removeStyleAndScriptBlocks(_ html: String) -> String {
    // Some dictionary sources embed <style>/<script>; remove them before tag-stripping.
    var out = html
    let patterns = [
        #"(?is)<style\b[^>]*>.*?</style>"#,
        #"(?is)<script\b[^>]*>.*?</script>"#,
    ]
    for p in patterns {
        if let rx = try? NSRegularExpression(pattern: p) {
            out = rx.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..<out.endIndex, in: out),
                withTemplate: ""
            )
        }
    }
    return out
}

private func stripHTMLTags(_ s: String) -> String {
    // Not a perfect HTML parser; good enough for small definition snippets.
    // Remove tags and their attributes, keep inner text.
    var out = ""
    out.reserveCapacity(s.count)
    var inTag = false
    for ch in s {
        if ch == "<" {
            inTag = true
            continue
        }
        if ch == ">" {
            inTag = false
            continue
        }
        if !inTag {
            out.append(ch)
        }
    }
    // Collapse runs of whitespace.
    return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

private func scrubDictionaryMarkupArtifacts(_ s: String) -> String {
    // Defensive cleanup for leaked CSS or parser artifacts that can survive
    // simplified HTML stripping (e.g. ".mw-parser-output { ... }").
    var out = s
    let patterns = [
        // CSS rule blocks
        #"(?s)\.[a-zA-Z0-9_-]{1,80}\s*\{[^}]*\}"#,
        // Common class names that sometimes leak through
        #"(?i)\bmw-parser-output\b"#,
        #"(?i)\bobject-usage-tag\b"#,
    ]
    for p in patterns {
        if let rx = try? NSRegularExpression(pattern: p) {
            out = rx.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..<out.endIndex, in: out),
                withTemplate: ""
            )
        }
    }
    return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

// MARK: - Yandex Dictionary API

enum YandexDictionaryClient {
    struct EnrichmentPayload: Equatable, Hashable {
        let definitions: [String]
        let examples: [String]
        let sourceURL: URL
    }

    enum YandexError: Error {
        case invalidURL
        case http(Int)
        case decoding
        case empty
    }

    static func fetchRussianEnrichment(
        apiKey: String,
        headword russian: String,
        preferredPartOfSpeech: String?
    ) async throws -> EnrichmentPayload {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw YandexError.invalidURL }
        guard let encodedText = russian.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw YandexError.invalidURL
        }
        let url = URL(string: "https://dictionary.yandex.net/api/v1/dicservice.json/lookup?key=\(trimmedKey)&lang=ru-en&text=\(encodedText)")!

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("RussianWordOfDayApp/1.0 (enrichment)", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw YandexError.http(status) }

        guard let parsed = try? JSONDecoder().decode(LookupResponse.self, from: data) else {
            throw YandexError.decoding
        }

        let preferred = preferredPartOfSpeech.flatMap { acceptedYandexPOS(localPOS: $0) }
        let defs = selectDefs(parsed.def, preferred: preferred)

        let (definitions, examples) = extract(defs)
        let uniqDefs = Array(uniquePreservingOrder(definitions).prefix(8))
        let uniqEx = Array(uniquePreservingOrder(examples).prefix(6))
        if uniqDefs.isEmpty && uniqEx.isEmpty { throw YandexError.empty }

        return EnrichmentPayload(definitions: uniqDefs, examples: uniqEx, sourceURL: url)
    }
}

private struct LookupResponse: Decodable {
    let `def`: [YandexDef]
}

private struct YandexDef: Decodable {
    let text: String?
    let pos: String?
    let tr: [YandexTr]?
}

private struct YandexTr: Decodable {
    let text: String?
    let pos: String?
    /// Sense hints; for ru-en often Russian (skipped in English “Meaning”).
    let mean: [YandexTextBlob]?
    /// Synonyms; for ru-en usually English (kept when Latin-only).
    let syn: [YandexTextBlob]?
    let ex: [YandexEx]?
}

private struct YandexTextBlob: Decodable {
    let text: String?
}

private struct YandexEx: Decodable {
    let text: String?
    let tr: [YandexExTr]?
}

private struct YandexExTr: Decodable {
    let text: String?
}

private func selectDefs(_ defs: [YandexDef], preferred: Set<String>?) -> [YandexDef] {
    guard let preferred, !preferred.isEmpty else { return defs }
    let filtered = defs.filter { d in
        let p = (d.pos ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return preferred.contains(p)
    }
    return filtered.isEmpty ? defs : filtered
}

private func containsCyrillic(_ s: String) -> Bool {
    for u in s.unicodeScalars {
        let v = Int(u.value)
        if (0x0400...0x04FF).contains(v) { return true }
        if (0x0500...0x052F).contains(v) { return true }
    }
    return false
}

private func extract(_ defs: [YandexDef]) -> (definitions: [String], examples: [String]) {
    var outDefs: [String] = []
    var outEx: [String] = []

    for d in defs {
        for tr in d.tr ?? [] {
            if let t = tr.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                // ru→en: `tr.text` is English. `mean` is often *Russian* sense glosses;
                // showing those in "Meaning" confuses English UI. Keep only Latin glosses.
                let means = (tr.mean ?? [])
                    .compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && !containsCyrillic($0) }
                let syns = (tr.syn ?? [])
                    .compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && !containsCyrillic($0) }
                var line = t
                if !means.isEmpty {
                    line = "\(t) — \(means.joined(separator: ", "))"
                }
                if !syns.isEmpty {
                    line += " (also: \(syns.joined(separator: ", ")))"
                }
                outDefs.append(line)
            }
            for ex in tr.ex ?? [] {
                let ru = ex.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let en = (ex.tr?.first?.text)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let combined: String
                if !ru.isEmpty && !en.isEmpty {
                    combined = "\(ru) — \(en)"
                } else {
                    combined = ru.isEmpty ? en : ru
                }
                if !combined.isEmpty {
                    outEx.append(combined)
                }
            }
        }
    }
    return (outDefs, outEx)
}

private func acceptedYandexPOS(localPOS raw: String) -> Set<String> {
    let p = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch p {
    case "noun":
        return ["noun"]
    case "verb":
        return ["verb"]
    case "adj":
        return ["adjective", "adj"]
    case "adv":
        return ["adverb", "adv"]
    case "pron":
        return ["pronoun", "pron"]
    case "det":
        return ["determiner", "det", "article"]
    case "prep":
        return ["preposition", "prep"]
    case "conj":
        return ["conjunction", "conj"]
    case "particle":
        return ["particle"]
    case "num":
        return ["numeral", "number", "num"]
    case "intj":
        return ["interjection", "intj"]
    default:
        return []
    }
}

