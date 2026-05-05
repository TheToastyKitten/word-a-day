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
    private let seedResourceName = "words.seed"

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func ensureSeededIfNeeded() async {
        do {
            try openOrCreateDatabase()
            try createSchemaIfNeeded()
            try seedIfNeeded()
            isReady = true
        } catch {
            isReady = false
        }
    }

    func search(query raw: String, limit: Int = 20) -> [WordEntry] {
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

        let sql = """
        SELECT w.id, w.ru, w.en, w.meaning_en, w.phonetic
        FROM words_fts f
        JOIN words w ON w.id = f.id
        WHERE words_fts MATCH ?
        ORDER BY bm25(words_fts)
        LIMIT ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, ftsQuery, -1, SQLITE_TRANSIENT_SWIFT)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var out: [WordEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(rowToWord(stmt))
        }
        return out
    }

    func getWord(id: String) -> WordEntry? {
        guard let db else { return nil }
        let sql = "SELECT id, ru, en, meaning_en, phonetic FROM words WHERE id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT_SWIFT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return rowToWord(stmt)
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
        LEFT JOIN used_words u ON u.word_id = w.id
        WHERE u.word_id IS NULL;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
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
        SELECT u.word_id, u.used_at, w.ru, w.en, w.meaning_en, w.phonetic
        FROM used_words u
        JOIN words w ON w.id = u.word_id
        ORDER BY u.used_at DESC
        LIMIT ? OFFSET ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        sqlite3_bind_int(stmt, 2, Int32(offset))

        var out: [UsedWord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let usedAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1)))
            let ru = String(cString: sqlite3_column_text(stmt, 2))
            let en = String(cString: sqlite3_column_text(stmt, 3))
            let meaning = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let phonetic = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            let word = WordEntry(
                id: id,
                russian: ru,
                english: en,
                meaning_en: (meaning?.isEmpty == false) ? meaning : nil,
                phonetic: (phonetic?.isEmpty == false) ? phonetic : nil
            )
            out.append(UsedWord(word: word, usedAt: usedAt))
        }
        return out
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

    /// Picks a random unused word AND inserts a `scheduled_pushes` row
    /// AND inserts into `used_words`, in a single transaction. Returns the
    /// newly-built `ScheduledPush` plus the `WordEntry`, or nil if the
    /// dictionary is exhausted.
    ///
    /// The atomicity here matters: we never want a half-state where a word
    /// is in `used_words` but not yet in `scheduled_pushes` (that would
    /// permanently waste it).
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
        guard insertUsedWordLocked(wordID: word.id, at: now),
              insertScheduledPushLocked(
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
    /// the spec is explicit that words committed to the buffer remain "used"
    /// even after a settings-change rebuild, so the same word can't reappear.
    /// Caller is responsible for cancelling matching `UN` requests.
    func clearScheduledPushes() {
        guard let db else { return }
        _ = sqlite3_exec(db, "DELETE FROM scheduled_pushes;", nil, nil, nil)
    }

    /// Removes scheduled push rows whose `fire_at` is in the past, since
    /// iOS has already delivered (or dropped) them. Keeps the buffer count
    /// honest for top-up math.
    func purgePastScheduledPushes(now: Date = Date()) {
        guard let db else { return }
        let sql = "DELETE FROM scheduled_pushes WHERE fire_at <= ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(now.timeIntervalSince1970))
        _ = sqlite3_step(stmt)
    }

    // MARK: - Locked helpers (must run inside an open transaction)

    private func pickRandomUnusedLocked() -> WordEntry? {
        guard let db else { return nil }
        let sql = """
        SELECT w.id, w.ru, w.en, w.meaning_en, w.phonetic
        FROM words w
        LEFT JOIN used_words u ON u.word_id = w.id
        WHERE u.word_id IS NULL
        ORDER BY RANDOM()
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
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

        // Canonical table. ru_norm/en_norm are the FTS-indexable forms
        // (lowercased, ё→е). The display columns ru/en are kept verbatim.
        try exec("""
        CREATE TABLE IF NOT EXISTS words(
          id         TEXT PRIMARY KEY,
          ru         TEXT NOT NULL,
          en         TEXT NOT NULL,
          meaning_en TEXT,
          phonetic   TEXT,
          ru_norm    TEXT NOT NULL DEFAULT '',
          en_norm    TEXT NOT NULL DEFAULT ''
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

        // Backfill FTS for any rows that exist in `words` but not in `words_fts`
        // (covers upgrades from older builds where the trigger didn't exist yet).
        try exec("""
        INSERT INTO words_fts(id, ru, en)
        SELECT w.id, w.ru_norm, w.en_norm
        FROM words w
        LEFT JOIN words_fts f ON f.id = w.id
        WHERE f.id IS NULL;
        """)
    }

    /// Idempotent seeding: insert every entry from the bundled JSON using
    /// INSERT OR IGNORE so re-running does nothing for rows already present,
    /// and new rows added to the seed in a future build are picked up.
    private func seedIfNeeded() throws {
        guard let db else { return }

        guard let url = Bundle.main.url(forResource: seedResourceName, withExtension: "json") else {
            // No bundled seed — nothing to do, but not fatal.
            return
        }
        let data = try Data(contentsOf: url)
        let entries = try JSONDecoder().decode([SeedWordEntry].self, from: data)

        let insertSQL = """
        INSERT OR IGNORE INTO words(id, ru, en, meaning_en, phonetic, ru_norm, en_norm)
        VALUES(?, ?, ?, ?, ?, ?, ?);
        """
        var insertStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else {
            throw NSError(domain: "WordStore", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Failed to prepare seed insert"
            ])
        }
        defer { sqlite3_finalize(insertStmt) }

        _ = sqlite3_exec(db, "BEGIN;", nil, nil, nil)
        for e in entries {
            sqlite3_reset(insertStmt)
            sqlite3_clear_bindings(insertStmt)

            sqlite3_bind_text(insertStmt, 1, e.id, -1, SQLITE_TRANSIENT_SWIFT)
            sqlite3_bind_text(insertStmt, 2, e.russian, -1, SQLITE_TRANSIENT_SWIFT)
            sqlite3_bind_text(insertStmt, 3, e.english, -1, SQLITE_TRANSIENT_SWIFT)

            if let m = e.meaning_en, !m.isEmpty {
                sqlite3_bind_text(insertStmt, 4, m, -1, SQLITE_TRANSIENT_SWIFT)
            } else {
                sqlite3_bind_null(insertStmt, 4)
            }
            if let p = e.phonetic, !p.isEmpty {
                sqlite3_bind_text(insertStmt, 5, p, -1, SQLITE_TRANSIENT_SWIFT)
            } else {
                sqlite3_bind_null(insertStmt, 5)
            }

            let ruNorm = normalizeForIndex(e.russian)
            let enNorm = normalizeForIndex(e.english)
            sqlite3_bind_text(insertStmt, 6, ruNorm, -1, SQLITE_TRANSIENT_SWIFT)
            sqlite3_bind_text(insertStmt, 7, enNorm, -1, SQLITE_TRANSIENT_SWIFT)

            _ = sqlite3_step(insertStmt)
        }
        _ = sqlite3_exec(db, "COMMIT;", nil, nil, nil)

        // Note: we deliberately do NOT manually insert into words_fts here —
        // the AFTER INSERT trigger handles new rows, and createSchemaIfNeeded()
        // backfills any pre-existing rows that were missing from FTS.
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
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        let phon = colText(4)
        return WordEntry(
            id: id,
            russian: ru,
            english: en,
            meaning_en: meaning.isEmpty ? nil : meaning,
            phonetic: phon.isEmpty ? nil : phon
        )
    }
}
