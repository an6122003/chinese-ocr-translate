import Testing
@testable import HanziKit

@Suite("CJK text")
struct CJKTests {
    @Test func removesOCRSpacingBetweenChineseCharacters() {
        #expect(CJK.normalize("我 们 今天  去 图书馆 。") == "我们今天去图书馆。")
        #expect(CJK.normalize("学习 English 很 有意思") == "学习English很有意思")
        #expect(CJK.normalize("hello  world") == "hello world")
        #expect(CJK.normalize("\u{00A0} 你好\u{00A0}世界 ") == "你好世界")
        #expect(CJK.normalize("第一行 \n 第二行") == "第一行\n第二行")
    }

    @Test func classifiesCharacters() {
        #expect(CJK.isHan("学"))
        #expect(CJK.isHan("學"))
        #expect(CJK.isHan("𠀀"))  // extension B
        #expect(!CJK.isHan("a"))
        #expect(!CJK.isHan("。"))
        #expect(CJK.isCJKPunctuation("。"))
        #expect(CJK.isCJKPunctuation("，"))
        #expect(CJK.containsHan("abc中"))
        #expect(!CJK.containsHan("abc"))
        #expect(CJK.endsSentence("你好吗？"))
        #expect(!CJK.endsSentence("你好"))
    }

    @Test func detectsScript() {
        #expect(CJK.looksTraditional("我們這個學校") == true)
        #expect(CJK.looksTraditional("我们这个学校") == false)
        #expect(CJK.looksTraditional("你好") == nil)
    }
}
