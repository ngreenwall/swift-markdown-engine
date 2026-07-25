//
//  DocumentSession.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 25.07.26.
//
//  Everything the coordinator knows that belongs to the DOCUMENT rather than to
//  the text view.
//
//  The editor has one NSTextView for every open tab, so all of this used to live
//  directly on the coordinator — one document's state wearing a singleton's
//  clothes. That is survivable while a switch throws the old document away
//  wholesale, and fatal the moment two documents are alive at once: the fields
//  below include `lastComputedStorage`, the splice base for the incremental
//  writeback. A swap that restored the text but not the splice base would write
//  document A's content spliced with document B's edit to disk, silently.
//
//  Hence one object rather than a save/restore of individual fields: swapping a
//  document becomes a single assignment, and no future field can be forgotten,
//  because adding it here makes it travel automatically. The coordinator keeps
//  forwarding properties so existing call sites are unchanged.
//
//  What deliberately does NOT live here: state that belongs to the view or the
//  session rather than the document — WritingTools bookkeeping, spell-checking
//  preferences, drag-select flags, the first responder, find state. Those stay
//  correct across a document swap precisely because they do not travel.
//

import AppKit

final class DocumentSession {

    // MARK: Text mirrors

    /// Storage-form text as of the last sync. Updates via async dispatch, so it
    /// can lag a keystroke — `lastComputedStorage` is the synchronous one.
    var lastSyncedText: String = ""

    /// Storage form computed by the previous wiki sync, kept synchronously.
    /// **This is the splice base for the incremental writeback**, and the single
    /// most dangerous field in this type: wrong here means wrong bytes on disk.
    var lastComputedStorage: String = ""

    /// Display-text length after the previous textDidChange — yields the edit's
    /// length delta without retaining the previous text.
    var previousDisplayLength: Int = -1

    /// Range-keyed `[[Name|uuid]]` metadata for the current display text. Paired
    /// with `lastComputedStorage`: the writeback reads both, and a mismatch is
    /// how wiki links lose their uuid.
    var wikiLinkMetadata: [WikiLinkService.RangeKey: WikiLinkService.LinkMetadata] = [:]

    // MARK: Parsing

    /// Incremental parse state (buffer + blocks + tokens evolve together).
    let parseState = DocumentParseState()

    /// Monotonic stamp for fresh ParsedDocument builds.
    var parsedDocumentVersion: UInt64 = 0

    /// Monotonic edit counter, bumped whenever the storage can have changed.
    var parseGeneration: UInt64 = 0

    var cachedParsedText: String?
    var cachedParsedDocument: NativeTextViewCoordinator.ParsedDocument?
    var cachedParseGeneration: UInt64 = .max
    var cachedParsedLength: Int = -1

    // MARK: Backtick census

    var previousBacktickCount: Int = 0
    var pendingBacktickWindow: (location: Int, oldLength: Int, oldCount: Int)?
    var backtickCensusNeedsRescan = false

    // MARK: Token activation (syntax reveal)

    var activeTokenIndices: Set<Int> = []
    var previousActiveTokenIndices: Set<Int> = []
    var activeTokenMemo: (version: UInt64, selection: NSRange, suppressed: Bool, result: Set<Int>)?

    // MARK: Code-block geometry cache

    var cachedCodeBlockTokens: [(index: Int, token: MarkdownToken)] = []
    var lastCodeSelKey: (UInt64, CGFloat, CGFloat, Set<Int>)?
}
