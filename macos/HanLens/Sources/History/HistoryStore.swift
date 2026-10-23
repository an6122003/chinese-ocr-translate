import AppKit
import Foundation
import Observation

/// One past lookup. (`nonisolated` so it can be encoded off the main actor.)
nonisolated struct HistoryItem: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var date: Date
    var text: String
    var pinyin: String
    var translation: String?
    var source: String
}

/// Recent lookups, stored as JSON in ~/Library/Application Support/HanLens/history.json.
@Observable
final class HistoryStore {
    static let shared = HistoryStore()

    private(set) var items: [HistoryItem] = []
    @ObservationIgnored private let url: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private let limit = 1000

    init(url: URL? = nil) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HanLens", isDirectory: true)
        self.url = url ?? directory.appendingPathComponent("history.json")
        load()
    }

    /// Adds a lookup, or refreshes the newest one when the same text is looked up again.
    func record(text: String, pinyin: String, translation: String?, source: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let index = items.firstIndex(where: { $0.text == text }) {
            var item = items.remove(at: index)
            item.date = Date()
            item.pinyin = pinyin
            if let translation { item.translation = translation }
            items.insert(item, at: 0)
        } else {
            items.insert(HistoryItem(date: Date(), text: text, pinyin: pinyin, translation: translation, source: source), at: 0)
            if items.count > limit { items.removeLast(items.count - limit) }
        }
        scheduleSave()
    }

    func remove(_ ids: Set<HistoryItem.ID>) {
        items.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    func clear() {
        items.removeAll()
        scheduleSave()
    }

    /// Tab-separated "Chinese, pinyin, translation" — imports straight into Anki.
    func exportTSV(_ selection: [HistoryItem]? = nil) -> String {
        let clean = { (value: String) in value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: "<br>") }
        return (selection ?? items).map { item in
            [clean(item.text), clean(item.pinyin), clean(item.translation ?? "")].joined(separator: "\t")
        }.joined(separator: "\n") + "\n"
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([HistoryItem].self, from: data)) ?? []
    }

    /// Writes immediately (used when quitting, so a pending save isn't lost).
    func saveNow() {
        guard let saveTask else { return }
        saveTask.cancel()
        self.saveTask = nil
        Self.writeSync(items, to: url)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = items
        let url = url
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await Self.write(snapshot, to: url)
            if !Task.isCancelled { saveTask = nil }
        }
    }

    @concurrent
    private static func write(_ items: [HistoryItem], to url: URL) async {
        writeSync(items, to: url)
    }

    private nonisolated static func writeSync(_ items: [HistoryItem], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(items).write(to: url, options: .atomic)
        } catch {
            Log.app.error("Couldn't save history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
