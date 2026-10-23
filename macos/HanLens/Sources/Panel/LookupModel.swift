import AppKit
import HanziKit
import Observation

/// State behind one result panel: recognized/selected text, its analysis, and the translation.
@Observable
final class LookupModel: Identifiable {
    enum Source: Equatable {
        case screen, selection, typed, clipboard, service

        var label: String {
            switch self {
            case .screen: "From screen"
            case .selection: "Selected text"
            case .typed: "Look up"
            case .clipboard: "Clipboard"
            case .service: "Services"
            }
        }

        var symbol: String {
            switch self {
            case .screen: "viewfinder"
            case .selection: "selection.pin.in.out"
            case .typed: "character.book.closed.zh"
            case .clipboard: "doc.on.clipboard"
            case .service: "contextualmenu.and.cursorarrow"
            }
        }
    }

    enum Status: Equatable {
        case recognizing
        case ready
        case noText(String)
        case failed(String)
    }

    enum TranslationState: Equatable {
        case idle
        case loading
        case done(TranslationOutput)
        case failed(String)
    }

    let id = UUID()
    let source: Source
    private(set) var status: Status
    private(set) var text = ""
    private(set) var analysis: AnalyzedText = .empty
    private(set) var translation: TranslationState = .idle
    var selectedSegmentID: Int?
    var isPinned = false
    var isEditing = false
    var draft = ""

    /// Machine translations of example sentences, keyed by sentence id.
    private(set) var exampleTranslations: [Int64: String] = [:]

    /// The screen area the text came from — lets the panel "follow" it (e.g. video subtitles).
    @ObservationIgnored var screenRegion: (rect: CGRect, screen: NSScreen)?
    private(set) var isFollowing = false
    @ObservationIgnored private var followTask: Task<Void, Never>?
    var canFollow: Bool { screenRegion != nil }

    /// Where the current text came from. Lines picked up while following aren't added to history; this travels
    /// with the text, so a translation that finishes later still knows.
    enum TextOrigin { case user, follow }
    @ObservationIgnored private(set) var textOrigin: TextOrigin = .user
    var isFollowUpdate: Bool { textOrigin == .follow }

    /// The OCR / analysis work that fills the panel; cancelled when the panel closes.
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    /// Set when the panel closes: no more clipboard writes, history, translation or speech after that.
    @ObservationIgnored private(set) var isClosed = false

    @ObservationIgnored private let services: LookupServices
    @ObservationIgnored private var translationTask: Task<Void, Never>?
    @ObservationIgnored private var exampleTask: Task<Void, Never>?
    @ObservationIgnored var onTextChange: ((LookupModel) -> Void)?

    /// Off for screenshots, which shouldn't read aloud even when the user's setting says so.
    var speaksAutomatically = true

    init(source: Source, services: LookupServices, status: Status = .ready) {
        self.source = source
        self.services = services
        self.status = status
    }

    var settings: AppSettings { services.settings }
    var dictionary: HanziDictionary? { services.dictionary }

    var selectedSegment: Segment? {
        guard let selectedSegmentID else { return nil }
        return analysis.segments.first { $0.id == selectedSegmentID }
    }

    /// The word whose details are shown: the selection, or the only word in a single-word lookup.
    var focusedWord: Segment? {
        if let selectedSegment { return selectedSegment }
        let words = analysis.uniqueWords
        return words.count == 1 ? words.first : nil
    }

    // MARK: Input

    /// Runs the work that fills this panel (OCR, analysis) so closing the panel can cancel it.
    func begin(_ work: @escaping @MainActor (LookupModel) async -> Void) {
        inputTask?.cancel()
        inputTask = Task { [weak self] in
            guard let self else { return }
            await work(self)
        }
    }

    /// OCR a crop of the screen. `keepLine` filters lines (used for lasso selections).
    func recognize(_ image: CGImage, keepLine: ((CGRect) -> Bool)? = nil) async {
        status = .recognizing
        do {
            var result = try await TextRecognizer().recognize(image)
            guard !isClosed, !Task.isCancelled else { return }
            if let keepLine {
                let kept = result.lines.filter { keepLine($0.box) }
                if !kept.isEmpty, kept.count < result.lines.count {
                    result = OCRResult(lines: kept, text: TextRecognizer.join(kept, aspectRatio: CGFloat(image.width) / CGFloat(max(image.height, 1))))
                }
            }
            Log.capture.notice("OCR found \(result.lines.count) line(s), confidence \(result.averageConfidence, format: .fixed(precision: 2))")
            let text = result.text
            guard !text.isEmpty else {
                status = .noText("No text found. Try selecting a little more around the characters.")
                return
            }
            if settings.autoCopyRecognizedText {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            await setText(text)
        } catch {
            Log.capture.error("OCR failed: \(error.localizedDescription, privacy: .public)")
            status = .failed("Text recognition failed: \(error.localizedDescription)")
        }
    }

    /// Analyzes and translates new text (replacing any previous text).
    func setText(_ newText: String, origin: TextOrigin = .user) async {
        guard !isClosed else { return }
        let cleaned = newText.cjkNormalized
        guard !cleaned.isEmpty else {
            status = .noText("Nothing to look up.")
            return
        }
        let analyzed: AnalyzedText
        if let analyzer = services.analyzer {
            analyzed = await analyzer.analyzeInBackground(cleaned)
        } else {
            analyzed = AnalyzedText(text: cleaned, segments: [])
        }
        guard !isClosed, !Task.isCancelled else { return }
        text = cleaned
        textOrigin = origin
        analysis = analyzed
        selectedSegmentID = nil
        exampleTranslations = [:]
        status = .ready
        onTextChange?(self)
        translate()
        if speaksAutomatically, settings.autoSpeak, analysis.containsChinese { Speaker.shared.speak(text) }
    }

    func translate(using engine: TranslationEngine? = nil) {
        translationTask?.cancel()
        let text = text
        guard !text.isEmpty, !isClosed else { return }
        // A lone dictionary word is better served by its definitions than by machine translation… but keep both.
        translation = .loading
        let translator = ChineseTranslator(preferred: engine ?? settings.translationEngine)
        let target = settings.targetLanguage
        translationTask = Task {
            do {
                let output = try await translator.translate(text, to: target)
                guard !Task.isCancelled, !isClosed, text == self.text else { return }
                translation = .done(output)
                onTextChange?(self)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                translation = .failed(error.localizedDescription)
            }
        }
    }

    var translatedText: String? {
        if case .done(let output) = translation { return output.text }
        return nil
    }

    // MARK: Editing

    /// Switches to an empty editor (manual look-up, or when OCR found nothing).
    func startTyping() {
        draft = ""
        isEditing = true
        status = .ready
    }

    func beginEditing() {
        draft = text
        isEditing = true
    }

    func commitEditing() {
        isEditing = false
        let newText = draft
        guard newText.cjkNormalized != text else { return }
        Task { await setText(newText) }
    }

    func cancelEditing() {
        isEditing = false
        draft = text
    }

    // MARK: Words

    func toggleSelection(_ segment: Segment) {
        guard segment.isWord else { return }
        selectedSegmentID = selectedSegmentID == segment.id ? nil : segment.id
    }

    func moveSelection(by offset: Int) {
        let words = analysis.segments.filter(\.isWord)
        guard !words.isEmpty else { return }
        let current = words.firstIndex { $0.id == selectedSegmentID } ?? (offset > 0 ? -1 : words.count)
        let next = min(max(current + offset, 0), words.count - 1)
        selectedSegmentID = words[next].id
    }

    func examples(for word: String, limit: Int = 3) -> [ExampleSentence] {
        services.dictionary?.examples(containing: word, limit: limit) ?? []
    }

    /// Fills in Vietnamese for examples that only have English, using the translator (one request).
    func translateExamplesIfNeeded(_ examples: [ExampleSentence]) {
        guard settings.targetLanguage == .vietnamese, !isClosed else { return }
        let missing = examples.filter { $0.vietnamese == nil && exampleTranslations[$0.id] == nil }
        guard !missing.isEmpty else { return }
        exampleTask?.cancel()
        let translator = ChineseTranslator(preferred: settings.translationEngine)
        exampleTask = Task {
            let joined = missing.map(\.chinese).joined(separator: "\n")
            guard let output = try? await translator.translate(joined, to: .vietnamese), !Task.isCancelled else { return }
            let lines = output.text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard lines.count == missing.count else { return }
            for (example, line) in zip(missing, lines) { exampleTranslations[example.id] = line }
        }
    }

    // MARK: Following

    /// Re-reads the same screen area every ~0.7 s and updates when the text changes (two identical reads in a
    /// row are required, so fading subtitles don't flicker through half-drawn text).
    func startFollowing() {
        guard let region = screenRegion, !isFollowing else { return }
        isFollowing = true
        isPinned = true
        let capturer = RegionCapturer(rect: region.rect, screen: region.screen)
        let recognizer = TextRecognizer()
        followTask = Task { [weak self] in
            var shown = self?.text ?? ""
            var candidate = ""
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                guard let self else { return }
                guard self.isFollowing, !self.isEditing else { continue }
                guard let image = try? await capturer.capture(),
                      let result = try? await recognizer.recognize(image) else { continue }
                let text = result.text.cjkNormalized
                guard !text.isEmpty, CJK.containsHan(text) else { continue }
                if text == candidate, text != shown {
                    shown = text
                    await self.setText(text, origin: .follow)
                }
                candidate = text
            }
        }
        Log.capture.info("Following a screen region")
    }

    func stopFollowing() {
        isFollowing = false
        followTask?.cancel()
        followTask = nil
    }

    /// The panel closed: stop everything this lookup was doing.
    func close() {
        isClosed = true
        inputTask?.cancel()
        translationTask?.cancel()
        exampleTask?.cancel()
        stopFollowing()
    }
}

/// Shared services handed to every lookup.
@MainActor
final class LookupServices {
    let settings: AppSettings
    let dictionary: HanziDictionary?
    let analyzer: TextAnalyzer?

    init(settings: AppSettings, dictionary: HanziDictionary?) {
        self.settings = settings
        self.dictionary = dictionary
        self.analyzer = dictionary.map(TextAnalyzer.init(dictionary:))
    }
}
