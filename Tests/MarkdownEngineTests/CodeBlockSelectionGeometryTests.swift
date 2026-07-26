//
//  CodeBlockSelectionGeometryTests.swift
//  MarkdownEngineTests
//
//  Regression coverage for the code-block selection-highlight bug: the cutout
//  rects used to punch selection holes in the code-block background fill must
//  use each visual row's own vertical extent (not the whole fragment's), so a
//  wrapped line doesn't produce overlapping full-height rects that cancel out
//  under the evenOdd fill; and a fully-selected interior line should extend to
//  the block's full width instead of staying glyph-tight.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Code block selection highlight geometry")
struct CodeBlockSelectionGeometryTests {

    /// Retains the layout-manager delegate and coordinator alongside the text
    /// view: `NSTextLayoutManager.delegate` is weak, and without something
    /// keeping `MarkdownLayoutManagerDelegate` alive for the test's duration,
    /// `textLayoutManager(_:textLayoutFragmentFor:in:)` stops firing and every
    /// fragment reverts to a plain `NSTextLayoutFragment` instead of
    /// `MarkdownTextLayoutFragment` — mirrors `NativeTextViewWrapper.makeNSView`.
    private struct StyledTextViewHarness {
        let textView: NativeTextView
        let coordinator: NativeTextViewCoordinator
        let layoutDelegate: MarkdownLayoutManagerDelegate
    }

    private func makeStyledTextView(text: String, width: CGFloat) -> StyledTextViewHarness {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        let textView = NativeTextView(frame: scrollView.contentView.bounds)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.isEditable = true
        textView.configuration = .default

        guard let textContainer = textView.textContainer, let tlm = textView.textLayoutManager else {
            fatalError("NSTextView did not create a TextKit 2 stack on this OS version")
        }
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = true
        let layoutDelegate = MarkdownLayoutManagerDelegate()
        tlm.delegate = layoutDelegate

        let coordinator = NativeTextViewCoordinator(
            text: .constant(""),
            fontName: "SF Pro Text",
            fontSize: 14,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        coordinator.textView = textView
        textView.string = text
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        coordinator.restyleTextView(textView, paragraphCandidates: [fullRange])
        tlm.ensureLayout(for: tlm.documentRange)
        return StyledTextViewHarness(textView: textView, coordinator: coordinator, layoutDelegate: layoutDelegate)
    }

    private func codeBlockFragments(in textView: NativeTextView) -> [MarkdownTextLayoutFragment] {
        guard let tlm = textView.textLayoutManager else { return [] }
        var fragments: [MarkdownTextLayoutFragment] = []
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { fragment in
            if let mdFragment = fragment as? MarkdownTextLayoutFragment {
                fragments.append(mdFragment)
            }
            return true
        }
        return fragments
    }

    @Test func wrappedLineSelectionRowsStayWithinFragmentBoundsWithDistinctYs() {
        let longLine = String(repeating: "let x = \"padding to force a wrap\"; ", count: 6)
        let text = "```\n\(longLine)\n```\n"
        let harness = makeStyledTextView(text: text, width: 160)
        let textView = harness.textView
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))

        let fragments = codeBlockFragments(in: textView)
        guard let wrapped = fragments.first(where: { $0.textLineFragments.count > 1 }) else {
            Issue.record("Expected at least one code-block fragment to wrap at width 160")
            return
        }

        let point = wrapped.layoutFragmentFrame.origin
        let bgRect = CGRect(origin: point, size: wrapped.layoutFragmentFrame.size)
        let rects = wrapped.selectionRectsInDrawCoordinates(drawPoint: point, bgRect: bgRect, scale: 2.0)

        #expect(rects.count > 1)
        for rect in rects {
            #expect(rect.minY >= bgRect.minY - 0.5)
            #expect(rect.maxY <= bgRect.maxY + 0.5)
        }
        // The bug: every row got the whole fragment's height, so distinct
        // rows fully overlapped instead of stacking. Distinct y origins prove
        // each row now carries its own vertical extent.
        let uniqueYs = Set(rects.map { $0.minY.rounded() })
        #expect(uniqueYs.count == rects.count)
    }

    @Test func fullySelectedInteriorLineExtendsToBlockWidth() {
        let text = "```\nshort one\nshort two\nshort three\n```\n"
        let harness = makeStyledTextView(text: text, width: 400)
        let textView = harness.textView
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))

        let fragments = codeBlockFragments(in: textView)
        guard fragments.count >= 3 else {
            Issue.record("Expected at least 3 code-block line fragments, got \(fragments.count)")
            return
        }
        // Middle line ("short two") is fully inside the selection and doesn't
        // wrap, so it's the simple single-row, full-line case.
        let middle = fragments[1]
        let point = middle.layoutFragmentFrame.origin
        let bgRect = CGRect(x: 0, y: point.y, width: 380, height: middle.layoutFragmentFrame.height)
        let rects = middle.selectionRectsInDrawCoordinates(drawPoint: point, bgRect: bgRect, scale: 2.0)

        #expect(rects.count == 1)
        if let rect = rects.first {
            #expect(abs(rect.maxX - bgRect.maxX) < 0.5)
        }
    }
}
