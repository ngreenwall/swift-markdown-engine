//
//  MarkdownASTStylerTests.swift
//  MarkdownEngineTests
//
//  Phase 2.5b — the AST styler composes nested/combined inline styles instead
//  of overwriting them (the flat 18-pass styler's flaw).
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Phase 2.5b — AST styler font composition")
struct MarkdownASTStylerTests {

    private let base: CGFloat = 14
    private var fontName: String { NSFont.systemFont(ofSize: 14).fontName }

    /// Effective font at `pos`: the last styled range covering it that sets `.font`.
    private func font(in attrs: [StyledRange], at pos: Int) -> NSFont? {
        var result: NSFont?
        for (range, a) in attrs where NSLocationInRange(pos, range) {
            if let f = a[.font] as? NSFont { result = f }
        }
        return result
    }

    /// Per-keystroke perf: scoping a restyle to the edited paragraph must produce
    /// the EXACT same attributes within that paragraph as a full-document style.
    /// This is the safety net for the `scopedRanges` fast path — it can't diverge
    /// from the full rebuild (no glitch).
    @MainActor
    @Test("scoped styling == full styling, clipped to the edited paragraph")
    func scopedMatchesFullForEditedParagraph() {
        _ = NSApplication.shared
        let text = "plain one\n\n**bold** in two `code`\n\n- item *x*\n\nhttps://example.com"
        let ns = text as NSString
        let para = ns.paragraphRange(for: NSRange(location: 13, length: 0))   // the `**bold**…` line
        func keys(_ scoped: [NSRange]?) -> String {
            let r = MarkdownASTStyler.styleAttributes(
                text: text, fontName: fontName, fontSize: base, scopedRanges: scoped
            ).filter { NSIntersectionRange($0.range, para).length > 0 }
            return styleKeySnapshot(r)
        }
        #expect(keys([para]) == keys(nil))
    }

    @Test("bold inside a heading stays heading-size and consistent (fixes # **n*o*des**)")
    func headingBoldComposesToHeadingSize() {
        let attrs = MarkdownASTStyler.styleAttributes(text: "# **n*o*des**", fontName: fontName, fontSize: base)
        // "# **n*o*des**": n=4, o=6, d=8
        let n = font(in: attrs, at: 4)
        let o = font(in: attrs, at: 6)
        let d = font(in: attrs, at: 8)

        // The fix: every emphasized char is the SAME (heading) size — not "o" big, "n/des" small.
        #expect(n?.pointSize == o?.pointSize)
        #expect(n?.pointSize == d?.pointSize)
        #expect((n?.pointSize ?? 0) > base)   // heading-size, not base

        // Correct composed traits.
        #expect(n?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(d?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(o?.fontDescriptor.symbolicTraits.contains([.bold, .italic]) == true)
    }

    @Test("nested emphasis in a paragraph composes bold+italic")
    func paragraphNestedEmphasis() {
        let attrs = MarkdownASTStyler.styleAttributes(text: "**a *b* c**", fontName: fontName, fontSize: base)
        // "**a *b* c**": a=2, b=5, c=8
        let a = font(in: attrs, at: 2)
        let b = font(in: attrs, at: 5)
        #expect(a?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(a?.fontDescriptor.symbolicTraits.contains(.italic) == false)
        #expect(b?.fontDescriptor.symbolicTraits.contains([.bold, .italic]) == true)
    }

    /// Code is not prose: fenced blocks and inline `code` spans must carry
    /// `.spellingState: 0` so the system spell-checker leaves them alone,
    /// matching the existing convention that links / wiki-links / LaTeX / tables
    /// already follow.
    @Test("code blocks and inline code receive .spellingState: 0; prose does not")
    func codeRegionsSuppressSpellCheck() {
        let text = "prose word\n\n```\nfencedcd notaword\n```\n\nplain `inlnecode` tail"
        let attrs = MarkdownASTStyler.styleAttributes(text: text, fontName: fontName, fontSize: base)
        let ns = text as NSString
        let fencedContent = ns.range(of: "fencedcd notaword")
        let inlineSpan = ns.range(of: "`inlnecode`")
        let prose = ns.range(of: "prose word")

        // Pull every `.spellingState` value from styled ranges that intersect `r`.
        func spellingStates(intersecting r: NSRange) -> [Int] {
            attrs.compactMap { entry -> Int? in
                guard NSIntersectionRange(entry.range, r).length > 0 else { return nil }
                return entry.attributes[.spellingState] as? Int
            }
        }

        #expect(spellingStates(intersecting: fencedContent).contains(0))
        #expect(spellingStates(intersecting: inlineSpan).contains(0))
        #expect(spellingStates(intersecting: prose).isEmpty)
    }

    /// `.link` attribute lookup at a position, mirroring `font(in:at:)` above.
    private func linkValue(in attrs: [StyledRange], at pos: Int) -> Any? {
        var result: Any?
        for entry in attrs where NSLocationInRange(pos, entry.range) {
            if let v = entry.attributes[.link] { result = v }
        }
        return result
    }

    @Test("absolute link (has a scheme) styles .link as a URL")
    func absoluteLinkStylesAsURL() {
        let text = "see [site](https://example.com)"
        let attrs = MarkdownASTStyler.styleAttributes(text: text, fontName: fontName, fontSize: base)
        let pos = (text as NSString).range(of: "site").location
        #expect(linkValue(in: attrs, at: pos) is URL)
    }

    @Test("relative link (no scheme) styles .link as the raw path string, not a rewritten https URL")
    func relativeLinkStylesAsRawString() {
        let text = "see [note](wren-test.md)"
        let attrs = MarkdownASTStyler.styleAttributes(text: text, fontName: fontName, fontSize: base)
        let pos = (text as NSString).range(of: "note").location
        #expect(linkValue(in: attrs, at: pos) as? String == "wren-test.md")
    }

    /// Only resolves a wikilink named "Existing"; everything else is unresolved.
    private struct FakeWikiLinkResolver: WikiLinkResolver {
        func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? {
            WikiLinkResolution(id: displayName, exists: displayName == "Existing")
        }
    }

    @Test("resolved wikilink still styles .link (regression guard)")
    func resolvedWikiLinkStylesLink() {
        let text = "see [[Existing]]"
        let config = MarkdownEditorConfiguration(services: .init(wikiLinks: FakeWikiLinkResolver()))
        let attrs = MarkdownASTStyler.styleAttributes(text: text, fontName: fontName, fontSize: base, configuration: config)
        let pos = (text as NSString).range(of: "Existing").location
        #expect(linkValue(in: attrs, at: pos) as? String == "Existing")
    }

    @Test("unresolved wikilink now also styles .link, so create-on-click can fire")
    func unresolvedWikiLinkStylesLinkToo() {
        let text = "see [[Brand New Note]]"
        let config = MarkdownEditorConfiguration(services: .init(wikiLinks: FakeWikiLinkResolver()))
        let attrs = MarkdownASTStyler.styleAttributes(text: text, fontName: fontName, fontSize: base, configuration: config)
        let pos = (text as NSString).range(of: "Brand New Note").location
        #expect(linkValue(in: attrs, at: pos) as? String == "Brand New Note")
        // Still styled as disabled/muted, not the active link color.
        let hasDisabledColor = attrs.contains { entry in
            NSLocationInRange(pos, entry.range) && entry.attributes[.foregroundColor] != nil
        }
        #expect(hasDisabledColor)
    }

    /// `.link` attribute lookup at a position, mirroring `linkValue(in:at:)`.
    private func attributeValue(_ key: NSAttributedString.Key, in attrs: [StyledRange], at pos: Int) -> Any? {
        var result: Any?
        for entry in attrs where NSLocationInRange(pos, entry.range) {
            if let v = entry.attributes[key] { result = v }
        }
        return result
    }

    /// A wikilink and a regular link both reduce to the same bare-`String`
    /// `.link` value once unresolved (see the two tests above), so click
    /// routing can't tell them apart from `.link` alone — `.isWikiLink` is
    /// the attribute that lets it. Covers the specific case that broke
    /// downstream: a wikilink display name that happens to look like a file
    /// path (`[[test.md]]`), which `.link`'s shape alone can't distinguish
    /// from a real relative link to `test.md`.
    @Test("wikilink sets .isWikiLink; regular link (even one shaped like a wikilink extension) does not")
    func isWikiLinkDistinguishesFromRegularLink() {
        let text = "[[test.md]] and [reg](test.md)"
        let config = MarkdownEditorConfiguration(services: .init(wikiLinks: FakeWikiLinkResolver()))
        let attrs = MarkdownASTStyler.styleAttributes(text: text, fontName: fontName, fontSize: base, configuration: config)
        let ns = text as NSString

        let wikiLinkPos = ns.range(of: "test.md").location
        let regularLinkPos = ns.range(of: "reg").location

        #expect(attributeValue(.link, in: attrs, at: wikiLinkPos) as? String == "test.md")
        #expect(attributeValue(.isWikiLink, in: attrs, at: wikiLinkPos) as? Bool == true)

        #expect(attributeValue(.link, in: attrs, at: regularLinkPos) as? String == "test.md")
        #expect(attributeValue(.isWikiLink, in: attrs, at: regularLinkPos) == nil)
    }
}

/// Canonical, order-independent string of styled ranges so two style runs can be
/// compared for equality.
private func styleKeySnapshot(_ ranges: [StyledRange]) -> String {
    let lines = ranges
        .map { entry -> (NSRange, [String]) in
            (entry.range, entry.attributes.keys.map(\.rawValue).sorted())
        }
        .sorted { a, b in
            if a.0.location != b.0.location { return a.0.location < b.0.location }
            if a.0.length != b.0.length { return a.0.length < b.0.length }
            return a.1.joined(separator: ",") < b.1.joined(separator: ",")
        }
        .map { "@\(fmt($0.0)) keys=[\($0.1.joined(separator: ","))]" }
    return lines.isEmpty ? "(no styled ranges)" : lines.joined(separator: "\n")
}

private func fmt(_ r: NSRange) -> String {
    r.location == NSNotFound ? "∅" : "\(r.location)+\(r.length)"
}
