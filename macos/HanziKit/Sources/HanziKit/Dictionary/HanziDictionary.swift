import Foundation
import SQLite3

/// Read-only access to the bundled `hanzi.sqlite` (built by `scripts/build_dictionary.py`):
/// CC-CEDICT + CVDICT entries, Hán Việt and Mandarin character readings, example sentences.
public final class HanziDictionary: @unchecked Sendable {
    public enum OpenError: LocalizedError {
        case cannotOpen(String)
        case incompatible(String)

        public var errorDescription: String? {
            switch self {
            case .cannotOpen(let message): "Couldn't open the dictionary: \(message)"
            case .incompatible(let message): "The dictionary file is incompatible: \(message)"
            }
        }
    }

    /// Schema version this code understands (see build_dictionary.py).
    public static let schemaVersion = 1

    private var db: OpaquePointer?
    private let lock = NSLock()
    private var statements: [String: OpaquePointer] = [:]
    private var entryCache: [String: [DictionaryEntry]] = [:]
    /// Longest headword length (in characters), to bound substring searches.
    public private(set) var maxWordLength = 8
    public private(set) var metadata: [String: String] = [:]

    public init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw OpenError.cannotOpen(message)
        }
        db = handle
        metadata = Dictionary(uniqueKeysWithValues: rows("SELECT key, value FROM meta", []) { ($0.text(0), $0.text(1)) })
        guard Int(metadata["schema_version"] ?? "") == Self.schemaVersion else {
            throw OpenError.incompatible("schema \(metadata["schema_version"] ?? "?") ≠ \(Self.schemaVersion)")
        }
        maxWordLength = Int(metadata["max_word_length"] ?? "") ?? 8
    }

    deinit {
        for (_, statement) in statements { sqlite3_finalize(statement) }
        sqlite3_close(db)
    }

    // MARK: - Entries

    /// All entries whose simplified or traditional form is `word`, most useful first:
    /// common words before proper nouns, HSK words and frequent readings first.
    public func entries(for word: String) -> [DictionaryEntry] {
        guard !word.isEmpty else { return [] }
        lock.lock()
        if let cached = entryCache[word] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let found = rows("""
            SELECT id, trad, simp, pinyin, vi, en, hsk, freq, hv FROM entries WHERE simp = ?1
            UNION
            SELECT id, trad, simp, pinyin, vi, en, hsk, freq, hv FROM entries WHERE trad = ?1
            """, [word]) { row in
            DictionaryEntry(id: row.int64(0), traditional: row.text(1), simplified: row.text(2), pinyin: row.text(3),
                            vietnamese: Self.senses(row.optionalText(4)), english: Self.senses(row.optionalText(5)),
                            hskLevel: row.optionalInt(6), frequency: Int(row.int64(7)),
                            hanViet: row.optionalText(8).map { $0.components(separatedBy: "|") } ?? [])
        }
        // One entry per reading: merge duplicates such as 了解 (了解) and 了解 (瞭解).
        var byReading: [String: DictionaryEntry] = [:]
        var readingOrder: [String] = []
        for entry in found.sorted(by: Self.isMoreUseful) {
            if let existing = byReading[entry.pinyin] {
                byReading[entry.pinyin] = existing.merged(with: entry)
            } else {
                byReading[entry.pinyin] = entry
                readingOrder.append(entry.pinyin)
            }
        }
        let sorted = readingOrder.compactMap { byReading[$0] }

        lock.lock()
        if entryCache.count > 4000 { entryCache.removeAll(keepingCapacity: true) }
        entryCache[word] = sorted
        lock.unlock()
        return sorted
    }

    public func contains(_ word: String) -> Bool {
        !entries(for: word).isEmpty
    }

    static func isMoreUseful(_ a: DictionaryEntry, _ b: DictionaryEntry) -> Bool {
        if a.isProperNoun != b.isProperNoun { return !a.isProperNoun }
        if (a.hskLevel != nil) != (b.hskLevel != nil) { return a.hskLevel != nil }
        if a.frequency != b.frequency { return a.frequency > b.frequency }
        let aSenses = a.vietnamese.count + a.english.count, bSenses = b.vietnamese.count + b.english.count
        if aSenses != bSenses { return aSenses > bSenses }
        return a.id < b.id
    }

    /// Longest dictionary word starting at the beginning of `text` (Zhongwen-style lookup).
    public func longestPrefixMatch(in text: Substring) -> (length: Int, entries: [DictionaryEntry])? {
        let characters = Array(text.prefix(maxWordLength))
        for length in stride(from: characters.count, through: 1, by: -1) {
            let candidate = String(characters[0..<length])
            let found = entries(for: candidate)
            if !found.isEmpty { return (length, found) }
        }
        return nil
    }

    private static func senses(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    // MARK: - Characters

    /// Hán Việt readings of a character, most common first ("学" → ["học"], "行" → ["hành", "hàng", "hạnh", "hạng"]).
    public func hanViet(for character: Character) -> [String] {
        characterRow(character)?.hanViet ?? []
    }

    /// The Hán Việt reading that corresponds to one specific Mandarin reading of a polyphonic character:
    /// ("行", "háng") → "hàng" but ("行", "xíng") → "hành". Nil when the data has no specific mapping.
    public func hanViet(for character: Character, pinyin: String) -> String? {
        let key = Pinyin.comparisonKey(pinyin) + String(Pinyin.tone(ofMarked: pinyin))
        return rows("SELECT hanviet FROM char_readings WHERE ch = ?1 AND pinyin = ?2", [String(character), key]) {
            $0.text(0)
        }.first
    }

    /// Most common Mandarin reading of a character, tone-marked ("行" → "xíng").
    public func mandarin(for character: Character) -> String? {
        characterRow(character)?.mandarin
    }

    private struct CharacterRow {
        let hanViet: [String]
        let mandarin: String?
    }

    private var characterCache: [Character: CharacterRow?] = [:]

    private func characterRow(_ character: Character) -> CharacterRow? {
        lock.lock()
        if let cached = characterCache[character] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let row = rows("SELECT hanviet, pinyin FROM chars WHERE ch = ?1", [String(character)]) { row in
            CharacterRow(hanViet: (row.optionalText(0) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty },
                         mandarin: row.optionalText(1))
        }.first
        lock.lock()
        characterCache[character] = row
        lock.unlock()
        return row
    }

    // MARK: - Examples & grammar

    /// Example sentences containing `word` (matched in simplified form, so traditional sentences are found too).
    /// Sentences with a Vietnamese translation come first, then the shortest (simplest) ones.
    public func examples(containing word: String, limit: Int = 3) -> [ExampleSentence] {
        guard !word.isEmpty else { return [] }
        let simplified = entries(for: word).first?.simplified ?? word
        let pattern = "%" + simplified.replacingOccurrences(of: "%", with: "") + "%"
        return rows("""
            SELECT id, zh, vi, en, author FROM sentences WHERE zh_s LIKE ?1
            ORDER BY (vi IS NULL), abs(length(zh) - 12), id LIMIT ?2
            """, [pattern, String(limit)]) { row in
            ExampleSentence(id: row.int64(0), chinese: row.text(1), vietnamese: row.optionalText(2),
                            english: row.optionalText(3), author: row.optionalText(4))
        }
    }

    /// Whether the Chinese Grammar Wiki (AllSet Learning) has a grammar page for this word.
    public func hasGrammarPage(_ word: String) -> Bool {
        !rows("SELECT 1 FROM grammar WHERE word = ?1", [word]) { _ in true }.isEmpty
    }

    // MARK: - SQLite plumbing

    struct Row {
        let statement: OpaquePointer
        func text(_ column: Int32) -> String { optionalText(column) ?? "" }
        func optionalText(_ column: Int32) -> String? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL, let pointer = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: pointer)
        }
        func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func optionalInt(_ column: Int32) -> Int? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, column))
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func rows<T>(_ sql: String, _ arguments: [String], map: (Row) -> T) -> [T] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
        } else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { return [] }
            statements[sql] = prepared
            statement = prepared
        }
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (index, argument) in arguments.enumerated() {
            if let number = Int64(argument), sql.contains("LIMIT ?\(index + 1)") {
                sqlite3_bind_int64(statement, Int32(index + 1), number)
            } else {
                sqlite3_bind_text(statement, Int32(index + 1), argument, -1, Self.transient)
            }
        }
        var results: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(map(Row(statement: statement)))
        }
        return results
    }
}
