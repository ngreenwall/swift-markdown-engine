//
//  LayoutBridge.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 12.04.26.
//
//  Thin helper around TextKit 2's NSTextLayoutManager for the handful of
//  character-range queries the editor needs.

import AppKit

/// Line height from the bridge, or a font-metric fallback when no bridge is available.
func layoutBridgeDefaultLineHeight(for font: NSFont, using bridge: LayoutBridge? = nil) -> CGFloat {
    bridge?.defaultLineHeight(for: font)
        ?? (font.ascender - font.descender + font.leading)
}

final class LayoutBridge {
    /// Resolved from the text view on every access rather than captured once.
    ///
    /// `NSTextView.textLayoutManager` is derived from its text container, so
    /// repointing the container at a different TextKit 2 stack — which is how a
    /// document can be kept laid out per tab and swapped back in — silently
    /// leaves any CAPTURED layout manager pointing at the previous document.
    /// Every other layout-manager reference in the engine already goes through
    /// `textView.textLayoutManager`; this was the only place that did not.
    ///
    /// Weak, and the text view holds the bridge weakly too — the coordinator owns it.
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
    }

    private var textLayoutManager: NSTextLayoutManager? {
        textView?.textLayoutManager
    }

    private var textContentStorage: NSTextContentStorage? {
        textLayoutManager?.textContentManager as? NSTextContentStorage
    }

    private func textRange(for range: NSRange) -> NSTextRange? {
        guard let tcs = textContentStorage,
              let start = tcs.location(tcs.documentRange.location, offsetBy: range.location),
              let end = tcs.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    func defaultLineHeight(for font: NSFont) -> CGFloat {
        font.ascender - font.descender + font.leading
    }

    func boundingRect(forCharacterRange range: NSRange, in textContainer: NSTextContainer) -> CGRect {
        guard let textLayoutManager, let textRange = textRange(for: range) else { return .zero }
        var result = CGRect.null
        textLayoutManager.enumerateTextSegments(
            in: textRange, type: .standard, options: []
        ) { _, rect, _, _ in
            result = result.isNull ? rect : result.union(rect)
            return true
        }
        return result.isNull ? .zero : result
    }

    func characterIndex(
        for point: CGPoint,
        in textContainer: NSTextContainer,
        fractionOfDistanceBetweenInsertionPoints fraction: inout CGFloat
    ) -> Int {
        guard let textLayoutManager, let tcs = textContentStorage else {
            fraction = 0
            return NSNotFound
        }
        guard let fragment = textLayoutManager.textLayoutFragment(for: point) else {
            fraction = 0
            return NSNotFound
        }
        let fragFrame = fragment.layoutFragmentFrame
        let localPoint = CGPoint(
            x: point.x - fragFrame.origin.x,
            y: point.y - fragFrame.origin.y
        )
        var lineY: CGFloat = 0
        for lineFragment in fragment.textLineFragments {
            let lineBounds = lineFragment.typographicBounds
            if localPoint.y < lineY + lineBounds.height || lineFragment === fragment.textLineFragments.last {
                let lineLocalPoint = CGPoint(x: localPoint.x - lineFragment.glyphOrigin.x,
                                             y: localPoint.y - lineY)
                let charIndex = lineFragment.characterIndex(for: lineLocalPoint)
                let fragmentStart = tcs.offset(
                    from: tcs.documentRange.location,
                    to: fragment.rangeInElement.location
                )
                fraction = lineFragment.fractionOfDistanceThroughGlyph(for: lineLocalPoint)
                return fragmentStart + lineFragment.characterRange.location + charIndex
            }
            lineY += lineBounds.height
        }
        fraction = 0
        return NSNotFound
    }

    func invalidateDisplay(forCharacterRange range: NSRange) {
        // In TextKit 2, invalidating layout also triggers redisplay.
        guard let textLayoutManager, textRange(for: range) != nil else { return }
        textLayoutManager.textViewportLayoutController.layoutViewport()
    }

    func removeTemporaryAttribute(_ attrName: NSAttributedString.Key, forCharacterRange range: NSRange) {
        guard let textLayoutManager, let textRange = textRange(for: range) else { return }
        textLayoutManager.removeRenderingAttribute(attrName, for: textRange)
    }

    var firstTextContainer: NSTextContainer? {
        textLayoutManager?.textContainer
    }
}
