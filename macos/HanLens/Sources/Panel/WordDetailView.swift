import HanziKit
import SwiftUI

/// Everything about one word: readings, meanings, characters, examples.
struct WordDetailView: View {
    @Bindable var model: LookupModel
    let segment: Segment

    var body: some View {
        let settings = model.settings
        VStack(alignment: .leading, spacing: 12) {
            WordTitle(model: model, segment: segment)

            if let entry = segment.bestEntry {
                SensesView(entry: entry, language: settings.targetLanguage, showEnglish: settings.showEnglish)
            } else {
                Text("Not in the dictionary — see the translation above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            let others = Array(segment.entries.dropFirst().prefix(4))
            if !others.isEmpty {
                OtherReadingsView(entries: others, language: settings.targetLanguage, toneColors: settings.toneColors)
            }

            if segment.text.count > 1 {
                CharacterBreakdownView(model: model, segment: segment)
            }

            ExamplesView(model: model, word: segment.text, reading: segment.pinyin)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .id(segment.id)
        .transition(.opacity)
    }
}

private struct WordTitle: View {
    let model: LookupModel
    let segment: Segment

    var body: some View {
        let settings = model.settings
        let entry = segment.bestEntry
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(segment.text)
                        .font(HanFont.font(size: 32, weight: .medium))
                        .textSelection(.enabled)
                    if let entry, entry.traditional != entry.simplified {
                        Text(segment.text == entry.simplified ? entry.traditional : entry.simplified)
                            .font(HanFont.font(size: 20, traditional: segment.text == entry.simplified))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                ToneStyle.pinyin(segment.syllables, colored: settings.toneColors)
                    .font(.system(size: 18, weight: .semibold))
                if settings.showHanViet, !segment.hanVietText.isEmpty {
                    Text(segment.hanVietText.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                        .help("Âm Hán Việt")
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 4) {
                    if let level = entry?.hskLevel { HSKBadge(level: level) }
                    Button {
                        Speaker.shared.speak(segment.text)
                    } label: {
                        Image(systemName: "speaker.wave.2.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Pronounce")
                }
                if model.dictionary?.hasGrammarPage(segment.text) == true {
                    Link(destination: URL(string: "https://resources.allsetlearning.com/chinese/grammar/\(segment.text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? segment.text)")!) {
                        Label("Grammar", systemImage: "book")
                            .font(.caption)
                    }
                    .help("Open the Chinese Grammar Wiki page for \(segment.text)")
                }
            }
        }
    }
}

private struct SensesView: View {
    let entry: DictionaryEntry
    let language: TargetLanguage
    let showEnglish: Bool

    var body: some View {
        let primary = entry.senses(preferring: language).map(DefinitionFormatter.clean).filter { !$0.isEmpty }
        let english = entry.english.map(DefinitionFormatter.clean).filter { !$0.isEmpty }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(primary.prefix(8).enumerated()), id: \.offset) { index, sense in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .trailing)
                    Text(sense)
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if showEnglish, language == .vietnamese, !entry.vietnamese.isEmpty, !english.isEmpty {
                Text(english.prefix(4).joined(separator: "; "))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24)
                    .padding(.top, 2)
            }
        }
    }
}

private struct OtherReadingsView: View {
    let entries: [DictionaryEntry]
    let language: TargetLanguage
    let toneColors: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Other readings")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(entries) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ToneStyle.pinyin(numbered: entry.pinyin, colored: toneColors)
                        .font(.system(size: 13, weight: .semibold))
                    Text(entry.shortGloss(preferring: language, maxSenses: 3))
                        .font(.system(size: 13))
                        .foregroundStyle(.primary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct CharacterBreakdownView: View {
    let model: LookupModel
    let segment: Segment

    var body: some View {
        let settings = model.settings
        let characters = Array(segment.text)
        VStack(alignment: .leading, spacing: 4) {
            Text("Characters")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(characters.enumerated()), id: \.offset) { index, character in
                let syllable = index < segment.syllables.count ? segment.syllables[index] : nil
                let entry = bestEntry(for: character, syllable: syllable)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(character))
                        .font(HanFont.font(size: 20))
                    if let syllable {
                        ToneStyle.pinyin([syllable], colored: settings.toneColors)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(minWidth: 38, alignment: .leading)
                    }
                    if settings.showHanViet, index < segment.hanViet.count, !segment.hanViet[index].isEmpty {
                        Text(segment.hanViet[index])
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 44, alignment: .leading)
                    }
                    Text(entry?.shortGloss(preferring: settings.targetLanguage, maxSenses: 3) ?? "")
                        .font(.system(size: 13))
                        .foregroundStyle(.primary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func bestEntry(for character: Character, syllable: Pinyin.Syllable?) -> DictionaryEntry? {
        let entries = model.dictionary?.entries(for: String(character)) ?? []
        guard let syllable else { return entries.first }
        let key = Pinyin.comparisonKey(syllable.text)
        return entries.first { !$0.isProperNoun && Pinyin.comparisonKey($0.pinyin) == key && Pinyin.parseNumbered($0.pinyin).first?.tone == syllable.tone }
            ?? entries.first { !$0.isProperNoun && Pinyin.comparisonKey($0.pinyin) == key }
            ?? entries.first
    }
}

private struct ExamplesView: View {
    @Bindable var model: LookupModel
    let word: String
    /// The reading being shown — examples must use the word with this reading (长 zhǎng ≠ 长 cháng).
    let reading: String
    @State private var examples: [ExampleRow] = []

    struct ExampleRow: Identifiable {
        let sentence: ExampleSentence
        let pinyin: String
        var id: Int64 { sentence.id }
    }

    var body: some View {
        // A VStack (not a Group) so there is always a view for `.task` to attach to, even before loading.
        VStack(alignment: .leading, spacing: 8) {
            if !examples.isEmpty {
                Text("Examples")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(examples) { row in
                    ExampleRowView(model: model, row: row, word: word)
                }
            }
        }
        .task(id: word + "|" + reading) { await load() }
    }

    /// Keeps sentences where the word appears as a word of its own, with the same reading — a plain substring
    /// match would offer 擅长 or 河长300公里 (cháng) as examples of 长 zhǎng.
    private func load() async {
        guard let dictionary = model.dictionary else { return }
        let analyzer = TextAnalyzer(dictionary: dictionary)
        let entry = dictionary.entries(for: word).first
        let forms = Set([word, entry?.simplified, entry?.traditional].compactMap { $0 })
        let key = Pinyin.comparisonKey(reading)
        var rows: [ExampleRow] = []
        // Single characters match many unrelated words (长 in 擅长, 校长…), so look through more candidates.
        let candidates = model.examples(for: word, limit: word.count == 1 ? 120 : 24)
        for sentence in candidates where rows.count < 3 {
            let analysis = await analyzer.analyzeInBackground(sentence.chinese)
            guard analysis.segments.contains(where: { forms.contains($0.text) && Pinyin.comparisonKey($0.pinyin) == key }) else { continue }
            rows.append(ExampleRow(sentence: sentence, pinyin: analysis.pinyinText))
        }
        examples = rows
        model.translateExamplesIfNeeded(rows.map(\.sentence))
    }
}

private struct ExampleRowView: View {
    let model: LookupModel
    let row: ExamplesView.ExampleRow
    let word: String

    var body: some View {
        let sentence = row.sentence
        let target = model.settings.targetLanguage
        let translation: (text: String, machine: Bool)? = {
            if target == .vietnamese {
                if let vi = sentence.vietnamese { return (vi, false) }
                if let machine = model.exampleTranslations[sentence.id] { return (machine, true) }
            }
            return sentence.english.map { ($0, false) }
        }()

        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                highlighted(sentence.chinese)
                    .font(HanFont.font(size: 16))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !row.pinyin.isEmpty, model.settings.showPinyin {
                    Text(row.pinyin)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let translation {
                    Text(translation.text + (translation.machine ? "  ⚙︎" : ""))
                        .font(.system(size: 13))
                        .foregroundStyle(.primary.opacity(0.8))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(translation.machine ? "Machine translation" : "")
                }
                // Tatoeba's licence (CC BY 2.0 FR) asks for each sentence's author to be credited.
                Text(sentence.attribution)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .pointerStyle(.link)
                    .onTapGesture { if let url = sentence.url { NSWorkspace.shared.open(url) } }
                    .help("Open this sentence on Tatoeba")
            }
            Spacer(minLength: 0)
            Button {
                Speaker.shared.speak(sentence.chinese)
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            .buttonStyle(.borderless)
            .help("Read this example")
        }
    }

    /// The sentence with the looked-up word emphasised (in whichever script the sentence uses).
    private func highlighted(_ sentence: String) -> Text {
        var attributed = AttributedString(sentence)
        let entry = model.dictionary?.entries(for: word).first
        let forms = [word, entry?.simplified, entry?.traditional].compactMap { $0 }
        if let range = forms.lazy.compactMap({ attributed.range(of: $0) }).first {
            attributed[range].foregroundColor = .accentColor
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
        }
        return Text(attributed)
    }
}
