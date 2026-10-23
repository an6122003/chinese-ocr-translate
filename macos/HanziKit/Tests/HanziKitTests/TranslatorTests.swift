import Foundation
import Testing
@testable import HanziKit

@Suite("Google translator")
struct GoogleTranslatorTests {
    @Test func joinsTranslatedSegments() throws {
        let json = #"[[["Xin chào. ","你好。",null,null,10],["Tạm biệt","再见",null,null,10]],null,"zh-CN",null]"#
        #expect(try GoogleTranslator.parse(Data(json.utf8)) == "Xin chào. Tạm biệt")
    }

    @Test func rejectsUnexpectedResponses() {
        #expect(throws: (any Error).self) { try GoogleTranslator.parse(Data("<html>rate limited</html>".utf8)) }
        #expect(throws: (any Error).self) { try GoogleTranslator.parse(Data("[[],null]".utf8)) }
    }

    @Test func formEncodingEscapesReservedCharacters() {
        #expect(GoogleTranslator.formEncode("a&b=c+d 学") == "a%26b%3Dc%2Bd%20%E5%AD%A6")
        #expect(GoogleTranslator.formEncode("safe-._~") == "safe-._~")
    }
}
