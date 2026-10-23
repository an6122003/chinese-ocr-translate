import HanziKit
import SwiftUI

/// The content of a result panel.
struct ResultView: View {
    @Bindable var model: LookupModel
    var maxHeight: CGFloat
    var onClose: () -> Void
    var onHeightChange: (CGFloat) -> Void
    var onCaptureAgain: () -> Void

    @State private var contentHeight: CGFloat = 120
    @State private var headerHeight: CGFloat = 38
    @State private var footerHeight: CGFloat = 46

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(model: model, onClose: onClose)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0; report() }
            Divider().opacity(0.6)
            ScrollView {
                content
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0; report() }
            }
            .scrollIndicators(.automatic)
            .frame(height: scrollHeight)
            if model.status == .ready {
                Divider().opacity(0.6)
                FooterBar(model: model)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0; report() }
            }
        }
        .background(.regularMaterial)
    }

    private var scrollHeight: CGFloat {
        let chrome = headerHeight + (model.status == .ready ? footerHeight : 0) + 2
        return max(60, min(contentHeight, maxHeight - chrome))
    }

    private func report() {
        let chrome = headerHeight + (model.status == .ready ? footerHeight : 0) + 2
        onHeightChange(chrome + scrollHeight)
    }

    @ViewBuilder
    private var content: some View {
        switch model.status {
        case .recognizing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Recognizing text…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        case .noText(let message):
            MessageView(symbol: "text.viewfinder", message: message) {
                Button("Capture Again", action: onCaptureAgain)
                Button("Type Text Instead") { model.startTyping() }
            }
        case .failed(let message):
            MessageView(symbol: "exclamationmark.triangle", message: message) {
                Button("Capture Again", action: onCaptureAgain)
            }
        case .ready:
            if model.isEditing {
                EditorView(model: model)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    InterlinearView(model: model)
                    if model.analysis.containsChinese || !model.text.isEmpty {
                        TranslationCard(model: model)
                    }
                    if let word = model.focusedWord {
                        WordDetailView(model: model, segment: word)
                    } else if model.analysis.uniqueWords.count > 1 {
                        WordListView(model: model)
                    }
                }
            }
        }
    }
}

// MARK: - Header & footer

private struct HeaderBar: View {
    @Bindable var model: LookupModel
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.source.symbol)
                .foregroundStyle(.secondary)
            Text(model.source.label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            if model.isFollowing {
                FollowingBadge()
            }
            Spacer()
            Button {
                model.isPinned.toggle()
            } label: {
                Image(systemName: model.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(model.isPinned ? Color.accentColor : .secondary)
            }
            .help(model.isPinned ? "Unpin — close when clicking elsewhere" : "Pin — keep this panel open")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .help("Close (esc)")
        }
        .buttonStyle(.borderless)
        .imageScale(.medium)
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 38)
    }
}

private struct FooterBar: View {
    @Bindable var model: LookupModel
    @State private var copied: String?

    private var speaker: Speaker { Speaker.shared }
    private var isSpeakingThis: Bool { speaker.isSpeaking && speaker.spokenText == model.analysis.text }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if isSpeakingThis { speaker.stop() } else { speaker.speak(model.text) }
            } label: {
                Label(isSpeakingThis ? "Stop" : "Speak", systemImage: isSpeakingThis ? "stop.fill" : "speaker.wave.2.fill")
            }
            .keyboardShortcut(model.isEditing ? nil : KeyboardShortcut(.space, modifiers: []))
            .help("Read aloud (space)")

            Button {
                speaker.speak(model.text, slow: true)
            } label: {
                Image(systemName: "tortoise.fill")
            }
            .help("Read slowly")

            if model.canFollow {
                Button {
                    model.isFollowing ? model.stopFollowing() : model.startFollowing()
                } label: {
                    Label(model.isFollowing ? "Stop" : "Follow",
                          systemImage: model.isFollowing ? "eye.slash" : "eye")
                }
                .help(model.isFollowing
                      ? "Stop following this area"
                      : "Keep reading this area of the screen — great for video subtitles (⌘F)")
                .keyboardShortcut("f", modifiers: .command)
            }

            Spacer()

            copyButton(id: "text", title: "Copy", symbol: "doc.on.doc", help: "Copy the Chinese text (⇧⌘C)") { model.text }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            copyButton(id: "pinyin", title: "Pinyin", symbol: "textformat.abc", help: "Copy pinyin") { model.analysis.pinyinText }
            if let translated = model.translatedText {
                copyButton(id: "translation", title: "Translation", symbol: "character.bubble", help: "Copy the translation") { translated }
            }

            Menu {
                Button("Edit Text  ⌘E") { model.beginEditing() }
                Divider()
                ForEach(ExternalDictionary.allCases) { site in
                    Button("Open in \(site.name)") { site.open(model.focusedWord?.text ?? model.text) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private func copyButton(id: String, title: String, symbol: String, help: String, value: @escaping () -> String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value(), forType: .string)
            copied = id
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                if copied == id { copied = nil }
            }
        } label: {
            Label(copied == id ? "Copied" : title, systemImage: copied == id ? "checkmark" : symbol)
        }
        .help(help)
    }
}

/// A pulsing "LIVE" marker shown while a panel follows a screen area.
private struct FollowingBadge: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
                .opacity(pulse ? 0.35 : 1)
            Text("LIVE")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.red)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.red.opacity(0.12)))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
        .help("Following this area of the screen")
    }
}

// MARK: - Interlinear text

private struct InterlinearView: View {
    let model: LookupModel

    var body: some View {
        let settings = model.settings
        let speaker = Speaker.shared
        let spoken = speaker.spokenText == model.analysis.text ? speaker.spokenRange : nil
        let speakingIDs = spoken.map { model.analysis.segmentIDs(overlapping: $0) } ?? []
        let traditional = CJK.looksTraditional(model.text) == true

        FlowLayout(spacing: 1, rowSpacing: 6) {
            ForEach(model.analysis.segments) { segment in
                switch segment.kind {
                case .newline:
                    Color.clear.frame(width: 0, height: 0).layoutValue(key: FlowLineBreak.self, value: true)
                case .space:
                    Color.clear.frame(width: 7, height: 1)
                default:
                    WordChip(segment: segment,
                             isSelected: model.selectedSegmentID == segment.id,
                             isSpeaking: speakingIDs.contains(segment.id),
                             showPinyin: settings.showPinyin,
                             showHanViet: settings.showHanViet,
                             toneColors: settings.toneColors,
                             traditional: traditional,
                             gloss: segment.bestEntry?.shortGloss(preferring: settings.targetLanguage) ?? "")
                        .onTapGesture { withAnimation(.snappy(duration: 0.18)) { model.toggleSelection(segment) } }
                }
            }
        }
        .textSelection(.disabled)
    }
}

private struct WordChip: View {
    let segment: Segment
    let isSelected: Bool
    let isSpeaking: Bool
    let showPinyin: Bool
    let showHanViet: Bool
    let toneColors: Bool
    let traditional: Bool
    let gloss: String

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            if showPinyin {
                Group {
                    if segment.isWord {
                        ToneStyle.pinyin(segment.syllables, colored: toneColors)
                    } else {
                        Text(" ")
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .frame(height: 16)
            }
            Text(segment.text)
                .font(segment.kind == .latin ? .system(size: 19) : HanFont.font(size: 25, traditional: traditional))
                .frame(height: 33)
            if showHanViet {
                Text(segment.isWord ? segment.hanVietText : " ")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(height: 14)
            }
        }
        .fixedSize()
        .padding(.horizontal, segment.isWord ? 4 : 0.5)
        .padding(.vertical, 2)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(background)
        }
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { isHovering = segment.isWord && $0 }
        .help(segment.isWord ? gloss : "")
    }

    private var background: Color {
        if isSpeaking { return Color.yellow.opacity(0.35) }
        if isSelected { return Color.accentColor.opacity(0.22) }
        if isHovering { return Color.primary.opacity(0.07) }
        return .clear
    }
}

// MARK: - Translation

private struct TranslationCard: View {
    @Bindable var model: LookupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(model.settings.targetLanguage == .vietnamese ? "🇻🇳" : "🇬🇧")
                Text(model.settings.targetLanguage.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(TranslationEngine.allCases) { engine in
                        Button(engine.displayName) { model.translate(using: engine) }
                    }
                } label: {
                    Text(engineLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Translate again with another engine")
            }
            switch model.translation {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Translating…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(minHeight: 22)
            case .done(let output):
                Text(output.text)
                    .font(.system(size: 15))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Text(message).font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") { model.translate() }
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private var engineLabel: String {
        if case .done(let output) = model.translation { return output.engine.displayName }
        return model.settings.translationEngine.displayName
    }
}

// MARK: - Word list

private struct WordListView: View {
    @Bindable var model: LookupModel
    @State private var showAll = false

    var body: some View {
        let words = model.analysis.uniqueWords
        let shown = showAll ? words : Array(words.prefix(24))
        let settings = model.settings
        VStack(alignment: .leading, spacing: 2) {
            Text("Words")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            ForEach(shown) { word in
                Button {
                    withAnimation(.snappy(duration: 0.18)) { model.selectedSegmentID = word.id }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(word.text)
                            .font(HanFont.font(size: 17))
                            .frame(minWidth: 40, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                ToneStyle.pinyin(word.syllables, colored: settings.toneColors)
                                    .font(.system(size: 13, weight: .medium))
                                if settings.showHanViet, !word.hanVietText.isEmpty {
                                    Text(word.hanVietText)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(word.bestEntry?.shortGloss(preferring: settings.targetLanguage) ?? "—")
                                .font(.system(size: 13))
                                .foregroundStyle(.primary.opacity(0.85))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        if let level = word.bestEntry?.hskLevel {
                            HSKBadge(level: level)
                        }
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
            }
            if words.count > shown.count {
                Button("Show all \(words.count) words") { showAll = true }
                    .buttonStyle(.link)
                    .font(.callout)
                    .padding(.top, 4)
            }
        }
    }
}

struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.06 : 0))
                )
                .onHover { hovering = $0 }
        }
    }
}

struct HSKBadge: View {
    let level: Int

    var body: some View {
        Text(level >= 7 ? "HSK 7–9" : "HSK \(level)")
            .font(.system(size: 9.5, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(.white)
            .background(Capsule().fill(color))
            .fixedSize()
    }

    private var color: Color {
        switch level {
        case 1...2: .green
        case 3...4: .teal
        case 5...6: .blue
        default: .purple
        }
    }
}

// MARK: - Editing & messages

private struct EditorView: View {
    @Bindable var model: LookupModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.text.isEmpty ? "Type or paste Chinese text" : "Fix the recognized text")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $model.draft)
                .font(HanFont.font(size: 20))
                .frame(minHeight: 70, maxHeight: 180)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                .focused($focused)
            HStack {
                Text("⌘↩ to look up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.text.isEmpty {
                    Button("Cancel") { model.cancelEditing() }
                }
                Button("Look Up") { model.commitEditing() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .onAppear { focused = true }
    }
}

private struct MessageView<Actions: View>: View {
    let symbol: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack { actions }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

// MARK: - External dictionaries

enum ExternalDictionary: String, CaseIterable, Identifiable {
    case hanzii, googleTranslate, mdbg

    var id: String { rawValue }

    var name: String {
        switch self {
        case .hanzii: "Hanzii"
        case .googleTranslate: "Google Translate"
        case .mdbg: "MDBG"
        }
    }

    func url(for text: String) -> URL? {
        let query = text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#&"))) ?? text
        switch self {
        case .hanzii: return URL(string: "https://hanzii.net/search/word/\(query)?hl=vi")
        case .googleTranslate: return URL(string: "https://translate.google.com/?sl=zh-CN&tl=vi&op=translate&text=\(query)")
        case .mdbg: return URL(string: "https://www.mdbg.net/chinese/dictionary?page=worddict&wdqb=\(query)")
        }
    }

    func open(_ text: String) {
        if let url = url(for: text) { NSWorkspace.shared.open(url) }
    }
}
