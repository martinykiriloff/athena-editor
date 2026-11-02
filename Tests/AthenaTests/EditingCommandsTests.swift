// EditingCommandsTests.swift
// Athena — tag auto-close/rename, Emmet, column selection, add cursor, line transforms.
// Swift 6, strict concurrency.

import Testing
import Foundation
@testable import Athena

private func apply(_ e: LineOperations.Edit?, to text: String) -> String? {
    guard let e else { return nil }
    return (text as NSString).replacingCharacters(in: e.range, with: e.replacement)
}

// MARK: - Tags

@Suite struct MarkupTagTests {
    @Test func autoCloseSimple() {
        #expect(MarkupTags.closingTag(afterTyping: 4, in: "<div", flavor: .html) == "</div>")
        #expect(MarkupTags.closingTag(afterTyping: 13, in: "<a href=\"x>y\"", flavor: .html) == "</a>")
    }

    @Test func autoCloseSkipsVoidSelfClosedAndExisting() {
        #expect(MarkupTags.closingTag(afterTyping: 3, in: "<br", flavor: .html) == nil)
        #expect(MarkupTags.closingTag(afterTyping: 5, in: "<x a/", flavor: .html) == nil)
        #expect(MarkupTags.closingTag(afterTyping: 4, in: "<div</div>", flavor: .html) == nil)
        #expect(MarkupTags.closingTag(afterTyping: 3, in: "<p</p>", flavor: .html) == nil)
        #expect(MarkupTags.closingTag(afterTyping: 6, in: "<input", flavor: .html) == nil)
    }

    @Test func autoCloseIsmlAndJSX() {
        #expect(MarkupTags.closingTag(afterTyping: 19, in: "<isif condition=\"a\"", flavor: .isml) == "</isif>")
        #expect(MarkupTags.closingTag(afterTyping: 6, in: "<iselse", flavor: .isml) == nil)
        #expect(MarkupTags.closingTag(afterTyping: 1, in: "<", flavor: .jsx) == "</>")
        // TypeScript generic is not a tag.
        #expect(MarkupTags.closingTag(afterTyping: 12, in: "useState<str", flavor: .jsx) == nil)
        #expect(MarkupTags.closingTag(afterTyping: 15, in: "(<Foo bar={a>b}", flavor: .jsx) == "</Foo>")
    }

    @Test func autoCloseNotInsideClosedTagOrText() {
        #expect(MarkupTags.closingTag(afterTyping: 8, in: "<a>text a", flavor: .html) == nil)
        #expect(MarkupTags.closingTag(afterTyping: 3, in: "a b", flavor: .html) == nil)
    }

    @Test func scanPairsAndSkipsCommentsAndScript() {
        let text = "<div><!-- <b> --><script>if (a<b) {}</script><br><p>x</p></div>"
        let tags = MarkupTags.scan(text, flavor: .html)
        #expect(tags.map(\.name) == ["div", "script", "script", "br", "p", "p", "div"])
        let pairs = MarkupTags.pairs(of: tags, flavor: .html)
        #expect(pairs[0] == 6)
        #expect(pairs[4] == 5)
        #expect(pairs[3] == nil)
    }

    @Test func linkedRenameFromOpeningTag() {
        let before = "<div>é😀</div>"
        let edit = NSRange(location: 4, length: 0)       // typing after "div"
        let pair = MarkupTags.namePair(in: before, flavor: .html, touching: edit)
        #expect(pair?.name == NSRange(location: 1, length: 3))
        let after = "<divs>é😀</div>"
        let rename = MarkupTags.partnerRename(newText: after, pair: pair!, editRange: edit,
                                              replacementLength: 1, flavor: .html)
        // Partner shifted by +1 because it follows the edited name.
        #expect(rename == MarkupTags.Rename(range: NSRange(location: 11, length: 3), replacement: "divs"))
    }

    @Test func linkedRenameFromClosingTag() {
        let before = "<span>x</span>"
        let edit = NSRange(location: 9, length: 4)       // replace "span" in "</span>"
        let pair = MarkupTags.namePair(in: before, flavor: .html, touching: edit)
        #expect(pair?.partner == NSRange(location: 1, length: 4))
        let after = "<span>x</b>"
        let r = MarkupTags.partnerRename(newText: after, pair: pair!, editRange: edit,
                                         replacementLength: 1, flavor: .html)
        #expect(r == MarkupTags.Rename(range: NSRange(location: 1, length: 4), replacement: "b"))
    }

    @Test func linkedRenameRejectsInvalidNamesAndNonTags() {
        let before = "<div></div>"
        #expect(MarkupTags.namePair(in: before, flavor: .html, touching: NSRange(location: 6, length: 0)) == nil)
        let edit = NSRange(location: 4, length: 0)
        let pair = MarkupTags.namePair(in: before, flavor: .html, touching: edit)!
        #expect(MarkupTags.partnerRename(newText: "<div >", pair: pair, editRange: edit,
                                         replacementLength: 1, flavor: .html) == nil)
        #expect(MarkupTags.flavorCheck())
    }
}

private extension MarkupTags {
    static func flavorCheck() -> Bool {
        MarkupFlavor.flavor(forPathExtension: "VUE") == .vue
            && MarkupFlavor.flavor(forPathExtension: "tsx") == .jsx
            && MarkupFlavor.flavor(forPathExtension: "swift") == nil
    }
}

// MARK: - Emmet

@Suite struct EmmetTests {
    private func html(_ s: String, _ flavor: MarkupFlavor = .html) -> String? {
        Emmet.expandMarkup(s, flavor: flavor, indentUnit: "  ", baseIndent: "")?.text
    }

    @Test func basics() {
        #expect(html("div") == "<div></div>")
        #expect(html(".a.b") == "<div class=\"a b\"></div>")
        #expect(html("p#x.y{hi}") == "<p id=\"x\" class=\"y\">hi</p>")
        #expect(html("a") == "<a href=\"\"></a>")
        #expect(html("img") == "<img src=\"\" alt=\"\">")
        #expect(html("img", .jsx) == "<img src=\"\" alt=\"\" />")
        #expect(html("input[type=email disabled]") == "<input type=\"email\" disabled=\"\">")
    }

    @Test func nestingSiblingsClimb() {
        #expect(html("ul>li*2") == "<ul>\n  <li></li>\n  <li></li>\n</ul>")
        #expect(html("div>p+span") == "<div>\n  <p></p>\n  <span></span>\n</div>")
        #expect(html("div>section>p^footer") == "<div>\n  <section>\n    <p></p>\n  </section>\n  <footer></footer>\n</div>")
        #expect(html("(dt+dd)*2") == "<dt></dt>\n<dd></dd>\n<dt></dt>\n<dd></dd>")
    }

    @Test func implicitNamesAndNumbering() {
        #expect(html("ul>.item$*2") == "<ul>\n  <li class=\"item1\"></li>\n  <li class=\"item2\"></li>\n</ul>")
        #expect(html("table>.r>.c") == "<table>\n  <tr class=\"r\">\n    <td class=\"c\"></td>\n  </tr>\n</table>")
        #expect(html("p>.x") == "<p>\n  <span class=\"x\"></span>\n</p>")
        #expect(html("li{n$$}*3") == "<li>n01</li>\n<li>n02</li>\n<li>n03</li>")
        #expect(html("li{$@-}*3") == "<li>3</li>\n<li>2</li>\n<li>1</li>")
        #expect(html("li{$@5}*2") == "<li>5</li>\n<li>6</li>")
    }

    @Test func textOnlyAndEmoji() {
        #expect(html("p>{héllo 😀}") == "<p>héllo 😀</p>")
        #expect(html("p{😀}*2") == "<p>😀</p>\n<p>😀</p>")
    }

    @Test func jsxAttributes() {
        #expect(html("label[for=a].b", .jsx) == "<label className=\"b\" htmlFor=\"a\"></label>")
    }

    @Test func invalidAbbreviations() {
        for bad in ["", "a>", ">a", "a++", "a*0", "a[b", "(a", "a)", "a{x"] {
            #expect(html(bad) == nil, "\(bad)")
        }
    }

    @Test func tabStopsAreOrderedWithFinalLast() {
        let s = Emmet.expandMarkup("ul>li*2", flavor: .html, indentUnit: "  ", baseIndent: "")!
        #expect(s.tabStops.map(\.index) == [1, 2, 0])
        #expect(s.tabStops.last?.range.location == (s.text as NSString).length)
        let first = s.tabStops[0].range.location
        #expect((s.text as NSString).substring(to: first) == "<ul>\n  <li>")
        #expect(Emmet.expandMarkup("p{x}", flavor: .html, indentUnit: "  ", baseIndent: "")!.tabStops.isEmpty)
    }

    @Test func baseIndentAppliesAfterFirstLine() {
        let t = Emmet.expandMarkup("ul>li", flavor: .html, indentUnit: "\t", baseIndent: "    ")!.text
        #expect(t == "<ul>\n    \t<li></li>\n    </ul>")
    }

    @Test func extractionFromLine() {
        let text = "<div>\n  ul>li*2"
        let r = Emmet.expansion(in: text, caret: (text as NSString).length, syntax: .markup(.html), indentUnit: "  ")
        #expect(r?.range == NSRange(location: 8, length: 7))
        #expect(r?.snippet.text == "<ul>\n    <li></li>\n    <li></li>\n  </ul>")
        let inline = "<p>b>i"
        let r2 = Emmet.expansion(in: inline, caret: 6, syntax: .markup(.html), indentUnit: "  ")
        #expect(r2?.range == NSRange(location: 3, length: 3))
    }

    @Test func notInsideTagAndJSXGuards() {
        let attr = "<div class=\"a"
        #expect(Emmet.expansion(in: attr, caret: attr.utf16.count, syntax: .markup(.html), indentUnit: "  ") == nil)
        let js = "console.log"
        #expect(Emmet.expansion(in: js, caret: 11, syntax: .markup(.jsx), indentUnit: "  ") == nil)
        let ok = "  div.a"
        #expect(Emmet.expansion(in: ok, caret: 7, syntax: .markup(.jsx), indentUnit: "  ")?.snippet.text
                == "<div className=\"a\"></div>")
    }

    @Test func css() {
        func c(_ s: String) -> String? { Emmet.expandCSS(s)?.text }
        #expect(c("m10") == "margin: 10px;")
        #expect(c("p10-20") == "padding: 10px 20px;")
        #expect(c("m-10") == "margin: -10px;")
        #expect(c("m10--5") == "margin: 10px -5px;")
        #expect(c("m0-a") == "margin: 0 auto;")
        #expect(c("w100p") == "width: 100%;")
        #expect(c("h2e") == "height: 2em;")
        #expect(c("z5") == "z-index: 5;")
        #expect(c("op.5") == "opacity: .5;")
        #expect(c("df") == "display: flex;")
        #expect(c("jcc") == "justify-content: center;")
        #expect(c("m10!") == "margin: 10px !important;")
        #expect(c("mw400") == "max-width: 400px;")
        #expect(c("zzz") == nil)
        #expect(c("m10q") == nil)
        let bare = Emmet.expandCSS("m")!
        #expect(bare.text == "margin: ;")
        #expect(bare.tabStops.first?.range.location == 8)
    }

    @Test func cssContext() {
        let text = ".a {\n  m10"
        let r = Emmet.expansion(in: text, caret: (text as NSString).length, syntax: .css, indentUnit: "  ")
        #expect(r?.snippet.text == "margin: 10px;")
        #expect(r?.range == NSRange(location: 7, length: 3))
        let outside = "m10"
        #expect(Emmet.expansion(in: outside, caret: 3, syntax: .css, indentUnit: "  ") == nil)
        #expect(Emmet.isInsideCSSBlock("/* { */ a", caret: 9) == false)
        #expect(Emmet.isInsideCSSBlock("a { b: \"}\"; ", caret: 12) == true)
        let value = ".a { color: m10"
        #expect(Emmet.expansion(in: value, caret: 15, syntax: .css, indentUnit: "  ") == nil)
    }
}

// MARK: - Column selection / cursors

@Suite struct ColumnSelectionTests {
    @Test func boxAcrossShortLines() {
        let text = "abcdef\nab\nabcdef"
        let state = ColumnSelection.State(anchor: .init(line: 0, column: 1), head: .init(line: 2, column: 4))
        #expect(ColumnSelection.ranges(in: text, state: state) == [
            NSRange(location: 1, length: 3), NSRange(location: 8, length: 1), NSRange(location: 11, length: 3),
        ])
    }

    @Test func emojiColumnsAreCharacters() {
        let text = "😀a😀b\nxyz😀w"
        let ns = text as NSString
        let starts = ColumnSelection.lineStarts(ns)
        #expect(ColumnSelection.position(ns, starts, offset: 2) == .init(line: 0, column: 1))
        #expect(ColumnSelection.lineLength(ns, starts, line: 0) == 4)
        let state = ColumnSelection.State(anchor: .init(line: 0, column: 1), head: .init(line: 1, column: 3))
        #expect(ColumnSelection.ranges(in: text, state: state) == [
            NSRange(location: 2, length: 3), NSRange(location: 8, length: 2),
        ])
    }

    @Test func keyboardMoves() {
        let text = "ab\nabcd\nab"
        var s = ColumnSelection.state(from: [NSRange(location: 1, length: 0)], in: text)!
        s = ColumnSelection.moved(s, .down, in: text)
        s = ColumnSelection.moved(s, .right, in: text)
        #expect(s.head == .init(line: 1, column: 2))
        s = ColumnSelection.moved(s, .down, in: text)
        s = ColumnSelection.moved(s, .left, in: text)
        #expect(s.head == .init(line: 2, column: 1))
        #expect(ColumnSelection.moved(s, .up, in: text).head.line == 1)
        let top = ColumnSelection.moved(.init(anchor: .init(line: 0, column: 0), head: .init(line: 0, column: 0)), .up, in: text)
        #expect(top.head.line == 0)
    }

    @Test func rightStopsAtLongestLine() {
        let text = "ab\ncd"
        var s = ColumnSelection.State(anchor: .init(line: 0, column: 0), head: .init(line: 1, column: 2))
        s = ColumnSelection.moved(s, .right, in: text)
        #expect(s.head.column == 2)
    }

    @Test func addCursorAboveBelow() {
        let text = "hello\nab\nworld 😀"
        let mid = [NSRange(location: 8, length: 0)]            // end of "ab", col 2
        let below = ColumnSelection.addingCursor(to: mid, above: false, in: text)
        #expect(below == [NSRange(location: 8, length: 0), NSRange(location: 11, length: 0)])
        let above = ColumnSelection.addingCursor(to: mid, above: true, in: text)
        #expect(above == [NSRange(location: 2, length: 0), NSRange(location: 8, length: 0)])
        let top = [NSRange(location: 2, length: 0)]
        #expect(ColumnSelection.addingCursor(to: top, above: true, in: text) == top)
        // Clamped to a shorter line, and emoji line measured in characters.
        let end = [NSRange(location: 6 + 3 + 8, length: 0)]
        let up = ColumnSelection.addingCursor(to: end, above: true, in: text)
        #expect(up.first == NSRange(location: 8, length: 0))
        // Single-line selection is mirrored.
        let sel = ColumnSelection.addingCursor(to: [NSRange(location: 1, length: 3)], above: false, in: "abcde\nvwxyz")
        #expect(sel.last == NSRange(location: 7, length: 3))
    }
}

// MARK: - Line commands

@Suite struct LineTransformTests {
    @Test func sort() {
        let t = "pear\napple\n😀\nbanana\n"
        let all = NSRange(location: 0, length: (t as NSString).length)
        #expect(apply(LineOperations.sortLines(text: t, selection: all, ascending: true), to: t) == "apple\nbanana\npear\n😀\n")
        #expect(apply(LineOperations.sortLines(text: t, selection: all, ascending: false), to: t) == "😀\npear\nbanana\napple\n")
        // Caret acts on the whole document; one line is a no-op; sorted is a no-op.
        #expect(apply(LineOperations.sortLines(text: t, selection: NSRange(location: 0, length: 0), ascending: true), to: t) == "apple\nbanana\npear\n😀\n")
        #expect(LineOperations.sortLines(text: "a", selection: NSRange(location: 0, length: 1), ascending: true) == nil)
        #expect(LineOperations.sortLines(text: "a\nb", selection: NSRange(location: 0, length: 3), ascending: true) == nil)
    }

    @Test func sortOnlySelectedLinesWithoutTrailingNewline() {
        let t = "z\nc\nb\na"
        // Select lines 2-3 only, ending at line start of "a" (excluded).
        let sel = NSRange(location: 2, length: 4)
        #expect(apply(LineOperations.sortLines(text: t, selection: sel, ascending: true), to: t) == "z\nb\nc\na")
        let tail = NSRange(location: 2, length: 5)
        #expect(apply(LineOperations.sortLines(text: t, selection: tail, ascending: true), to: t) == "z\na\nb\nc")
    }

    @Test func reverseAndDedupe() {
        let t = "a\nb\na\n😀\n😀\n"
        let all = NSRange(location: 0, length: (t as NSString).length)
        #expect(apply(LineOperations.reverseLines(text: t, selection: all), to: t) == "😀\n😀\na\nb\na\n")
        #expect(apply(LineOperations.removeDuplicateLines(text: t, selection: all), to: t) == "a\nb\n😀\n")
        #expect(LineOperations.removeDuplicateLines(text: "a\nb", selection: NSRange(location: 0, length: 0)) == nil)
    }

    @Test func trim() {
        let t = "a  \n\tb \t\nc\r\nd \r\n"
        let all = NSRange(location: 0, length: (t as NSString).length)
        #expect(apply(LineOperations.trimTrailingWhitespace(text: t, selection: all), to: t) == "a\n\tb\nc\r\nd\r\n")
        #expect(LineOperations.trimTrailingWhitespace(text: "ok\n", selection: NSRange(location: 0, length: 0)) == nil)
        let caretLine = "x  \ny  \n"
        #expect(apply(LineOperations.trimTrailingWhitespace(text: caretLine, selection: NSRange(location: 5, length: 0)), to: caretLine) == "x  \ny\n")
    }

    @Test func join() {
        let t = "a\n   b\n\tc\nd"
        let e = LineOperations.joinLines(text: t, selection: NSRange(location: 0, length: 0))
        #expect(apply(e, to: t) == "a b\n\tc\nd")
        #expect(e?.newSelection == NSRange(location: 2, length: 0))
        let multi = LineOperations.joinLines(text: t, selection: NSRange(location: 0, length: 8))
        #expect(apply(multi, to: t) == "a b c\nd")
        #expect(LineOperations.joinLines(text: "a\nb", selection: NSRange(location: 2, length: 0)) == nil)
        let emoji = "😀\n😀"
        #expect(apply(LineOperations.joinLines(text: emoji, selection: NSRange(location: 0, length: 0)), to: emoji) == "😀 😀")
        #expect(apply(LineOperations.joinLines(text: "a\n\nb", selection: NSRange(location: 0, length: 0)), to: "a\n\nb") == "a\nb")
    }

    @Test func caseTransforms() {
        let t = "hello wörld ß"
        let word = NSRange(location: 8, length: 0)
        #expect(apply(LineOperations.transformCase(text: t, selection: word, to: .uppercase), to: t) == "hello WÖRLD ß")
        let all = NSRange(location: 0, length: (t as NSString).length)
        #expect(apply(LineOperations.transformCase(text: t, selection: all, to: .uppercase), to: t) == "HELLO WÖRLD SS")
        #expect(apply(LineOperations.transformCase(text: "ABC dEf", selection: NSRange(location: 0, length: 7), to: .lowercase), to: "ABC dEf") == "abc def")
        let title = "don't SHOUT 😀x"
        #expect(apply(LineOperations.transformCase(text: title, selection: NSRange(location: 0, length: (title as NSString).length), to: .titlecase), to: title) == "Don't Shout 😀X")
        #expect(LineOperations.transformCase(text: "ABC", selection: NSRange(location: 0, length: 3), to: .uppercase) == nil)
        #expect(LineOperations.transformCase(text: "  ", selection: NSRange(location: 1, length: 0), to: .uppercase) == nil)
        // Length-changing transform keeps a caret at the same logical spot.
        let sharp = LineOperations.transformCase(text: "ß", selection: NSRange(location: 1, length: 0), to: .uppercase)
        #expect(sharp?.newSelection == NSRange(location: 2, length: 0))
    }

    @Test func applyEachShiftsSelections() {
        let t = "ab cd ef"
        let ranges = [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2), NSRange(location: 6, length: 2)]
        let m = LineOperations.applyEach(text: t, ranges: ranges) {
            LineOperations.transformCase(text: $0, selection: $1, to: .uppercase)
        }!
        var s = t as NSString
        for e in m.edits { s = s.replacingCharacters(in: e.range, with: e.replacement) as NSString }
        #expect(s as String == "AB CD EF")
        #expect(m.selections == ranges)
        // Length-changing edits shift later selections.
        let m2 = LineOperations.applyEach(text: "ß ß", ranges: [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)]) {
            LineOperations.transformCase(text: $0, selection: $1, to: .uppercase)
        }!
        #expect(m2.selections == [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
        // Two carets on the same line: only one trim edit.
        let m3 = LineOperations.applyEach(text: "a  \n", ranges: [NSRange(location: 0, length: 0), NSRange(location: 1, length: 0)]) {
            LineOperations.trimTrailingWhitespace(text: $0, selection: $1)
        }!
        #expect(m3.edits.count == 1)
        #expect(LineOperations.applyEach(text: "x", ranges: [NSRange(location: 0, length: 0)]) { _, _ in nil } == nil)
    }
}

// MARK: - Key actions

@Suite struct EditingKeyActionTests {
    @Test func bindingsExist() {
        let d = KeyBinding.vscodeDefaults
        #expect(d.first { $0.action == .joinLines }?.combo == KeyCombo(key: "j", control: true))
        #expect(d.first { $0.action == .insertCursorAbove }?.combo == KeyCombo(key: "up", command: true, option: true))
        #expect(KeyAction.sortLinesAscending.rawValue == "editor.action.sortLinesAscending")
        #expect(KeyAction.columnSelectUp.category == "Editor")
    }
}
