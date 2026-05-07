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

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func ensureSeededIfNeeded() async {
        do {
            try installBundledDictionaryIfMissing()
            try openOrCreateDatabase()
            try migrateBundledDictionaryIfNeeded()
            try createSchemaIfNeeded()
            isReady = true
        } catch {
            isReady = false
        }
    }

    func search(query raw: String, limit: Int = 5) -> [WordEntry] {
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
        LEFT JOIN used_words u       ON u.word_id = w.id
        LEFT JOIN scheduled_pushes s ON s.word_id = w.id
        WHERE u.word_id IS NULL
          AND s.word_id IS NULL
          AND w.is_common = 1;
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
    func recentViews(limit: Int = 5) -> [WordEntry] {
        guard let db else { return [] }
        let sql = """
        SELECT w.id, w.ru, w.en, w.meaning_en, w.phonetic
        FROM recent_views r
        JOIN words w ON w.id = r.word_id
        ORDER BY r.viewed_at DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

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
        SELECT w.id, w.ru, w.en, w.meaning_en, w.phonetic
        FROM words w
        LEFT JOIN used_words u       ON u.word_id = w.id
        LEFT JOIN scheduled_pushes s ON s.word_id = w.id
        WHERE u.word_id IS NULL
          AND s.word_id IS NULL
          AND w.is_common = 1
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

    /// On a fresh install (no `words.sqlite` in App Support) copies the bundled
    /// `dictionary.sqlite` directly into the sandbox. The migration step then
    /// becomes a no-op because the bundled DB already stamps `dictionary_version = 3`.
    /// On an existing install this is a no-op and the migration runs instead.
    private func installBundledDictionaryIfMissing() throws {
        let url = try databaseURL()
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            return
        }
        guard let bundled = Bundle.main.url(
            forResource: bundledDictionaryName,
            withExtension: bundledDictionaryExtension
        ) else {
            // Allowed (dev builds may run without the asset). The migration
            // step will then leave the user with an empty `words` table.
            return
        }
        try fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fm.copyItem(at: bundled, to: url)
    }

    /// Reads the user's `dictionary_version`; if the table is missing or the
    /// value is older than what the bundled DB ships with (2), swaps the
    /// dictionary tables in a single transaction while preserving user-state
    /// tables (`used_words`, `scheduled_pushes`, `recent_views`).
    private func migrateBundledDictionaryIfNeeded() throws {
        guard let db else { return }

        let currentVersion = readDictionaryVersion()
        let targetVersion: Int = 3
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
          phonetic   TEXT,
          ru_norm    TEXT NOT NULL DEFAULT '',
          en_norm    TEXT NOT NULL DEFAULT '',
          is_common  INTEGER NOT NULL DEFAULT 0
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_words_is_common ON words(is_common) WHERE is_common = 1;")
        try exec("""
        INSERT INTO words(id, ru, en, meaning_en, phonetic,
                          ru_norm, en_norm, is_common)
        SELECT id, ru, en, meaning_en, phonetic,
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
