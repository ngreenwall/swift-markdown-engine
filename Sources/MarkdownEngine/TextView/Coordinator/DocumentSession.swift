//
//  DocumentSession.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 25.07.26.
//
//  Everything the coordinator knows that belongs to the DOCUMENT rather than the
//  text view. One NSTextView serves every tab, so this used to live on the
//  coordinator — fine while a switch discarded the old document, fatal once two
//  are alive: `lastComputedStorage` is the writeback splice base, and restoring
//  text without it writes A's content spliced with B's edit to disk.
//
//  One object rather than save/restore of individual fields, so a swap is a
//  single assignment and a new field cannot be forgotten. The coordinator keeps
//  forwarding properties, so call sites are unchanged.
//
//  NOT here: view- or session-scoped state (WritingTools, spell-checking, drag
//  flags, first responder, find) — it stays correct by NOT travelling.
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
