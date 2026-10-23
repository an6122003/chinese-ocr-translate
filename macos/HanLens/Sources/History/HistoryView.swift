import AppKit
import HanziKit
import SwiftUI
import UniformTypeIdentifiers

/// The History window: search past lookups, look one up again, export to Anki.
struct HistoryView: View {
    @Bindable var store: HistoryStore
    var onLookUp: (String) -> Void

    @State private var query = ""
    @State private var selection = Set<HistoryItem.ID>()

    private var filtered: [HistoryItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.items }
        let key = Pinyin.comparisonKey(query)
        return store.items.filter { item in
            item.text.localizedCaseInsensitiveContains(query)
                || (item.translation ?? "").localizedCaseInsensitiveContains(query)
                || item.pinyin.localizedCaseInsensitiveContains(query)
                || (!key.isEmpty && Pinyin.comparisonKey(item.pinyin).contains(key))
        }
    }

    var body: some View {
        Group {
            if store.items.isEmpty {
                ContentUnavailableView("No lookups yet",
                                       systemImage: "clock.arrow.circlepath",
                                       description: Text("Text you capture or look up appears here."))
            } else {
                List(selection: $selection) {
                    ForEach(filtered) { item in
                        HistoryRow(item: item)
                            .tag(item.id)
                            .contextMenu { menu(for: item) }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: HistoryItem.ID.self) { _ in
                } primaryAction: { ids in
                    if let id = ids.first, let item = store.items.first(where: { $0.id == id }) { onLookUp(item.text) }
                }
                .onDeleteCommand { store.remove(selection) }
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search Chinese, pinyin or meaning")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    export()
                } label: {
                    Label("Export for Anki…", systemImage: "square.and.arrow.up")
                }
                .help("Export as a tab-separated file (Chinese · pinyin · translation) for Anki")
                .disabled(store.items.isEmpty)
                Button(role: .destructive) {
                    confirmClear()
                } label: {
                    Label("Clear History", systemImage: "trash")
                }
                .disabled(store.items.isEmpty)
            }
        }
        .frame(minWidth: 520, minHeight: 380)
    }

    @ViewBuilder
    private func menu(for item: HistoryItem) -> some View {
        Button("Look Up Again") { onLookUp(item.text) }
        Button("Copy Chinese") { copy(item.text) }
        Button("Copy Pinyin") { copy(item.pinyin) }
        if let translation = item.translation { Button("Copy Translation") { copy(translation) } }
        Divider()
        Button("Delete", role: .destructive) { store.remove([item.id]) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "HanLens words.txt"
        panel.allowedContentTypes = [.tabSeparatedText, .plainText]
        panel.message = "Import into Anki with File › Import (fields separated by Tab)."
        let items = selection.isEmpty ? nil : store.items.filter { selection.contains($0.id) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? store.exportTSV(items).write(to: url, atomically: true, encoding: .utf8)
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Clear all history?"
        alert.informativeText = "This removes every saved lookup from this Mac."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { store.clear() }
    }
}

private struct HistoryRow: View {
    let item: HistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.text)
                    .font(HanFont.font(size: 17))
                    .lineLimit(2)
                Spacer()
                Text(item.date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !item.pinyin.isEmpty {
                Text(item.pinyin)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let translation = item.translation {
                Text(translation)
                    .font(.callout)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }
}
