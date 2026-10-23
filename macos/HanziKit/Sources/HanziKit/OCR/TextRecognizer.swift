import CoreGraphics
import Foundation
import Vision

/// One recognized line of text.
public struct RecognizedLine: Sendable, Hashable {
    public var text: String
    public var confidence: Float
    /// Bounding box normalized to the image (0…1) with the origin at the **top-left**.
    public var box: CGRect
    /// Vision's own hint about whether the line continues on the next one (nil when unknown).
    public var wrapsToNextLine: Bool?

    public init(text: String, confidence: Float, box: CGRect, wrapsToNextLine: Bool? = nil) {
        self.text = text
        self.confidence = confidence
        self.box = box
        self.wrapsToNextLine = wrapsToNextLine
    }
}

/// The result of recognizing an image: individual lines plus their joined, normalized text.
public struct OCRResult: Sendable {
    public var lines: [RecognizedLine]
    public var text: String

    public init(lines: [RecognizedLine], text: String) {
        self.lines = lines
        self.text = text
    }
    public var averageConfidence: Float {
        lines.isEmpty ? 0 : lines.map(\.confidence).reduce(0, +) / Float(lines.count)
    }
    public static let empty = OCRResult(lines: [], text: "")
}

/// Chinese-first OCR on top of Apple's Vision framework (works on macOS and iPadOS).
public struct TextRecognizer: Sendable {
    public enum Quality: Sendable { case accurate, fast }

    /// Recognition languages in priority order. Vision's Chinese models also read Latin text.
    public var languages: [String]

    public init(languages: [String] = ["zh-Hans", "zh-Hant", "en-US"]) {
        self.languages = languages
    }

    /// Recognizes the lines in `image`. `minimumTextHeight` is a fraction of the image height
    /// (lower finds smaller text, e.g. 0.004 for a whole-screen capture).
    public func lines(in image: CGImage, quality: Quality = .accurate, minimumTextHeight: Float? = nil) async throws -> [RecognizedLine] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = quality == .accurate ? .accurate : .fast
        request.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = false
        if let minimumTextHeight { request.minimumTextHeightFraction = minimumTextHeight }

        let observations = try await request.perform(on: image)
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            let box = observation.boundingBox
            let topLeftBox = CGRect(x: box.origin.x, y: 1 - box.origin.y - box.height, width: box.width, height: box.height)
            return RecognizedLine(text: text, confidence: candidate.confidence, box: topLeftBox,
                                  wrapsToNextLine: observation.shouldWrapToNextLine)
        }
    }

    /// Recognizes a user-selected crop. Small or low-confidence crops are retried upscaled with padding,
    /// and the better reading wins — tiny UI text and single short lines come out far more reliably.
    /// Line boxes in the result are normalized to `image` (top-left origin).
    public func recognize(_ image: CGImage) async throws -> OCRResult {
        let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        let first = try await lines(in: ImagePreprocessing.padded(image, scale: 1))

        let isSmall = image.height < 90 || image.width < 90
        let isWeak = first.isEmpty || (first.map(\.confidence).reduce(0, +) / Float(max(first.count, 1))) < 0.6
        var best = first
        if isSmall || isWeak {
            let scale = min(4, max(2, 160 / CGFloat(max(1, min(image.width, image.height)))))
            let second = try await lines(in: ImagePreprocessing.padded(image, scale: scale))
            if Self.score(second) > Self.score(first) { best = second }
        }
        return OCRResult(lines: best, text: Self.join(best, aspectRatio: aspect))
    }

    /// Recognizes a padded image and maps the boxes back onto the original, unpadded image.
    private func lines(in padded: ImagePreprocessing.Padded) async throws -> [RecognizedLine] {
        try await lines(in: padded.image).map { line in
            var line = line
            line.box = padded.originalBox(for: line.box)
            return line
        }
    }

    /// Prefers readings with more confidently recognized characters.
    static func score(_ lines: [RecognizedLine]) -> Float {
        lines.reduce(0) { $0 + $1.confidence * Float($1.text.count) }
    }

    // MARK: - Joining lines

    /// Joins lines into readable text: Chinese soft-wraps are joined without spaces, Latin wraps with one,
    /// and real breaks (sentence ends, paragraph gaps, indents, separate items on one row) keep a newline.
    /// `aspectRatio` is the image's width ÷ height, so horizontal and vertical distances can be compared.
    public static func join(_ lines: [RecognizedLine], aspectRatio: CGFloat = 1) -> String {
        // Work in units of image height on both axes.
        let scaled = lines.map { line -> RecognizedLine in
            var line = line
            line.box = CGRect(x: line.box.minX * aspectRatio, y: line.box.minY,
                              width: line.box.width * aspectRatio, height: line.box.height)
            return line
        }
        guard var previous = scaled.first else { return "" }
        let heights = scaled.map(\.box.height).sorted()
        let lineHeight = max(heights[heights.count / 2], 0.0001)

        var output = previous.text
        for line in scaled.dropFirst() {
            output += separator(between: previous, and: line, lineHeight: lineHeight)
            output += line.text
            previous = line
        }
        return CJK.normalize(output)
    }

    static func separator(between a: RecognizedLine, and b: RecognizedLine, lineHeight: CGFloat) -> String {
        let latinJoin: String = {
            guard let last = a.text.last, let first = b.text.first else { return "" }
            let latinLike: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber || ",.;:!?)".contains($0)) }
            return latinLike(last) && latinLike(first) ? " " : ""
        }()

        // Same visual row (Vision split it, e.g. a label and its value): keep them apart.
        let verticalOverlap = min(a.box.maxY, b.box.maxY) - max(a.box.minY, b.box.minY)
        if verticalOverlap > 0.5 * min(a.box.height, b.box.height) {
            return b.box.minX - a.box.maxX > 1.5 * lineHeight ? "\n" : latinJoin
        }
        if let wraps = a.wrapsToNextLine { return wraps ? latinJoin : "\n" }

        let gap = b.box.minY - a.box.maxY
        if gap > 0.9 * lineHeight { return "\n" }                      // paragraph gap
        if CJK.endsSentence(a.text) { return "\n" }                    // sentence ended on this line
        if b.box.minX - a.box.minX > 1.2 * lineHeight { return "\n" }  // next line is indented
        if a.box.maxX < b.box.maxX - 3 * lineHeight { return "\n" }    // short line: ended early, not wrapped
        return latinJoin
    }
}

/// Image helpers for OCR.
public enum ImagePreprocessing {
    /// An image that was scaled and given a margin, with the geometry needed to map results back.
    public struct Padded {
        public let image: CGImage
        let margin: CGFloat
        let scale: CGFloat
        let originalSize: CGSize

        /// Converts a box normalized to the padded image into one normalized to the original image.
        func originalBox(for box: CGRect) -> CGRect {
            let paddedWidth = CGFloat(image.width), paddedHeight = CGFloat(image.height)
            let x = (box.minX * paddedWidth - margin) / scale / originalSize.width
            let y = (box.minY * paddedHeight - margin) / scale / originalSize.height
            let width = box.width * paddedWidth / scale / originalSize.width
            let height = box.height * paddedHeight / scale / originalSize.height
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }

    /// Returns the image scaled by `scale`, with a margin filled with the image's border colour —
    /// Vision often misses glyphs that touch the image edge.
    public static func padded(_ image: CGImage, scale: CGFloat, marginFraction: CGFloat = 0.12) -> Padded {
        let originalSize = CGSize(width: image.width, height: image.height)
        let width = (CGFloat(image.width) * scale).rounded()
        let height = (CGFloat(image.height) * scale).rounded()
        let margin = max(8, min(width, height) * marginFraction).rounded()
        let size = CGSize(width: width + 2 * margin, height: height + 2 * margin)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Padded(image: image, margin: 0, scale: 1, originalSize: originalSize) }
        context.setFillColor(borderColor(of: image))
        context.fill(CGRect(origin: .zero, size: size))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: margin, y: margin, width: width, height: height))
        guard let result = context.makeImage() else {
            return Padded(image: image, margin: 0, scale: 1, originalSize: originalSize)
        }
        return Padded(image: result, margin: margin, scale: width / originalSize.width, originalSize: originalSize)
    }

    /// Average colour of the image's outermost pixels.
    static func borderColor(of image: CGImage) -> CGColor {
        let sampleSize = 16
        guard let context = CGContext(data: nil, width: sampleSize, height: sampleSize, bitsPerComponent: 8,
                                      bytesPerRow: sampleSize * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data
        else { return CGColor(gray: 1, alpha: 1) }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
        let pixels = data.bindMemory(to: UInt8.self, capacity: sampleSize * sampleSize * 4)
        var sum = (r: 0, g: 0, b: 0, n: 0)
        for y in 0..<sampleSize {
            for x in 0..<sampleSize where x == 0 || y == 0 || x == sampleSize - 1 || y == sampleSize - 1 {
                let i = (y * sampleSize + x) * 4
                sum.r += Int(pixels[i]); sum.g += Int(pixels[i + 1]); sum.b += Int(pixels[i + 2]); sum.n += 1
            }
        }
        let n = CGFloat(max(sum.n, 1)) * 255
        return CGColor(srgbRed: CGFloat(sum.r) / n, green: CGFloat(sum.g) / n, blue: CGFloat(sum.b) / n, alpha: 1)
    }
}
