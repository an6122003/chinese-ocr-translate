import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import HanziKit

/// Renders lines of text into an image, like text on screen.
func renderText(_ lines: [String], fontSize: CGFloat = 28, scale: CGFloat = 2, width: CGFloat = 900,
                dark: Bool = false) -> CGImage {
    let lineHeight = fontSize * 1.6
    let size = CGSize(width: width * scale, height: (CGFloat(lines.count) * lineHeight + fontSize) * scale)
    let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(dark ? CGColor(gray: 0.12, alpha: 1) : CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    context.scaleBy(x: scale, y: scale)
    let font = CTFontCreateWithName("PingFang SC" as CFString, fontSize, nil)
    let color = dark ? CGColor(gray: 0.92, alpha: 1) : CGColor(gray: 0.1, alpha: 1)
    for (index, text) in lines.enumerated() {
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: fontSize * 0.6, y: size.height / scale - CGFloat(index + 1) * lineHeight)
        CTLineDraw(line, context)
    }
    return context.makeImage()!
}

@Suite("OCR")
struct OCRTests {
    @Test func readsSimplifiedChinese() async throws {
        let image = renderText(["我们今天去图书馆学习中文。"])
        let result = try await TextRecognizer().recognize(image)
        #expect(result.text == "我们今天去图书馆学习中文。")
    }

    @Test func readsTraditionalChineseOnDarkBackground() async throws {
        let image = renderText(["我們今天去圖書館學習中文"], dark: true)
        let result = try await TextRecognizer().recognize(image)
        #expect(result.text == "我們今天去圖書館學習中文")
    }

    @Test func readsTinyNonRetinaText() async throws {
        // 12 px text at 1× — like a small UI label on an external monitor.
        let image = renderText(["你好世界"], fontSize: 12, scale: 1, width: 80)
        let result = try await TextRecognizer().recognize(image)
        #expect(result.text == "你好世界")
    }

    @Test func joinsWrappedChineseLinesWithoutSpaces() async throws {
        let image = renderText(["人工智能正在改变我们的生活", "方式，也在改变工作。", "第二段从这里开始。"])
        let result = try await TextRecognizer().recognize(image)
        #expect(result.text.hasPrefix("人工智能正在改变我们的生活方式，也在改变工作。"))
        #expect(result.text.contains("\n第二段"))
        #expect(!result.text.contains(" "))
    }

    @Test func joinHeuristics() {
        let a = RecognizedLine(text: "Hello", confidence: 1, box: CGRect(x: 0, y: 0, width: 0.8, height: 0.1))
        let b = RecognizedLine(text: "world", confidence: 1, box: CGRect(x: 0, y: 0.12, width: 0.5, height: 0.1))
        #expect(TextRecognizer.join([a, b]) == "Hello world")
        let c = RecognizedLine(text: "你好。", confidence: 1, box: CGRect(x: 0, y: 0, width: 0.8, height: 0.1))
        let d = RecognizedLine(text: "再见", confidence: 1, box: CGRect(x: 0, y: 0.12, width: 0.5, height: 0.1))
        #expect(TextRecognizer.join([c, d]) == "你好。\n再见")
    }
}
