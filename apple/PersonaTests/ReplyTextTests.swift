import Testing
import UIKit
@testable import Persona

/// A lifted message's words selected in place (#603, `ReplyText`): a reply reads as the chat shows it, without the
/// Markdown marks, and is laid out with the chat's spacing, so a part copied from it is clean; your own message,
/// formulas and code stay exactly as written.
@MainActor
struct ReplyTextTests {
    private let look = ReplyText.Look(.reply(quiet: false), traits: UITraitCollection(preferredContentSizeCategory: .large))

    private func reply(_ markdown: String) -> NSAttributedString { ReplyText.attributed(markdown, look: look, width: 360) }
    private func shown(_ markdown: String) -> String { reply(markdown).string }

    private func style(_ s: NSAttributedString, at word: String) -> NSParagraphStyle? {
        s.attribute(.paragraphStyle, at: (s.string as NSString).range(of: word).location, effectiveRange: nil) as? NSParagraphStyle
    }

    @Test func inlineMarksGoTheirLookStays() {
        let s = reply("今天有 **3 件事**，跑 `swift test`，看 [PR](https://example.com/pr/42)。")
        #expect(s.string == "今天有 3 件事，跑 swift test，看 PR。")
        // Semibold, as the chat's strong text.
        let bold = s.attribute(.font, at: 4, effectiveRange: nil) as? UIFont
        let traits = bold?.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        #expect((traits?[.weight] as? CGFloat ?? 0) >= UIFont.Weight.semibold.rawValue)
        let code = (s.string as NSString).range(of: "swift test")
        #expect(s.attribute(.backgroundColor, at: code.location, effectiveRange: nil) != nil)
        // A link keeps its color and is not followed: a tap on the words is about the selection.
        let link = (s.string as NSString).range(of: "PR")
        #expect(s.attribute(.link, at: link.location, effectiveRange: nil) == nil)
        #expect(s.attribute(.foregroundColor, at: link.location, effectiveRange: nil) as? UIColor == look.link)
    }

    /// Outside a fence `a*b*c` would be emphasis (`abc`); inside it is code, kept as written, monospaced, on the code
    /// background (`ReplyBlock`).
    @Test func fencedCodeLosesItsFenceKeepsItsLines() {
        #expect(shown("a*b*c") == "abc")
        let s = reply("新的写法：\n\n```swift\nlet x = a*b*c\n  __init__()\n```\n\n完了")
        #expect(s.string == "新的写法：\n\nlet x = a*b*c\n  __init__()\n\n完了")
        let at = (s.string as NSString).range(of: "a*b*c").location
        let font = s.attribute(.font, at: at, effectiveRange: nil) as? UIFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true)
        let block = s.attribute(.replyBlock, at: at, effectiveRange: nil) as? ReplyBlock
        #expect(block?.kind == .code)
        // Both lines are one block: one background behind them.
        let next = (s.string as NSString).range(of: "__init__").location
        #expect(s.attribute(.replyBlock, at: next, effectiveRange: nil) as? ReplyBlock === block)
    }

    /// A shorter or other fence inside a fence is a line of it: ````md holding ```swift … ``` closes on ```` only.
    @Test func aFenceClosesOnlyOnItsOwnKind() {
        #expect(shown("看：\n````md\n```swift\nlet a = 1\n```\n还在里面\n````\n外面") == "看：\n```swift\nlet a = 1\n```\n还在里面\n外面")
        #expect(shown("~~~\n```\n~~~~\n后面") == "```\n后面")
        // An info string after a closing-looking fence: still inside.
        #expect(shown("```\na\n```js\nb\n```") == "a\n```js\nb")
    }

    @Test func formulasStayAsWritten() {
        #expect(shown("面积 $x*y*z$，还有 \\(a*b*c\\) 和 *重点*") == "面积 $x*y*z$，还有 \\(a*b*c\\) 和 重点")
        #expect(shown("$$\nE = m*c*c\n$$\n**完**") == "$$\nE = m*c*c\n$$\n完")
        #expect(shown("一行的 $$a*b*c$$ 公式") == "一行的 $$a*b*c$$ 公式")
        #expect(shown("跑 `echo $HOME*` 看看") == "跑 echo $HOME* 看看") // `$` in a code span is code
    }

    @Test func indentedCodeIsCode() {
        let s = reply("例子：\n\n    let x = a*b*c\n    __init__()\n\n完")
        #expect(s.string == "例子：\n\nlet x = a*b*c\n__init__()\n\n完")
        #expect((s.attribute(.replyBlock, at: (s.string as NSString).range(of: "let x").location, effectiveRange: nil) as? ReplyBlock)?.kind == .code)
        // In a list, four spaces in is the item's next level, not code.
        #expect(shown("- 一\n\n    - 二") == "•\t一\n\n◦\t二")
    }

    @Test func headingsListsQuotesAndRules() {
        #expect(shown("## 结论\n- 一\n  * 二\n1. **四**") == "结论\n•\t一\n◦\t二\n1.\t四")
        // A rule keeps its marks, drawn as a line (`ReplyBlock`), not as text.
        let rule = reply("上面\n\n---\n\n下面")
        #expect(rule.string == "上面\n\n---\n\n下面")
        let at = (rule.string as NSString).range(of: "---").location
        #expect((rule.attribute(.replyBlock, at: at, effectiveRange: nil) as? ReplyBlock)?.kind == .rule)
        #expect(rule.attribute(.foregroundColor, at: at, effectiveRange: nil) as? UIColor == .clear)
        let quote = reply("> 旧缓存要等一天\n> 才过期")
        #expect(quote.string == "旧缓存要等一天\n才过期")
        #expect((quote.attribute(.replyBlock, at: 0, effectiveRange: nil) as? ReplyBlock)?.kind == .quote)
        // The first heading level is larger.
        let h1 = reply("# 大\n## 小")
        let big = (h1.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize ?? 0
        #expect(big > look.size * 1.2)
    }

    /// Spacing as in the chat: the lines of a paragraph are only line-spaced; between blocks the larger margin; a list's
    /// items 0.2 em apart.
    @Test func spacingFollowsTheChat() {
        let s = reply("一行\n两行\n\n下一段\n- 甲\n- 乙")
        let lines = look.size * ReplyMetrics.lineSpacing
        #expect(style(s, at: "一行")?.paragraphSpacing == 0)
        #expect(style(s, at: "两行")?.paragraphSpacing == ReplyMetrics.paragraphBottom - lines)
        #expect(style(s, at: "甲")?.paragraphSpacing == look.size * ReplyMetrics.itemTop)
        #expect(style(s, at: "两行")?.lineSpacing == lines)
        // The blank line takes no room but stays a line break, so copied paragraphs stay apart.
        let blank = (s.string as NSString).range(of: "两行").location + 3
        #expect((s.attribute(.paragraphStyle, at: blank, effectiveRange: nil) as? NSParagraphStyle)?.maximumLineHeight ?? 1 < 0.1)
    }

    /// A table is drawn as the chat draws it, and copies as its Markdown.
    @Test func aTableCopiesAsItsMarkdown() {
        let table = "| 页面 | 风险 |\n| --- | --- |\n| 首页 | 低 |"
        let s = reply("看表：\n\n" + table + "\n\n完")
        let at = (s.string as NSString).range(of: "\u{FFFC}").location
        #expect(at != NSNotFound)
        #expect(s.attribute(.attachment, at: at, effectiveRange: nil) is NSTextAttachment)
        #expect(ReplyText.copyText(s) == "看表：\n\n" + table + "\n\n完")
    }

    @Test func plainTextIsUnchanged() {
        let text = "PR #42 看完了：逻辑没问题。\n#不是标题\n2 * 3 = 6"
        #expect(shown(text) == text)
    }

    /// Your own message is shown as its bubble shows it: no Markdown at all.
    @Test func yourOwnMessageIsPlain() {
        let text = "Python 里 __init__.py 的 2*3*4 是不是写错了？\n# 不是标题\n- 也不是列表\n```\n照原样\n```"
        let mine = ReplyText.Look(.plain(.primary), traits: UITraitCollection(preferredContentSizeCategory: .large))
        #expect(ReplyText.plain(text, look: mine).string == text)
        #expect(shown(text) != text) // as a reply it would lose marks
    }

    /// The fonts follow the text size.
    @Test func fontsFollowTheTextSize() {
        func size(_ s: NSAttributedString, _ at: Int) -> CGFloat { (s.attribute(.font, at: at, effectiveRange: nil) as? UIFont)?.pointSize ?? 0 }
        let small = ReplyText.Look(.reply(quiet: false), traits: UITraitCollection(preferredContentSizeCategory: .small))
        let large = ReplyText.Look(.reply(quiet: false), traits: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraLarge))
        let md = "正文\n```\ncode\n```"
        let a = ReplyText.attributed(md, look: small, width: 360), b = ReplyText.attributed(md, look: large, width: 360)
        #expect(size(b, 0) > size(a, 0))
        #expect(size(b, b.length - 1) > size(a, a.length - 1))
        // An agent's words between its steps are smaller.
        let quiet = ReplyText.Look(.reply(quiet: true), traits: UITraitCollection(preferredContentSizeCategory: .large))
        #expect(quiet.size < look.size)
    }
}
