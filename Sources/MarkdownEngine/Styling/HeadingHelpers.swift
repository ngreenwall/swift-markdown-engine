//
//  HeadingHelpers.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Small helper values for heading size/spacing, plus shared text measurements.
import AppKit

enum HeadingHelpers {

    /// Use heading context to scale LaTeX font size consistently with surrounding text.
    /// `headings` is the document's heading tokens, built once per styling pass —
    /// scanning all tokens per LaTeX token here was O(#latex × #tokens).
    static func latexFontSize(
        for token: MarkdownToken,
        headings: [MarkdownToken],
        baseFont: NSFont,
        configuration: HeadingStyle = .default
    ) -> CGFloat {
        if let headingToken = enclosingHeading(at: token.contentRange.location, in: headings) {
            let level = headingToken.markerRanges.first?.length ?? 1
            return baseFont.pointSize * configuration.fontMultiplier(for: level)
        }
        return baseFont.pointSize
    }

    /// Binary search instead of `headings.first(where:)`.
    ///
    /// This is called once per LaTeX token, so the linear scan made the inline
    /// LaTeX pass O(#latex × #headings) — 1,594 formulas × 426 headings = 679k
    /// range checks on a 346 KB document, measured as ~152 ms of walk around
    /// only ~4.5 ms of actual rendering. `headings` is built from the token
    /// stream, so it is already in ascending document order, and headings never
    /// overlap — which is exactly what a binary search needs.
    ///
    /// Match semantics are identical to `NSLocationInRange`: a zero-length
    /// heading range matches nothing, as before.
    private static func enclosingHeading(at location: Int, in headings: [MarkdownToken]) -> MarkdownToken? {
        var low = 0
        var high = headings.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = headings[mid].contentRange
            if location < range.location {
                high = mid - 1
            } else if location >= NSMaxRange(range) {
                low = mid + 1
            } else {
                return headings[mid]
            }
        }
        return nil
    }

    /// Advance width of `text` in `font`, memoized.
    ///
    /// This is a hot leaf: the inline-LaTeX styler alone calls it four times per
    /// formula (two of them for the constant `"$"`), so a document with ~1,600
    /// inline formulas drives it ~6,400 times per styling pass over a handful of
    /// distinct inputs. `NSString.size(withAttributes:)` builds a throwaway
    /// CoreText run each time; measured ~30 ms per pass, paid on every load AND
    /// every restyle. The distinct-input count stays tiny (marker glyphs, single
    /// characters), so a plain dictionary collapses it.
    ///
    /// Keyed by the `NSFont` object itself rather than name+size, so fonts that
    /// share a PostScript name but differ in traits can never collide.
    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        let key = WidthKey(text: text, font: font)
        widthCacheLock.lock()
        if let cached = widthCache[key] {
            widthCacheLock.unlock()
            return cached
        }
        widthCacheLock.unlock()

        let width = (text as NSString).size(withAttributes: [.font: font]).width

        widthCacheLock.lock()
        // Bounded: long unique strings (image URLs via MarkdownStyler+Images)
        // could otherwise grow this without limit. Wholesale drop is fine — the
        // working set is rebuilt within one styling pass.
        if widthCache.count >= 4096 { widthCache.removeAll(keepingCapacity: true) }
        widthCache[key] = width
        widthCacheLock.unlock()
        return width
    }

    private struct WidthKey: Hashable {
        let text: String
        let font: NSFont
    }

    private static var widthCache: [WidthKey: CGFloat] = [:]
    private static let widthCacheLock = NSLock()
}
