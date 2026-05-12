import Foundation
import SQLite3

// SQLite's SQLITE_TRANSIENT macro is not bridged into Swift; redefine it here.
private let SQLITE_TRANSIENT_SWIFT = unsafeBitCast(
    OpaquePointer(bitPattern: -1),
    to: sqlite3_destructor_type.self
)

@MainActor
final class WordStore: ObservableObject {
    @Published private(set) var isReady: Bool = false

    private var db: OpaquePointer?
    private let dbFileName = "words.sqlite"
    private let bundledDictionaryName = "dictionary"
    private let bundledDictionaryExtension = "sqlite"

    private static let enrichmentSourceYandex = "yandex_ruen_v4"

    // NOTE: This is embedded in the app binary and can be extracted.
    // Use only for personal builds / small betas.
    private static let bakedYandexDictionaryAPIKey =
        "dict.1.1.20260507T211145Z.dcce4f2d5fec4778.d72deadabead921e1c97e2e886028ac8d7f86de8"

    // Keep the app simpler for beginners by limiting content to core POS.
    private static let allowedPOS: [String] = [
        "noun",
        "verb",
        "adj",
        "adjective",
        "adv",
        "adverb",
    ]

    private static let allowedPOSClause: String =
        "AND (w.pos IS NOT NULL AND lower(trim(w.pos)) IN (\(allowedPOS.map { _ in "?" }.joined(separator: ", "))))"

    /// Wiktionary-style English lines that describe an inflected form ("past indicative of …")
    /// rather than a learner gloss. Search hides these so prefix lookup surfaces lemmas.
    private static let morphEnglishSearchPatterns: [NSRegularExpression] = {
        let raw: [String] = [
            #"(?i)\bindicative\b.*\bof\b"#,
            #"(?i)\bsubjunctive\b.*\bof\b"#,
            #"(?i)\bconditional\b.{0,40}\bof\b"#,
            #"(?i)\bpast\s+tense\b.*\bof\b"#,
            #"(?i)\bsimple\s+past\b.*\bof\b"#,
            #"(?i)\bpast\s+historic\b.*\bof\b"#,
            // Truncated before " of lemma"
            #"(?i)^(?:masculine|feminine|neuter)\b.{0,180}\b(?:past|present|future)\s+indicative\b"#,
            // Overlap with seed script heuristics (safety net for older bundles)
            #"(?i)\b(?:dative|genitive|accusative|instrumental|prepositional|locative|vocative|ablative)\b.*\bof\b"#,
            #"(?i)\bgerund\b.*\bof\b"#,
            #"(?i)\bimperative\b.*\bof\b"#,
            #"(?i)\binfinitive\b.*\bof\b"#,
            #"(?i)\brelational\s+adjective\b.*\bof\b"#,
            #"(?i)\bpossessive\s+adjective\b.*\bof\b"#,
            #"(?i)^(?:masculine|feminine|neuter)\b.{0,160}\brelational\s+adjective\b"#,
            #"(?i)\binflection\s+of\b"#,
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func ensureSeededIfNeeded() async {
        do {
            try await installBundledDictionaryIfMissing()
            try openOrCreateDatabase()
            try migrateBundledDictionaryIfNeeded()
            try createSchemaIfNeeded()
            try applyKnownDictionaryFixesIfNeeded()
            isReady = true
        } catch {
            isReady = false
        }
    }

    func search(query raw: String, limit: Int = 10, posFilters: [String] = []) -> [WordEntry] {
        guard let db else { return [] }
        let q = normalizeForIndex(raw)
        guard !q.isEmpty else { return [] }

        // Build a safe FTS5 prefix query: split on whitespace, drop characters
        // that are special in the FTS5 grammar, double-quote each token to
        // neutralize remaining oddities, then suffix with `*` for prefix match.
        let tokens = q
            .split(whereSeparator: \.isWhitespace)
            .map { String($0) }
            .map { sanitizeFTSToken($0) }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return [] }
        let ftsQuery = tokens.map { "\"\($0)\"*" }.joined(separator: " ")

        let pos = posFilters
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        let posClause = pos.isEmpty
            ? ""
            : "AND lower(trim(w.pos)) IN (\(Array(repeating: "?", count: pos.count).joined(separator: ", ")))"

        let sql = """
        SELECT w.id, w.ru, w.en, w.meaning_en, w.pos, w.glosses_en, w.ai_note_en, w.phonetic
        FROM words_fts f
        JOIN words w ON w.id = f.id
        WHERE words_fts MATCH ?
        \(Self.allowedPOSClause)
        \(posClause)
        ORDER BY bm25(words_fts)
        LIMIT ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, ftsQuery, -1, SQLITE_TRANSIENT_SWIFT)
        var bindIndex: Int32 = 2
        for p in Self.allowedPOS {
            sqlite3_bind_text(stmt, bindIndex, p, -1, SQLITE_TRANSIENT_SWIFT)
            bindIndex += 1
        }
        for p in pos {
            sqlite3_bind_text(stmt, bindIndex, p, -1, SQLITE_TRANSIENT_SWIFT)
            bindIndex += 1
        }
        // Pull extra candidates so we can drop inflection-definition rows (English
        // morphology like "past indicative … of …") and still fill `limit`.
        let fetchCap = min(max(limit * 12, limit + 8), 120)
        sqlite3_bind_int(stmt, bindIndex, Int32(fetchCap))

        var out: [WordEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let w = rowToWord(stmt)
            if Self.englishLooksLikeMorphSearchNoise(w.english) { continue }
            out.append(w)
            if out.count >= limit { break }
        }
        return out
    }

    func getWord(id: String) -> WordEntry? {
        guard let db else { return nil }
        let sql = "SELECT id, ru, en, meaning_en, pos, glosses_en, ai_note_en, phonetic FROM words WHERE id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT_SWIFT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return rowToWord(stmt)
    }

    /// Best-effort lookup for a Russian headword (exact match on normalized `ru_norm`).
    func findWordID(russianHeadword raw: String) -> String? {
        guard let db else { return nil }
        let norm = normalizeForIndex(raw)
        guard !norm.isEmpty else { return nil }
        let sql = """
        SELECT id
        FROM words w
        WHERE w.ru_norm = ?
        \(Self.allowedPOSClause)
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, norm, -1, SQLITE_TRANSIENT_SWIFT)
        var bindIndex: Int32 = 2
        for p in Self.allowedPOS {
            sqlite3_bind_text(stmt, bindIndex, p, -1, SQLITE_TRANSIENT_SWIFT)
            bindIndex += 1
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    // MARK: - Optional online enrichment (cached locally)

    func getEnrichment(id wordID: String) -> WordEnrichment? {
        guard let db else { return nil }
        let sql = """
        SELECT source, fetched_at, definitions, examples, source_url
        FROM word_enrichment
        WHERE word_id = ?
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, wordID, -1, SQLITE_TRANSIENT_SWIFT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let source = String(cString: sqlite3_column_text(stmt, 0))
        let fetchedAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1)))
        let defsBlob = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let exBlob = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
        let urlStr = sqlite3_column_text(stmt, 4).map { String(cString: $0) }

        let defs = defsBlob.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let ex = exBlob.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let url = urlStr.flatMap(URL.init(string:))

        return WordEnrichment(
            id: wordID,
            source: source,
            fetchedAt: fetchedAt,
            definitions: defs,
            examples: ex,
            sourceURL: url
        )
    }

    /// Best-effort fetch. Safe to call repeatedly; it only skips when we already
    /// have non-empty cached definitions.
    func fetchEnrichmentIfNeeded(id wordID: String) async {
        guard let word = getWord(id: wordID) else { return }

        // Yandex-only: if no key is set, enrichment is disabled.
        guard let key = readYandexKey() else { return }

        if let existing = getEnrichment(id: wordID), !existing.definitions.isEmpty {
            // If the cache only contains the headline translation (which the UI may
            // de-duplicate against the gray subtitle), treat it as effectively empty
            // and re-fetch so we can populate non-duplicate meaning lines.
            let headline = word.english.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let defs = existing.definitions
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            let onlyHeadline = !headline.isEmpty && !defs.isEmpty && defs.allSatisfy { $0 == headline }
            // Also refresh older cache formats when we change enrichment heuristics/provider.
            let currentSource = Self.enrichmentSourceYandex
            if existing.source != currentSource {
                // fallthrough to refetch
            } else if !onlyHeadline {
                return
            }
        }

        do {
            let payload = try await YandexDictionaryClient.fetchRussianEnrichment(
                apiKey: key,
                headword: word.russian,
                preferredPartOfSpeech: word.pos
            )
            storeEnrichment(
                wordID: wordID,
                source: Self.enrichmentSourceYandex,
                fetchedAt: Date(),
                definitions: payload.definitions,
                examples: payload.examples,
                sourceURL: payload.sourceURL
            )
        } catch {
            // Silent by design: enrichment is optional and should never block the UX.
        }
    }

    private func readYandexKey() -> String? {
        let s = UserDefaults.standard.string(forKey: "yandex_dictionary_api_key")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !s.isEmpty { return s }
        let baked = Self.bakedYandexDictionaryAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return baked.isEmpty ? nil : baked
    }

    /// Wipes every "this word is taken" piece of state:
    /// - `used_words` (the historical pool of words the user has been served)
    /// - `scheduled_pushes` (the rolling buffer of upcoming notifications)
    /// - legacy `scheduled_words` from the older slot-stable design
    /// After calling this the caller must also remove pending UN
    /// notification requests from the system.
    func resetUsedWords() {
        guard let db else { return }
        _ = sqlite3_exec(db, "DELETE FROM used_words;", nil, nil, nil)
        _ = sqlite3_exec(db, "DELETE FROM scheduled_pushes;", nil, nil, nil)
        _ = sqlite3_exec(db, "DELETE FROM scheduled_words;", nil, nil, nil)
    }

    func remainingUnusedCount() -> Int {
        guard let db else { return 0 }
        let sql = """
        SELECT COUNT(*)
        FROM words w
        LEFT JOIN used_words u       ON u.word_id = w.id
        LEFT JOIN scheduled_pushes s ON s.word_id = w.id
        WHERE u.word_id IS NULL
          AND s.word_id IS NULL
          \(Self.allowedPOSClause)
          AND w.is_common = 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        var bindIndex: Int32 = 1
        for p in Self.allowedPOS {
            sqlite3_bind_text(stmt, bindIndex, p, -1, SQLITE_TRANSIENT_SWIFT)
            bindIndex += 1
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - Used-words inspection (for a future Used-words screen)

    /// Total number of words currently marked used.
    func usedWordCount() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM used_words;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Lists used words newest-first, joined with their display fields so a
    /// future UI can render rows without a second lookup. Pagination is
    /// optional but defaults are conservative.
    func usedWords(limit: Int = 200, offset: Int = 0) -> [UsedWord] {
        guard let db else { return [] }
        let sql = """
        SELECT u.word_id, u.used_at, w.ru, w.en, w.meaning_en, w.pos, w.glosses_en, w.ai_note_en, w.phonetic
        FROM used_words u
        JOIN words w ON w.id = u.word_id
        WHERE 1 = 1
        \(Self.allowedPOSClause)
        ORDER BY u.used_at DESC
        LIMIT ? OFFSET ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var bindIndex: Int32 = 1
        for p in Self.allowedPOS {
            sqlite3_bind_text(stmt, bindIndex, p, -1, SQLITE_TRANSIENT_SWIFT)
            bindIndex += 1
        }
        sqlite3_bind_int(stmt, bindIndex, Int32(limit))
        sqlite3_bind_int(stmt, bindIndex + 1, Int32(offset))

        var out: [UsedWord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let usedAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1)))
            let ru = String(cString: sqlite3_column_text(stmt, 2))
            let en = String(cString: sqlite3_column_text(stmt, 3))
            let meaning = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let pos = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            let glosses = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            let aiNote = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
            let phonetic = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
            let word = WordEntry(
                id: id,
                russian: ru,
                english: en,
                meaning_en: (meaning?.isEmpty == false) ? meaning : nil,
                pos: (pos?.isEmpty == false) ? pos : nil,
                glosses_en: (glosses?.isEmpty == false) ? glosses : nil,
                ai_note_en: (aiNote?.isEmpty == false) ? aiNote : nil,
                phonetic: (phonetic?.isEmpty == false) ? phonetic : nil
            )
            out.append(UsedWord(word: word, usedAt: usedAt))
        }
        return out
    }

    // MARK: - Self quiz (used-word pool)

    /// Used words in random order (up to `limit`) for the self-quiz.
    func randomUsedWordsForQuiz(limit: Int = 10) -> [WordEntry] {
        guard let db else { return [] }
        let sql = """
        SELECT w.id, w.ru, w.en, w.meaning_en, w.pos, w.glosses_en, w.ai_note_en, w.phonetic
        FROM used_words u
        JOIN words w ON w.id = u.word_id
        WHERE 1 = 1
        \(Self.allowedPOSClause)
        ORDER BY RANDOM()
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var bindIndex: Int32 = 1
        for p in Self.allowedPOS {
            sqlite3_bind_text(stmt, bindIndex, p, -1, SQLITE_TRANSIENT_SWIFT)
            bindIndex += 1
        }
        sqlite3_bind_int(stmt, bindIndex, Int32(limit))

        var out: [WordEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(rowToWord(stmt))
        }
        return out
    }

    /// Primary English glosses from random dictionary rows for quiz distractors.
    /// Skips blank `en`, de-duplicates by `normalizeForIndex`, and omits strings whose
    /// normalized form appears in `excludingNormalized`.
    func randomEnglishQuizDistractorCandidates(
        excludingNormalized: Set<String>,
        maxToScan: Int = 400,
        maxCollected: Int = 80
    ) -> [String] {
        guard let db else { return [] }
        let cap = max(40, min(maxToScan, 2_000))
        let sql = """
        SELECT w.en
        FROM words w
        WHERE trim(w.en) != ''
        \(Self.allowedPOSClause)
        ORDER BY RANDOM()
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var bindIndex: Int32 = 1
        for p in Self.allowedPOS {
            sqlite3_bind_text(stmt, bindIndex, p, -1, SQLITE_TRANSIENT_SWIFT)
            bindIndex += 1
        }
        sqlite3_bind_int(stmt, bindIndex, Int32(cap))

        var collected: [String] = []
        var seenNorm: Set<String> = []
        let want = max(1, min(maxCollected, 200))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let raw = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let display = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !display.isEmpty else { continue }
            let key = normalizeForIndex(display)
            guard !key.isEmpty else { continue }
            if excludingNormalized.contains(key) { continue }
            if seenNorm.contains(key) { continue }
            seenNorm.insert(key)
            collected.append(display)
            if collected.count >= want { break }
        }
        return collected
    }

    /// Returns true if the word is currently marked used. Useful for an
    /// "un-use" button in a future UI to know which state to show.
    func isWordUsed(id: String) -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM used_words WHERE word_id = ? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT_SWIFT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Brings a word back into the pool atomically:
    /// - removes any future pushes referencing it (so it stops firing)
    /// - removes the row from `used_words`
    /// Returns the notification request identifiers that the caller must
    /// cancel via `UNUserNotificationCenter` so the iOS-side pending list
    /// stays consistent with the DB.
    @discardableResult
    func markWordUnused(id wordID: String) -> [String] {
        guard let db else { return [] }

        var cancelled: [String] = []

        _ = sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)

        let selectSQL = "SELECT id FROM scheduled_pushes WHERE word_id = ?;"
        var selectStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(selectStmt, 1, wordID, -1, SQLITE_TRANSIENT_SWIFT)
            while sqlite3_step(selectStmt) == SQLITE_ROW {
                cancelled.append(String(cString: sqlite3_column_text(selectStmt, 0)))
            }
        }
        sqlite3_finalize(selectStmt)

        let deletePushSQL = "DELETE FROM scheduled_pushes WHERE word_id = ?;"
        var deletePushStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, deletePushSQL, -1, &deletePushStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(deletePushStmt, 1, wordID, -1, SQLITE_TRANSIENT_SWIFT)
            _ = sqlite3_step(deletePushStmt)
        }
        sqlite3_finalize(deletePushStmt)

        let deleteUsedSQL = "DELETE FROM used_words WHERE word_id = ?;"
        var deleteUsedStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteUsedSQL, -1, &deleteUsedStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(deleteUsedStmt, 1, wordID, -1, SQLITE_TRANSIENT_SWIFT)
            _ = sqlite3_step(deleteUsedStmt)
        }
        sqlite3_finalize(deleteUsedStmt)

        _ = sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        return cancelled
    }

    /// Marks a word used without scheduling any push. This is the manual
    /// entry point used by the Word Detail toggle; it does NOT touch
    /// `scheduled_pushes`, so any future push that already references this
    /// word continues to fire (it was already going to).
    ///
    /// Idempotent: if the word is already in `used_words`, this is a no-op.
    @discardableResult
    func markWordUsed(id wordID: String, at date: Date = Date()) -> Bool {
        guard let db else { return false }
        let sql = "INSERT OR IGNORE INTO used_words(word_id, used_at) VALUES(?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, wordID, -1, SQLITE_TRANSIENT_SWIFT)
        sqlite3_bind_int64(stmt, 2, Int64(date.timeIntervalSince1970))
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    // MARK: - Recent views

    /// Records (or refreshes) a "user opened this word's detail" event.
    /// `INSERT OR REPLACE` keeps a single row per word with the latest
    /// timestamp so the recents list is naturally deduplicated.
    func recordRecentView(id wordID: String, at date: Date = Date()) {
        guard let db else { return }
        let sql = "INSERT OR REPLACE INTO recent_views(word_id, viewed_at) VALUES(?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, wordID, -1, SQLITE_TRANSIENT_SWIFT)
        sqlite3_bind_int64(stmt, 2, Int64(date.timeIntervalSince1970))
        _ = sqlite3_step(stmt)

        _ = sqlite3_exec(db, """
            DELETE FROM recent_views
            WHERE word_id NOT IN (
              SELECT word_id FROM recent_views ORDER BY viewed_at DESC LIMIT 50
            );
            """, nil, nil, nil)
    }

    /// Returns the most recently viewed words, newest first, joined with
    /// their display fields. Words whose underlying row has been deleted are
    /// silently skipped via the join.
    func recentViews(limit: Int = 10, posFilters: [String] = []) -> [WordEntry] {
        guard let db else { return [] }

        let pos = posFilters
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        let posClause = pos.isEmpty
            ? ""
            : "AND lower(trim(w.pos)) IN (\(Array(repeating: "?", count: pos.count).joined(separator: ", ")))"

        let sql = """
        SELECT w.id, w.ru, w.en, w.meaning_en, w.pos, w.glosses_en, w.ai_note_en, w.phonetic
        FROM recent_views r
        JOIN words w ON w.id = r.word_id
        WHERE 1 = 1
        \(Self.allowedPOSClause)
        \(posClause)
        ORDER BY r.viewed_at DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var bindIndex: Int32 = 1
        for p in Self.allowedPOS {
            sqlite3_bind_text(stmt, bindIndex, p, -1, SQLITE_TRANSIENT_SWIFT)
            bindIndex += 1
        }
        for p in pos {
            sqlite3_bind_text(stmt, bindIndex, p, -1, SQLITE_TRANSIENT_SWIFT)
            bindIndex += 1
        }
        sqlite3_bind_int(stmt, bindIndex, Int32(limit))

        var out: [WordEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(rowToWord(stmt))
        }
        return out
    }

    // MARK: - Rolling push buffer

    /// Number of currently-persisted pushes whose `fire_at` is strictly in
    /// the future (relative to `now`). Used to decide how many top-up
    /// pushes are needed to reach the rolling-buffer target.
    func futureScheduledPushCount(now: Date = Date()) -> Int {
        guard let db else { return 0 }
        let sql = "SELECT COUNT(*) FROM scheduled_pushes WHERE fire_at > ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(now.timeIntervalSince1970))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// The latest `fire_at` among future scheduled pushes, or nil if none.
    /// New top-up entries are placed AFTER this time so the chronological
    /// order is preserved.
    func latestFutureFireAt(now: Date = Date()) -> Date? {
        guard let db else { return nil }
        let sql = "SELECT MAX(fire_at) FROM scheduled_pushes WHERE fire_at > ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(now.timeIntervalSince1970))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
        return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0)))
    }

    /// Snapshot of all scheduled pushes (past and future), sorted by fire time.
    /// Used by the scheduler to recover identifiers for cancellation and by
    /// debug tooling. Most callers should use `futureScheduledPushCount` /
    /// `latestFutureFireAt` instead.
    func allScheduledPushes() -> [ScheduledPush] {
        guard let db else { return [] }
        let sql = """
        SELECT id, fire_at, slot, word_id, created_at
        FROM scheduled_pushes
        ORDER BY fire_at ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var out: [ScheduledPush] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let fireAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1)))
            let slot = Int(sqlite3_column_int(stmt, 2))
            let wordID = String(cString: sqlite3_column_text(stmt, 3))
            let createdAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 4)))
            out.append(ScheduledPush(id: id, fireAt: fireAt, slot: slot, wordID: wordID, createdAt: createdAt))
        }
        return out
    }

    /// Picks a random unused word AND inserts a `scheduled_pushes` row in a
    /// single transaction. Returns the newly-built `ScheduledPush` plus the
    /// `WordEntry`, or nil if the dictionary is exhausted.
    ///
    /// The word is NOT inserted into `used_words` here — the row in
    /// `scheduled_pushes` already excludes it from `pickRandomUnusedLocked`.
    /// The promotion to `used_words` happens in
    /// `promoteFiredPushesAndPurge(now:)` once `fire_at` has elapsed.
    func reserveAndPersistPush(
        identifier: String,
        fireAt: Date,
        slot: Int
    ) -> (ScheduledPush, WordEntry)? {
        guard let db else { return nil }

        _ = sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)

        guard let word = pickRandomUnusedLocked() else {
            _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return nil
        }

        let now = Date()
        guard insertScheduledPushLocked(
            identifier: identifier,
            fireAt: fireAt,
            slot: slot,
            wordID: word.id,
            createdAt: now
        ) else {
            _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return nil
        }

        _ = sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        let push = ScheduledPush(
            id: identifier,
            fireAt: fireAt,
            slot: slot,
            wordID: word.id,
            createdAt: now
        )
        return (push, word)
    }

    /// Empties the `scheduled_pushes` buffer. Does NOT touch `used_words` —
    /// reserved words were never written there to begin with, so dropping the
    /// reservations is enough to release them back into the pool. Caller is
    /// responsible for cancelling the matching `UN` requests.
    func clearScheduledPushes() {
        guard let db else { return }
        _ = sqlite3_exec(db, "DELETE FROM scheduled_pushes;", nil, nil, nil)
    }

    /// Promotes any `scheduled_pushes` rows whose `fire_at` has elapsed into
    /// `used_words` (preserving `fire_at` as the `used_at` timestamp), then
    /// deletes those rows. Idempotent and cheap — call it on every top-up,
    /// foreground, and cold launch.
    ///
    /// Replaces the older `purgePastScheduledPushes`, which deleted past rows
    /// without preserving the "this word was delivered" signal. Callers that
    /// only care about cleanup can keep using this method; the promote step is
    /// a no-op when there's nothing past `now`.
    func promoteFiredPushesAndPurge(now: Date = Date()) {
        guard let db else { return }
        let nowSec = Int64(now.timeIntervalSince1970)

        _ = sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)

        let promoteSQL = """
        INSERT OR IGNORE INTO used_words(word_id, used_at)
        SELECT word_id, fire_at FROM scheduled_pushes WHERE fire_at <= ?;
        """
        var promoteStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, promoteSQL, -1, &promoteStmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(promoteStmt, 1, nowSec)
            _ = sqlite3_step(promoteStmt)
        }
        sqlite3_finalize(promoteStmt)

        let deleteSQL = "DELETE FROM scheduled_pushes WHERE fire_at <= ?;"
        var deleteStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(deleteStmt, 1, nowSec)
            _ = sqlite3_step(deleteStmt)
        }
        sqlite3_finalize(deleteStmt)

        _ = sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    // MARK: - Locked helpers (must run inside an open transaction)

    private func pickRandomUnusedLocked() -> WordEntry? {
        guard let db else { return nil }
        let sql = """
        SELECT w.id, w.ru, w.en, w.meaning_en, w.pos, w.glosses_en, w.ai_note_en, w.phonetic
        FROM words w
        LEFT JOIN used_words u       ON u.word_id = w.id
        LEFT JOIN scheduled_pushes s ON s.word_id = w.id
        WHERE u.word_id IS NULL
          AND s.word_id IS NULL
          \(Self.allowedPOSClause)
          AND w.is_common = 1
        ORDER BY RANDOM()
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var bindIndex: Int32 = 1
        for p in Self.allowedPOS {
            sqlite3_bind_text(stmt, bindIndex, p, -1, SQLITE_TRANSIENT_SWIFT)
            bindIndex += 1
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return rowToWord(stmt)
    }

    private func insertUsedWordLocked(wordID: String, at date: Date) -> Bool {
        guard let db else { return false }
        let sql = "INSERT OR IGNORE INTO used_words(word_id, used_at) VALUES(?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, wordID, -1, SQLITE_TRANSIENT_SWIFT)
        sqlite3_bind_int64(stmt, 2, Int64(date.timeIntervalSince1970))
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func insertScheduledPushLocked(
        identifier: String,
        fireAt: Date,
        slot: Int,
        wordID: String,
        createdAt: Date
    ) -> Bool {
        guard let db else { return false }
        let sql = """
        INSERT INTO scheduled_pushes(id, fire_at, slot, word_id, created_at)
        VALUES(?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, identifier, -1, SQLITE_TRANSIENT_SWIFT)
        sqlite3_bind_int64(stmt, 2, Int64(fireAt.timeIntervalSince1970))
        sqlite3_bind_int(stmt, 3, Int32(slot))
        sqlite3_bind_text(stmt, 4, wordID, -1, SQLITE_TRANSIENT_SWIFT)
        sqlite3_bind_int64(stmt, 5, Int64(createdAt.timeIntervalSince1970))
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    // MARK: - Schema / seeding

    private func openOrCreateDatabase() throws {
        let url = try databaseURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if sqlite3_open(url.path, &db) != SQLITE_OK {
            throw NSError(domain: "WordStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to open SQLite database at \(url.path)"
            ])
        }
    }

    private func createSchemaIfNeeded() throws {
        guard let db else { return }

        // Pragmas (don't fail the app if they error).
        _ = sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        _ = sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        _ = sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)

        try exec("""
        CREATE TABLE IF NOT EXISTS dictionary_version(value INTEGER NOT NULL);
        """)

        // Canonical table. ru_norm/en_norm are the FTS-indexable forms
        // (lowercased, ё→е). The display columns ru/en are kept verbatim.
        // is_common = 1 for the top frequency-list lemmas; push pool draws
        // only from common words while search reads the full table.
        try exec("""
        CREATE TABLE IF NOT EXISTS words(
          id         TEXT PRIMARY KEY,
          ru         TEXT NOT NULL,
          en         TEXT NOT NULL,
          meaning_en TEXT,
          pos        TEXT,
          glosses_en TEXT,
          ai_note_en TEXT,
          phonetic   TEXT,
          ru_norm    TEXT NOT NULL DEFAULT '',
          en_norm    TEXT NOT NULL DEFAULT '',
          is_common  INTEGER NOT NULL DEFAULT 0
        );
        """)

        try exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS words_fts USING fts5(
          id UNINDEXED,
          ru,
          en,
          tokenize = 'unicode61'
        );
        """)

        try exec("""
        CREATE TABLE IF NOT EXISTS used_words(
          word_id TEXT PRIMARY KEY,
          used_at INTEGER NOT NULL,
          FOREIGN KEY(word_id) REFERENCES words(id) ON DELETE CASCADE
        );
        """)

        // Legacy table from the slot-stable design. Kept so a `resetUsedWords()`
        // call on an upgraded DB can still wipe rows that were left behind.
        // No code reads or writes new rows into it.
        try exec("""
        CREATE TABLE IF NOT EXISTS scheduled_words(
          slot INTEGER PRIMARY KEY,
          word_id TEXT NOT NULL,
          assigned_at INTEGER NOT NULL,
          FOREIGN KEY(word_id) REFERENCES words(id) ON DELETE CASCADE
        );
        """)

        // Rolling buffer of upcoming non-repeating notifications. Each row
        // corresponds 1:1 to a `UNNotificationRequest` whose identifier is
        // `id` and whose word_id is in `userInfo["word_id"]`.
        try exec("""
        CREATE TABLE IF NOT EXISTS scheduled_pushes(
          id          TEXT PRIMARY KEY,
          fire_at     INTEGER NOT NULL,
          slot        INTEGER NOT NULL,
          word_id     TEXT NOT NULL,
          created_at  INTEGER NOT NULL,
          FOREIGN KEY(word_id) REFERENCES words(id) ON DELETE CASCADE
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_scheduled_pushes_fire_at ON scheduled_pushes(fire_at);")

        try exec("""
        CREATE TABLE IF NOT EXISTS recent_views(
          word_id   TEXT PRIMARY KEY,
          viewed_at INTEGER NOT NULL,
          FOREIGN KEY(word_id) REFERENCES words(id) ON DELETE CASCADE
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_recent_views_viewed_at ON recent_views(viewed_at DESC);")

        try exec("""
        CREATE TABLE IF NOT EXISTS word_enrichment(
          word_id    TEXT PRIMARY KEY,
          source     TEXT NOT NULL,
          fetched_at INTEGER NOT NULL,
          definitions TEXT NOT NULL DEFAULT '',
          examples    TEXT NOT NULL DEFAULT '',
          source_url  TEXT,
          FOREIGN KEY(word_id) REFERENCES words(id) ON DELETE CASCADE
        );
        """)

        // Keep words_fts in sync with words (insert/update/delete).
        // Drop+recreate so we can iterate on the trigger body across versions.
        _ = sqlite3_exec(db, "DROP TRIGGER IF EXISTS words_ai;", nil, nil, nil)
        _ = sqlite3_exec(db, "DROP TRIGGER IF EXISTS words_au;", nil, nil, nil)
        _ = sqlite3_exec(db, "DROP TRIGGER IF EXISTS words_ad;", nil, nil, nil)

        try exec("""
        CREATE TRIGGER words_ai AFTER INSERT ON words BEGIN
          INSERT INTO words_fts(id, ru, en) VALUES (new.id, new.ru_norm, new.en_norm);
        END;
        """)
        try exec("""
        CREATE TRIGGER words_au AFTER UPDATE ON words BEGIN
          DELETE FROM words_fts WHERE id = old.id;
          INSERT INTO words_fts(id, ru, en) VALUES (new.id, new.ru_norm, new.en_norm);
        END;
        """)
        try exec("""
        CREATE TRIGGER words_ad AFTER DELETE ON words BEGIN
          DELETE FROM words_fts WHERE id = old.id;
        END;
        """)

        // FTS backfill intentionally omitted: the bundled dictionary.sqlite already
        // has words_fts fully populated, and migrateBundledDictionaryIfNeeded() also
        // inserts into words_fts in one batch. The LEFT JOIN approach that was here
        // before was O(n²) on FTS5 (no B-tree index on the id column) and hung the
        // main thread for minutes with 37k rows.

        // One-time cleanup for upgrades from the eager-mark scheduler:
        // any row in used_words whose word is currently sitting in
        // scheduled_pushes was reserved-but-not-fired under the old behaviour.
        // Free those rows so the new defer-until-fire model is honoured.
        // On fresh installs and subsequent launches this is a no-op.
        try exec("""
        DELETE FROM used_words
        WHERE word_id IN (SELECT word_id FROM scheduled_pushes);
        """)
    }

    private func applyKnownDictionaryFixesIfNeeded() throws {
        guard let db else { return }

        // NOTE: We intentionally avoid broad runtime scrubs (e.g. deleting
        // inflected-form headwords) because they can add noticeable startup cost.
        // Instead, those are removed at build-time from the bundled dictionary,
        // and shipped via dictionary_version migrations.

        // Fix: bundled dictionary currently contains `помочь` as a noun ("belt"),
        // but for our app we want the common verb sense ("to help").
        // Apply as an in-place correction in the user's sandbox DB so we don't
        // require a full dictionary rebuild to resolve obvious mistakes.
        let ruNorm = normalizeForIndex("помочь")
        let desiredEn = "to help"
        let desiredPos = "verb"
        let desiredEnNorm = normalizeForIndex(desiredEn)
        let desiredMeaning = "to help"
        let desiredGlosses = "to help\nhelp\nassist"

        let sql = """
        UPDATE words
        SET en = ?, pos = ?, en_norm = ?, meaning_en = ?, glosses_en = ?
        WHERE ru_norm = ?
          AND (pos IS NULL OR lower(trim(pos)) = 'noun')
          AND lower(trim(en)) = 'belt';
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, desiredEn, -1, SQLITE_TRANSIENT_SWIFT)
        sqlite3_bind_text(stmt, 2, desiredPos, -1, SQLITE_TRANSIENT_SWIFT)
        sqlite3_bind_text(stmt, 3, desiredEnNorm, -1, SQLITE_TRANSIENT_SWIFT)
        sqlite3_bind_text(stmt, 4, desiredMeaning, -1, SQLITE_TRANSIENT_SWIFT)
        sqlite3_bind_text(stmt, 5, desiredGlosses, -1, SQLITE_TRANSIENT_SWIFT)
        sqlite3_bind_text(stmt, 6, ruNorm, -1, SQLITE_TRANSIENT_SWIFT)
        _ = sqlite3_step(stmt)

        // If we changed the underlying word, drop cached enrichment so it
        // re-fetches under the correct POS heuristics.
        _ = sqlite3_exec(db, "DELETE FROM word_enrichment WHERE word_id = 'pomoch';", nil, nil, nil)
    }

    /// On a fresh install (no `words.sqlite` in App Support) copies the bundled
    /// `dictionary.sqlite` into the sandbox on a background thread so the UI
    /// isn’t stalled by ~MB of disk I/O. Uses a `.partial` temp file + move.
    /// On an existing install this is a no-op and the migration runs instead.
    private func installBundledDictionaryIfMissing() async throws {
        let url = try databaseURL()
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            return
        }
        guard let bundled = Bundle.main.url(
            forResource: bundledDictionaryName,
            withExtension: bundledDictionaryExtension
        ) else {
            return
        }
        try fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let parent = url.deletingLastPathComponent()
        let tempURL = parent.appendingPathComponent("\(dbFileName).partial", isDirectory: false)

        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) { return }

            try? fm.removeItem(at: tempURL)
            try fm.copyItem(at: bundled, to: tempURL)

            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: tempURL)
                return
            }
            try fm.moveItem(at: tempURL, to: url)
        }.value
    }

    /// Reads the user's `dictionary_version`; if the table is missing or the
    /// value is older than what the bundled DB ships with (12), swaps the
    /// dictionary tables in a single transaction while preserving user-state
    /// tables (`used_words`, `scheduled_pushes`, `recent_views`).
    private func migrateBundledDictionaryIfNeeded() throws {
        guard let db else { return }

        let currentVersion = readDictionaryVersion()
        let targetVersion: Int = 18
        if currentVersion >= targetVersion {
            return
        }

        guard let bundled = Bundle.main.url(
            forResource: bundledDictionaryName,
            withExtension: bundledDictionaryExtension
        ) else {
            // No bundled DB available (dev). Leave existing data alone.
            return
        }

        // Foreign keys must be off across the table swap or DROP TABLE words
        // will cascade-delete every row in used_words / scheduled_pushes /
        // recent_views. We turn them back on (and clean up dangling refs)
        // after the swap completes.
        _ = sqlite3_exec(db, "PRAGMA foreign_keys=OFF;", nil, nil, nil)
        defer {
            _ = sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)
        }

        let attachSQL = "ATTACH DATABASE ? AS bundled;"
        var attachStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, attachSQL, -1, &attachStmt, nil) == SQLITE_OK else {
            throw NSError(domain: "WordStore", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "ATTACH prepare failed"
            ])
        }
        sqlite3_bind_text(attachStmt, 1, bundled.path, -1, SQLITE_TRANSIENT_SWIFT)
        let attachRC = sqlite3_step(attachStmt)
        sqlite3_finalize(attachStmt)
        guard attachRC == SQLITE_DONE else {
            throw NSError(domain: "WordStore", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "ATTACH bundled DB failed"
            ])
        }
        defer {
            _ = sqlite3_exec(db, "DETACH DATABASE bundled;", nil, nil, nil)
        }

        try exec("BEGIN IMMEDIATE;")
        try exec("DROP TRIGGER IF EXISTS words_ai;")
        try exec("DROP TRIGGER IF EXISTS words_au;")
        try exec("DROP TRIGGER IF EXISTS words_ad;")
        try exec("DROP TABLE  IF EXISTS words_fts;")
        try exec("DROP TABLE  IF EXISTS words;")
        try exec("""
        CREATE TABLE words(
          id         TEXT PRIMARY KEY,
          ru         TEXT NOT NULL,
          en         TEXT NOT NULL,
          meaning_en TEXT,
          pos        TEXT,
          glosses_en TEXT,
          ai_note_en TEXT,
          phonetic   TEXT,
          ru_norm    TEXT NOT NULL DEFAULT '',
          en_norm    TEXT NOT NULL DEFAULT '',
          is_common  INTEGER NOT NULL DEFAULT 0
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_words_is_common ON words(is_common) WHERE is_common = 1;")
        try exec("""
        INSERT INTO words(id, ru, en, meaning_en, pos, glosses_en, ai_note_en, phonetic,
                          ru_norm, en_norm, is_common)
        SELECT id, ru, en, meaning_en, pos, glosses_en, ai_note_en, phonetic,
               ru_norm, en_norm, is_common
        FROM bundled.words;
        """)
        try exec("""
        CREATE VIRTUAL TABLE words_fts USING fts5(
          id UNINDEXED,
          ru,
          en,
          tokenize = 'unicode61'
        );
        """)
        try exec("""
        INSERT INTO words_fts(id, ru, en)
        SELECT id, ru_norm, en_norm FROM words;
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS dictionary_version(value INTEGER NOT NULL);
        """)
        try exec("DELETE FROM dictionary_version;")
        try exec("INSERT INTO dictionary_version(value) VALUES (\(targetVersion));")
        try exec("COMMIT;")

        // Foreign keys were off across the swap, so any used_words /
        // scheduled_pushes / recent_views row whose word_id is no longer in
        // the new dictionary is now dangling. Clean those up explicitly so
        // the user doesn't see "ghost" entries on Manage Used Words.
        try exec("""
        DELETE FROM used_words
        WHERE word_id NOT IN (SELECT id FROM words);
        """)
        try exec("""
        DELETE FROM scheduled_pushes
        WHERE word_id NOT IN (SELECT id FROM words);
        """)
        try exec("""
        DELETE FROM recent_views
        WHERE word_id NOT IN (SELECT id FROM words);
        """)
    }

    private func readDictionaryVersion() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        let sql = "SELECT value FROM dictionary_version LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    private func databaseURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("RussianWordOfDay", isDirectory: true)
        return dir.appendingPathComponent(dbFileName)
    }

    /// Lowercase + ё→е. Used for both indexing and querying so the two stay aligned.
    private func normalizeForIndex(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "\u{0301}", with: "") // combining acute (stress mark)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the primary English line is Wiktionary morphology, not a dictionary gloss.
    private static func englishLooksLikeMorphSearchNoise(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.utf16.count >= 10 else { return false }
        let range = NSRange(location: 0, length: (t as NSString).length)
        for rx in morphEnglishSearchPatterns {
            if rx.firstMatch(in: t, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    /// Strip characters that are syntactically meaningful inside an FTS5 MATCH
    /// expression so user input can't accidentally form an invalid query.
    private func sanitizeFTSToken(_ s: String) -> String {
        let bad: Set<Character> = ["\"", "*", "(", ")", ":", "^", "+", "-"]
        return String(s.filter { !bad.contains($0) })
    }

    private func exec(_ sql: String) throws {
        guard let db else { return }
        var errPtr: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errPtr)
        if rc != SQLITE_OK {
            let msg = errPtr.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(errPtr)
            throw NSError(domain: "WordStore", code: Int(rc), userInfo: [
                NSLocalizedDescriptionKey: "SQLite exec failed: \(msg)\nSQL: \(sql)"
            ])
        }
    }

    private func rowToWord(_ stmt: OpaquePointer?) -> WordEntry {
        func colText(_ i: Int32) -> String {
            guard let c = sqlite3_column_text(stmt, i) else { return "" }
            return String(cString: c)
        }
        let id = colText(0)
        let ru = colText(1)
        let en = colText(2)
        let meaning = colText(3)
        let pos = colText(4)
        let glosses = colText(5)
        let aiNote = colText(6)
        let phon = colText(7)
        return WordEntry(
            id: id,
            russian: ru,
            english: en,
            meaning_en: meaning.isEmpty ? nil : meaning,
            pos: pos.isEmpty ? nil : pos,
            glosses_en: glosses.isEmpty ? nil : glosses,
            ai_note_en: aiNote.isEmpty ? nil : aiNote,
            phonetic: phon.isEmpty ? nil : phon
        )
    }

    private func storeEnrichment(
        wordID: String,
        source: String,
        fetchedAt: Date,
        definitions: [String],
        examples: [String],
        sourceURL: URL?
    ) {
        guard let db else { return }
        let defs = definitions.joined(separator: "\n")
        let ex = examples.joined(separator: "\n")
        let sql = """
        INSERT OR REPLACE INTO word_enrichment(word_id, source, fetched_at, definitions, examples, source_url)
        VALUES(?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, wordID, -1, SQLITE_TRANSIENT_SWIFT)
        sqlite3_bind_text(stmt, 2, source, -1, SQLITE_TRANSIENT_SWIFT)
        sqlite3_bind_int64(stmt, 3, Int64(fetchedAt.timeIntervalSince1970))
        sqlite3_bind_text(stmt, 4, defs, -1, SQLITE_TRANSIENT_SWIFT)
        sqlite3_bind_text(stmt, 5, ex, -1, SQLITE_TRANSIENT_SWIFT)
        if let s = sourceURL?.absoluteString {
            sqlite3_bind_text(stmt, 6, s, -1, SQLITE_TRANSIENT_SWIFT)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        _ = sqlite3_step(stmt)
    }
}
