//
//  ListHandlerBracketOvertypeTests.swift
//  MarkdownEngineTests
//
//  Regression coverage for the checklist stray-bracket bug: typing `[` auto-pairs
//  to `[]`, and the user's subsequent `]` keystroke must overtype the auto-closed
//  bracket instead of inserting a duplicate.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("List handler bracket overtype")
struct ListHandlerBracketOvertypeTests {

    /// Builds a real NativeTextView and drives it through `MarkdownInputHandler`
    /// exactly as the delegate does: consult the handler first, and only perform
    /// the raw insertion ourselves when it declines (returns `true`).
    private func makeTextView(initialText: String = "", caret: Int? = nil) -> NativeTextView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let textView = NativeTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = true
        textView.configuration = .default
        textView.string = initialText
        textView.setSelectedRange(NSRange(location: caret ?? (initialText as NSString).length, length: 0))
        return textView
    }

    private func type(_ string: String, into textView: NativeTextView) {
        let range = textView.selectedRange()
        let handled = MarkdownInputHandler.handleListInsertion(
            textView: textView,
            affectedCharRange: range,
            replacementString: string
        )
        guard handled else { return }
        textView.textStorage?.replaceCharacters(in: range, with: string)
        textView.setSelectedRange(NSRange(location: range.location + (string as NSString).length, length: 0))
    }

    @Test func openBracketAutoPairsWithCaretInside() {
        let tv = makeTextView()
        type("[", into: tv)
        #expect(tv.string == "[]")
        #expect(tv.selectedRange() == NSRange(location: 1, length: 0))
    }

    @Test func closeBracketOvertypesAutoPairedBracket() {
        let tv = makeTextView(initialText: "[]", caret: 1)
        type("]", into: tv)
        #expect(tv.string == "[]")
        #expect(tv.selectedRange() == NSRange(location: 2, length: 0))
    }

    @Test func checkboxTypingSequenceEndsWithExactlyOneCloseBracket() {
        let tv = makeTextView(initialText: "- ", caret: 2)
        type("[", into: tv)
        type(" ", into: tv)
        type("]", into: tv)
        type(" ", into: tv)
        #expect(tv.string == "- [ ] ")
        #expect(tv.string.filter { $0 == "]" }.count == 1)
    }

    @Test func closeBracketWithoutAutoPairAheadInsertsNormally() {
        let tv = makeTextView(initialText: "[ ", caret: 2)
        type("]", into: tv)
        #expect(tv.string == "[ ]")
    }

    @Test func enterAfterCheckboxItemContinuesWithoutStrayBracket() {
        let tv = makeTextView(initialText: "- [ ] item", caret: 10)
        type("\n", into: tv)
        #expect(tv.string == "- [ ] item\n- [ ] ")
        #expect(tv.string.filter { $0 == "]" }.count == 2)
    }
}
