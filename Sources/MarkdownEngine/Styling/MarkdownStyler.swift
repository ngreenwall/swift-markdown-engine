//
//  MarkdownStyler.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Applies the Markdown look (bold, links, code, headings, etc.). Most styling
// is now produced by the AST-native styler (`MarkdownASTStyler`); this type
// builds the `StylingContext` and runs the NSImage rendering passes that still
// consume tokens:
//   - MarkdownStyler+Latex.swift   (block + inline LaTeX rendering)
//   - MarkdownStyler+Images.swift  (image embeds / image links)
//   - MarkdownStyler+Tables.swift  (rendered tables)
import AppKit
import Foundation

// MARK: - Styling Context

extension MarkdownStyler {
    typealias IndexedToken = (index: Int, token: MarkdownToken)

    /// Per-kind token arrays (each with the token's index into the full array,
    /// for activeTokenIndices), built ONCE in the parse classification and
    /// reused across keystrokes. Lets the NSImage passes iterate a small,
    /// scope-sliced array instead of walking every document token per pass.
    struct ClassifiedStyleTokens {
        let inlineLatex: [IndexedToken]
        let blockLatex: [IndexedToken]
        let imageEmbed: [IndexedToken]
        let imageLink: [IndexedToken]
        let table: [IndexedToken]
        let code: [MarkdownToken]   // codeBlock + inlineCode, for isInsideCodeBlock checks
    }

    struct StylingContext {
        let nsText: NSString
        let tokens: [MarkdownToken]
        let codeTokens: [MarkdownToken]
        /// `codeTokens`' ranges, sorted and merged into a minimal non-overlapping
        /// set, so "is this inside code?" becomes a binary search instead of a
        /// linear walk of every code token.
        ///
        /// The linear form made the inline-LaTeX pass O(#latex × #codeTokens):
        /// measured at 86 ms for 1,594 formulas against 989 code tokens on a
        /// 346 KB document — more than the LaTeX rendering it was guarding.
        /// Merging (rather than plain sorting) is what makes the binary search
        /// valid even if an inline-code token nests inside a fenced block.
        let codeRangesMerged: [NSRange]
        let activeTokenIndices: Set<Int>
        let baseFont: NSFont
        let layoutBridge: LayoutBridge?
        let baseDefaultLineHeight: CGFloat
        let codeBackgroundColor: NSColor
        let latexMarkerFont: NSFont
        let configuration: MarkdownEditorConfiguration
        let wikiLinkIDProvider: (NSRange) -> String?
        /// Union bounds of the restyle's paragraph scope; nil = whole document
        /// (initial load). Attribute application clips per paragraph anyway,
        /// so the NSImage passes can skip tokens wholly outside these bounds
        /// instead of walking every token in the document per keystroke.
        var scopeBounds: (lo: Int, hi: Int)? = nil
        /// Pre-classified per-kind token arrays; nil for direct callers (tests),
        /// which fall back to classifying `tokens` on demand.
        var classified: ClassifiedStyleTokens? = nil

        /// `codeRangesMerged` is derived, never passed in — that way it cannot
        /// drift out of sync with `codeTokens`.
        init(
            nsText: NSString,
            tokens: [MarkdownToken],
            codeTokens: [MarkdownToken],
            activeTokenIndices: Set<Int>,
            baseFont: NSFont,
            layoutBridge: LayoutBridge?,
            baseDefaultLineHeight: CGFloat,
            codeBackgroundColor: NSColor,
            latexMarkerFont: NSFont,
            configuration: MarkdownEditorConfiguration,
            wikiLinkIDProvider: @escaping (NSRange) -> String?,
            scopeBounds: (lo: Int, hi: Int)? = nil,
            classified: ClassifiedStyleTokens? = nil
        ) {
            self.nsText = nsText
            self.tokens = tokens
            self.codeTokens = codeTokens
            self.codeRangesMerged = Self.mergedRanges(of: codeTokens)
            self.activeTokenIndices = activeTokenIndices
            self.baseFont = baseFont
            self.layoutBridge = layoutBridge
            self.baseDefaultLineHeight = baseDefaultLineHeight
            self.codeBackgroundColor = codeBackgroundColor
            self.latexMarkerFont = latexMarkerFont
            self.configuration = configuration
            self.wikiLinkIDProvider = wikiLinkIDProvider
            self.scopeBounds = scopeBounds
            self.classified = classified
        }

        var services: MarkdownEditorServices { configuration.services }

        // Per-kind indexed arrays: the cached classification, or a one-off
        // classification of `tokens` when a direct caller passed none.
        var inlineLatexIndexed: [IndexedToken] { classified?.inlineLatex ?? Self.indexed(tokens, .inlineLatex) }
        var blockLatexIndexed: [IndexedToken] { classified?.blockLatex ?? Self.indexed(tokens, .blockLatex) }
        var imageEmbedIndexed: [IndexedToken] { classified?.imageEmbed ?? Self.indexed(tokens, .imageEmbed) }
        var imageLinkIndexed: [IndexedToken] { classified?.imageLink ?? Self.indexed(tokens, .imageLink) }
        var tableIndexed: [IndexedToken] { classified?.table ?? Self.indexed(tokens, .table) }

        static func indexed(_ tokens: [MarkdownToken], _ kind: MarkdownTokenKind) -> [IndexedToken] {
            tokens.enumerated().compactMap { $0.element.kind == kind ? ($0.offset, $0.element) : nil }
        }

        /// Sort + merge token ranges into a minimal ascending, non-overlapping set.
        /// O(n log n) once, so the per-token membership tests can be O(log n).
        static func mergedRanges(of tokens: [MarkdownToken]) -> [NSRange] {
            let sorted = tokens.map(\.range).sorted { $0.location < $1.location }
            var merged: [NSRange] = []
            merged.reserveCapacity(sorted.count)
            for range in sorted {
                if let last = merged.last, range.location <= NSMaxRange(last) {
                    let end = max(NSMaxRange(last), NSMaxRange(range))
                    merged[merged.count - 1] = NSRange(location: last.location, length: end - last.location)
                } else {
                    merged.append(range)
                }
            }
            return merged
        }

        /// Binary-search equivalent of
        /// `MarkdownDetection.isInsideCodeBlock(range:codeTokens:)` against a
        /// merged set. Predicate is identical, including the inclusive
        /// `location <= end` treatment of a zero-length range.
        func isInCode(_ range: NSRange) -> Bool {
            var low = 0
            var high = codeRangesMerged.count - 1
            while low <= high {
                let mid = (low + high) / 2
                let candidate = codeRangesMerged[mid]
                let start = candidate.location
                let end = NSMaxRange(candidate)
                if range.length == 0 {
                    if range.location < start { high = mid - 1 }
                    else if range.location > end { low = mid + 1 }
                    else { return true }
                } else {
                    if NSMaxRange(range) <= start { high = mid - 1 }
                    else if range.location >= end { low = mid + 1 }
                    else { return true }
                }
            }
            return false
        }

        /// The range in a sorted, non-overlapping array that fully encloses
        /// `range`, or nil. Same predicate as the linear
        /// `contains(where: { $0.location <= r.location && NSMaxRange(r) <= NSMaxRange($0) })`.
        static func enclosingRange(_ range: NSRange, in sorted: [NSRange]) -> NSRange? {
            var low = 0
            var high = sorted.count - 1
            while low <= high {
                let mid = (low + high) / 2
                let candidate = sorted[mid]
                if range.location < candidate.location {
                    high = mid - 1
                } else if range.location > NSMaxRange(candidate) {
                    low = mid + 1
                } else {
                    return NSMaxRange(range) <= NSMaxRange(candidate) ? candidate : nil
                }
            }
            return nil
        }

        /// The slice of a location-sorted, non-overlapping per-kind array that
        /// intersects the restyle scope — binary-searched so out-of-scope
        /// tokens are never even visited. Whole array when scope is nil.
        func scoped(_ arr: [IndexedToken]) -> ArraySlice<IndexedToken> {
            guard let bounds = scopeBounds else { return arr[...] }
            return MarkdownStyler.scopedSlice(arr, lo: bounds.lo, hi: bounds.hi)
        }

        /// True when `range` lies entirely outside the restyle scope — its
        /// attributes would be clipped away at application time.
        func outsideScope(_ range: NSRange) -> Bool {
            guard let scopeBounds else { return false }
            return NSMaxRange(range) <= scopeBounds.lo || range.location >= scopeBounds.hi
        }

        /// True when iteration (over location-sorted tokens) is past the scope.
        func pastScope(_ range: NSRange) -> Bool {
            guard let scopeBounds else { return false }
            return range.location >= scopeBounds.hi
        }
    }

    /// Binary-searched slice of a location-sorted, non-overlapping per-kind
    /// array whose tokens intersect `[lo, hi)` — tokens outside are never
    /// visited. Shared by the styler's scope culling and the coordinator's
    /// edit-scoped candidate collection (which used to walk each array
    /// linearly from the document head to the edit).
    static func scopedSlice(_ arr: [IndexedToken], lo bound: Int, hi upper: Int) -> ArraySlice<IndexedToken> {
        var lo = 0, hi = arr.count
        while lo < hi {                                   // first NSMaxRange > bound
            let m = (lo + hi) / 2
            if NSMaxRange(arr[m].token.range) > bound { hi = m } else { lo = m + 1 }
        }
        let start = lo
        hi = arr.count
        while lo < hi {                                   // first location >= upper
            let m = (lo + hi) / 2
            if arr[m].token.range.location >= upper { hi = m } else { lo = m + 1 }
        }
        return arr[start..<lo]
    }
}

typealias StyledRange = (range: NSRange, attributes: [NSAttributedString.Key: Any])

// MARK: - Public API

enum MarkdownStyler {

    static func styleAttributes(
        text: String,
        fontName: String,
        fontSize: CGFloat,
        layoutBridge: LayoutBridge? = nil,
        caretLocation: Int,
        selection: NSRange? = nil,
        activeTokenIndices: Set<Int>,
        wikiLinkIDProvider: @escaping (NSRange) -> String? = { _ in nil },
        precomputedTokens: [MarkdownToken]? = nil,
        classified: ClassifiedStyleTokens? = nil,
        precomputedBlocks: [Block]? = nil,
        scopedRanges: [NSRange]? = nil,
        configuration: MarkdownEditorConfiguration = .default
    ) -> [StyledRange] {
        let tokens = precomputedTokens ?? MarkdownTokenizer.parseTokensViaAST(in: text, registry: configuration.extensionRegistry)
        let nsText = text as NSString
        let scopeBounds: (lo: Int, hi: Int)? = scopedRanges.flatMap { ranges in
            let valid = ranges.filter { $0.location != NSNotFound && $0.length > 0 }
            guard let lo = valid.map(\.location).min(),
                  let hi = valid.map({ NSMaxRange($0) }).max() else { return nil }
            return (lo, hi)
        }
        let codeTokens = classified?.code ?? tokens.filter { $0.kind == .codeBlock || $0.kind == .inlineCode }
        let baseFont = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        let baseDefaultLineHeight = ceil(
            layoutBridge?.defaultLineHeight(for: baseFont)
            ?? (baseFont.ascender - baseFont.descender + baseFont.leading)
        )
        let codeBackgroundColor = configuration.services.syntaxHighlighter.backgroundColor()
        let hiddenMarkerSize = configuration.markers.hiddenMarkerFontSize
        let ctx = StylingContext(
            nsText: nsText,
            tokens: tokens,
            codeTokens: codeTokens,
            activeTokenIndices: activeTokenIndices,
            baseFont: baseFont,
            layoutBridge: layoutBridge,
            baseDefaultLineHeight: baseDefaultLineHeight,
            codeBackgroundColor: codeBackgroundColor,
            latexMarkerFont: NSFont(name: fontName, size: hiddenMarkerSize)
                ?? NSFont.systemFont(ofSize: hiddenMarkerSize),
            configuration: configuration,
            wikiLinkIDProvider: wikiLinkIDProvider,
            scopeBounds: scopeBounds,
            classified: classified
        )

        var result: [StyledRange] = []
        // AST-native styler handles everything but NSImage rendering (incl. the composition fixes).
        let astT0 = DispatchTime.now().uptimeNanoseconds
        result += PerfTrace.switchCount("style.ast") {
            MarkdownASTStyler.styleAttributes(
                text: text, fontName: fontName, fontSize: fontSize,
                caretLocation: caretLocation, selection: selection, wikiLinkIDProvider: wikiLinkIDProvider,
                scopedRanges: scopedRanges, precomputedBlocks: precomputedBlocks,
                configuration: configuration
            )
        }
        let astMs = Double(DispatchTime.now().uptimeNanoseconds - astT0) / 1_000_000
        // NSImage rendering reuses the existing, proven machinery.
        let imgT0 = DispatchTime.now().uptimeNanoseconds
        result += PerfTrace.switchCount("style.latexBlockPass") { styleBlockLatex(ctx) }
        result += PerfTrace.switchCount("style.latexInlinePass") { styleInlineLatex(ctx) }
        result += PerfTrace.switchCount("style.imageEmbeds") { styleImageEmbeds(ctx) }
        result += PerfTrace.switchCount("style.imageLinks") { styleImageLinks(ctx) }
        let imgMs = Double(DispatchTime.now().uptimeNanoseconds - imgT0) / 1_000_000
        result += PerfTrace.switchCount("style.tables") { styleTables(ctx) }
        PerfTrace.note { "  styleAttributes: ast=\(String(format: "%.2f", astMs))ms latex+img4=\(String(format: "%.2f", imgMs))ms styledRanges=\(result.count)" }
        return result
    }
}

// MARK: - Shared helpers used by multiple styling extensions

extension MarkdownStyler {

    static func appendSecondaryMarkers(
        for token: MarkdownToken,
        to attrs: inout [StyledRange],
        theme: MarkdownEditorTheme
    ) {
        token.markerRanges.forEach {
            attrs.append(($0, [.foregroundColor: theme.mutedText]))
        }
    }

    enum RenderedStandaloneBlockMode {
        case collapsedSource(markerTexts: [String])
        case visibleSource(imageGap: CGFloat)
        /// Wide-table mode: anchor reserves container width, line gains scroller strip, tagged by sourceID.
        case collapsedSourceScrollable(
            markerTexts: [String],
            displayWidth: CGFloat,
            sourceID: Int
        )
    }

    static func appendRenderedStandaloneBlock(
        for token: MarkdownToken,
        rawContent: String,
        image: NSImage,
        imageBounds: CGRect,
        paragraphSpacingBefore: CGFloat,
        paragraphSpacing: CGFloat,
        alignment: NSTextAlignment,
        mode: RenderedStandaloneBlockMode,
        ctx: StylingContext,
        attrs: inout [StyledRange]
    ) -> Bool {
        guard let paraRange = token.standaloneParagraphRange(in: ctx.nsText) else { return false }

        let para = NSMutableParagraphStyle()
        let baseLineHeight = layoutBridgeDefaultLineHeight(for: ctx.baseFont, using: ctx.layoutBridge)
        para.paragraphSpacingBefore = max(para.paragraphSpacingBefore, paragraphSpacingBefore)
        para.alignment = alignment

        switch mode {
        case .collapsedSource(let markerTexts):
            emitCollapsedAttrs(
                token: token,
                rawContent: rawContent,
                image: image,
                imageBounds: imageBounds,
                paragraphSpacing: paragraphSpacing,
                para: para,
                paraRange: paraRange,
                advanceWidth: imageBounds.width,
                neededLineHeight: imageBounds.height,
                extraAnchorAttrs: [:],
                markerTexts: markerTexts,
                ctx: ctx,
                attrs: &attrs
            )

        case .collapsedSourceScrollable(let markerTexts, let displayWidth, let sourceID):
            let scrollerStrip = MarkdownTextLayoutFragment.scrollableBlockScrollerStrip
            let totalHeight = imageBounds.height + scrollerStrip
            emitCollapsedAttrs(
                token: token,
                rawContent: rawContent,
                image: image,
                imageBounds: imageBounds,
                paragraphSpacing: paragraphSpacing,
                para: para,
                paraRange: paraRange,
                advanceWidth: displayWidth,
                neededLineHeight: totalHeight,
                extraAnchorAttrs: [
                    .scrollableBlockNaturalWidth: imageBounds.width,
                    .scrollableBlockSourceID: sourceID,
                    .scrollableBlockTotalHeight: totalHeight,
                    .scrollableBlockFullRange: NSValue(range: paraRange)
                ],
                markerTexts: markerTexts,
                ctx: ctx,
                attrs: &attrs
            )

        case .visibleSource(let imageGap):
            para.minimumLineHeight = max(para.minimumLineHeight, baseLineHeight)
            para.maximumLineHeight = max(para.maximumLineHeight, baseLineHeight)
            para.paragraphSpacing = max(para.paragraphSpacing, imageBounds.height + imageGap + paragraphSpacing)

            attrs.append((paraRange, [.paragraphStyle: para]))
            attrs.append((token.range, [
                .latexImage: image,
                .latexBounds: NSValue(rect: imageBounds),
                .latexIsBlock: true,
                .latexBlockOffsetY: baseLineHeight + imageGap
            ]))
            appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
        }

        return true
    }

    /// Shared body for collapsed-source modes; hides raw source, plants image on anchor.
    private static func emitCollapsedAttrs(
        token: MarkdownToken,
        rawContent: String,
        image: NSImage,
        imageBounds: CGRect,
        paragraphSpacing: CGFloat,
        para: NSMutableParagraphStyle,
        paraRange: NSRange,
        advanceWidth: CGFloat,
        neededLineHeight: CGFloat,
        extraAnchorAttrs: [NSAttributedString.Key: Any],
        markerTexts: [String],
        ctx: StylingContext,
        attrs: inout [StyledRange]
    ) {
        let baseLineHeight = layoutBridgeDefaultLineHeight(for: ctx.baseFont, using: ctx.layoutBridge)
        let resolved = max(para.minimumLineHeight, neededLineHeight, baseLineHeight)
        para.minimumLineHeight = resolved
        para.maximumLineHeight = max(para.maximumLineHeight, resolved)
        para.paragraphSpacing = max(para.paragraphSpacing, paragraphSpacing)
        para.lineBreakMode = .byClipping

        let collapsedPara = NSMutableParagraphStyle()
        collapsedPara.maximumLineHeight = 1
        collapsedPara.paragraphSpacing = 0
        collapsedPara.paragraphSpacingBefore = 0

        let leadingWhitespaceUnits = rawContent.utf16.prefix { codeUnit in
            guard let scalar = UnicodeScalar(UInt32(codeUnit)) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }.count
        let contentEnd = NSMaxRange(token.contentRange)
        let anchorLocation = min(token.contentRange.location + leadingWhitespaceUnits, contentEnd - 1)

        var paragraphAttributes: [StyledRange] = []
        ctx.nsText.enumerateSubstrings(in: paraRange, options: .byParagraphs) { _, _, enclosingRange, _ in
            if NSLocationInRange(anchorLocation, enclosingRange) {
                paragraphAttributes.append((enclosingRange, [.paragraphStyle: para]))
            } else {
                paragraphAttributes.append((enclosingRange, [.paragraphStyle: collapsedPara]))
            }
        }
        attrs.append(contentsOf: paragraphAttributes)

        if leadingWhitespaceUnits > 0 {
            let leadingRange = NSRange(location: token.contentRange.location, length: leadingWhitespaceUnits)
            let leadingText = ctx.nsText.substring(with: leadingRange)
            attrs.append((leadingRange, [
                .foregroundColor: NSColor.clear,
                .font: ctx.latexMarkerFont,
                .kern: -HeadingHelpers.textWidth(leadingText, font: ctx.latexMarkerFont)
            ]))
        }

        let anchorRange = NSRange(location: anchorLocation, length: 1)
        let anchorChar = ctx.nsText.substring(with: anchorRange)
        var anchorAttrs: [NSAttributedString.Key: Any] = [
            .latexImage: image,
            .latexBounds: NSValue(rect: imageBounds),
            .latexIsBlock: true,
            .foregroundColor: NSColor.clear,
            .font: ctx.latexMarkerFont,
            .kern: advanceWidth - HeadingHelpers.textWidth(anchorChar, font: ctx.latexMarkerFont)
        ]
        for (key, value) in extraAnchorAttrs { anchorAttrs[key] = value }
        attrs.append((anchorRange, anchorAttrs))

        let trailingStart = anchorLocation + 1
        let trailingLength = contentEnd - trailingStart
        if trailingLength > 0 {
            let trailingRange = NSRange(location: trailingStart, length: trailingLength)
            let trailingText = ctx.nsText.substring(with: trailingRange)
            attrs.append((trailingRange, [
                .foregroundColor: NSColor.clear,
                .font: ctx.latexMarkerFont,
                .kern: -HeadingHelpers.textWidth(trailingText, font: ctx.latexMarkerFont)
            ]))
        }

        for (index, markerRange) in token.markerRanges.enumerated() {
            let markerText = markerTexts.indices.contains(index)
                ? markerTexts[index]
                : ctx.nsText.substring(with: markerRange)
            attrs.append((markerRange, [
                .foregroundColor: NSColor.clear,
                .font: ctx.latexMarkerFont,
                .kern: -HeadingHelpers.textWidth(markerText, font: ctx.latexMarkerFont)
            ]))
        }

        let preTokenLength = token.range.location - paraRange.location
        if preTokenLength > 0 {
            let preTokenRange = NSRange(location: paraRange.location, length: preTokenLength)
            let preTokenText = ctx.nsText.substring(with: preTokenRange)
            attrs.append((preTokenRange, [
                .foregroundColor: NSColor.clear,
                .font: ctx.latexMarkerFont,
                .kern: -HeadingHelpers.textWidth(preTokenText, font: ctx.latexMarkerFont)
            ]))
        }
    }
}

// MARK: - Whole-document & inline-only styling kept inline (small helpers)

extension MarkdownStyler {

    /// Line range if `location` is on a thematic-break line (3+ `-`/`*`/`_`), else nil; drives HR restyle.
    static func hrLineRange(at location: Int, in text: String) -> NSRange? {
        let nsText = text as NSString
        let safeLoc = max(0, min(location, nsText.length))
        let lineRange = nsText.lineRange(for: NSRange(location: safeLoc, length: 0))
        let line = nsText.substring(with: lineRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.range(
            of: #"^[ \t]*(-{3,}|\*{3,}|_{3,})[ \t]*$"#,
            options: .regularExpression
        ) != nil else {
            return nil
        }
        return lineRange
    }
}
