//
//  WarmDocumentPoolTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 25.07.26.
//
//  The pool decides which documents stay laid out across a switch. Getting it
//  wrong is invisible in the UI — a wrongly evicted document just rebuilds, and
//  a wrongly RETAINED one just costs memory — so the eviction rules are pinned
//  here rather than left to be noticed in a trace months later.
//
//  The case that motivated the pool is `detourStillFindsTheFirstDocument`:
//  a single slot made A↔B free and A→B→C→A a full rebuild.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
struct WarmDocumentPoolTests {

    /// A pool entry of a given id and text length. The stack itself is never
    /// exercised here — only the bookkeeping around it is under test.
    private func makeDocument(id: String, characters: Int) -> WarmDocument {
        let coordinator = NativeTextViewCoordinator(
            text: .constant(""), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        let (contentStorage, layoutManager, container) = coordinator.makeTextKitStack()
        return WarmDocument(
            documentId: id,
            contentStorage: contentStorage,
            layoutManager: layoutManager,
            container: container,
            session: DocumentSession(),
            storageText: String(repeating: "x", count: characters),
            textView: NativeTextView(frame: .zero)
        )
    }

    @Test("Taking a document removes it, so the same stack is never handed out twice")
    func takeRemoves() {
        let pool = WarmDocumentPool()
        pool.store(makeDocument(id: "a", characters: 10))

        #expect(pool.take("a") != nil)
        #expect(pool.take("a") == nil)
    }

    @Test("A detour through other documents still finds the first one")
    func detourStillFindsTheFirstDocument() {
        // The reported case: PerfTest → note B → note C → back to PerfTest. With
        // a single slot the last hop missed and cost a full rebuild.
        let pool = WarmDocumentPool()
        pool.store(makeDocument(id: "big", characters: 346_000))
        pool.store(makeDocument(id: "b", characters: 5_000))
        pool.store(makeDocument(id: "c", characters: 1_400))

        #expect(pool.take("big") != nil)
    }

    @Test("The count bound evicts the least recently used")
    func countBoundEvictsOldest() {
        let pool = WarmDocumentPool(maxDocuments: 2, maxRetainedCharacters: 1_000_000)
        pool.store(makeDocument(id: "a", characters: 10))
        pool.store(makeDocument(id: "b", characters: 10))
        pool.store(makeDocument(id: "c", characters: 10))

        #expect(pool.take("a") == nil) // evicted
        #expect(pool.take("b") != nil)
        #expect(pool.take("c") != nil)
    }

    @Test("The character bound evicts even when the count is fine")
    func characterBoundEvictsOldest() {
        let pool = WarmDocumentPool(maxDocuments: 10, maxRetainedCharacters: 1_000)
        pool.store(makeDocument(id: "a", characters: 600))
        pool.store(makeDocument(id: "b", characters: 600))

        #expect(pool.take("a") == nil) // 1,200 > 1,000 → oldest goes
        #expect(pool.take("b") != nil)
    }

    @Test("A document larger than the whole budget is still kept")
    func oversizedDocumentSurvivesAlone() {
        // Refusing it would leave the slowest case — the one large note — the
        // only one that never benefits.
        let pool = WarmDocumentPool(maxDocuments: 3, maxRetainedCharacters: 1_000)
        pool.store(makeDocument(id: "huge", characters: 500_000))

        #expect(pool.take("huge") != nil)
    }

    @Test("Re-storing a document replaces its earlier stack rather than duplicating it")
    func reStoringReplaces() {
        let pool = WarmDocumentPool(maxDocuments: 3, maxRetainedCharacters: 1_000_000)
        pool.store(makeDocument(id: "a", characters: 10))
        pool.store(makeDocument(id: "b", characters: 10))
        pool.store(makeDocument(id: "a", characters: 20)) // same id, newer stack

        #expect(pool.take("a") != nil)
        #expect(pool.take("a") == nil) // only one entry existed
        #expect(pool.take("b") != nil) // and "b" was not pushed out by the duplicate
    }

    @Test("Adopting a smaller policy trims immediately, not one switch later")
    func applyShrinksNow() {
        let pool = WarmDocumentPool(maxDocuments: 5, maxRetainedCharacters: 1_000_000)
        for id in ["a", "b", "c", "d", "e"] {
            pool.store(makeDocument(id: id, characters: 100))
        }

        pool.apply(WarmDocumentPolicy(isEnabled: true, maxDocuments: 2, maxCharacters: 1_000_000))

        #expect(pool.take("a") == nil)
        #expect(pool.take("b") == nil)
        #expect(pool.take("c") == nil)
        #expect(pool.take("d") != nil) // the two most recent survive
        #expect(pool.take("e") != nil)
    }

    @Test("A larger policy takes effect without discarding what is held")
    func applyGrowsWithoutLoss() {
        let pool = WarmDocumentPool(maxDocuments: 2, maxRetainedCharacters: 1_000_000)
        pool.store(makeDocument(id: "a", characters: 100))
        pool.store(makeDocument(id: "b", characters: 100))

        pool.apply(WarmDocumentPolicy(isEnabled: true, maxDocuments: 6, maxCharacters: 1_000_000))
        pool.store(makeDocument(id: "c", characters: 100))

        #expect(pool.take("a") != nil)
        #expect(pool.take("b") != nil)
        #expect(pool.take("c") != nil)
    }

    @Test("Pruning drops documents the embedder no longer retains")
    func pruneDropsUnretained() {
        // Without this the pool is a leak with a very large constant: a closed
        // document keeps tens of megabytes of laid-out fragments alive until two
        // other documents happen to push it out.
        let pool = WarmDocumentPool()
        pool.store(makeDocument(id: "closed", characters: 346_000))
        pool.store(makeDocument(id: "open", characters: 5_000))

        pool.prune(keeping: ["open"], current: nil)

        #expect(pool.take("closed") == nil)
        #expect(pool.take("open") != nil)
    }

    @Test("Pruning never drops the current document")
    func pruneKeepsCurrent() {
        // The embedder's retained set does not necessarily include the document
        // being displayed right now; evicting that one would rebuild the very
        // stack in use.
        let pool = WarmDocumentPool()
        pool.store(makeDocument(id: "current", characters: 1_000))

        pool.prune(keeping: [], current: "current")

        #expect(pool.take("current") != nil)
    }

    @Test("Re-storing counts as use, so the refreshed document is not the next evicted")
    func reStoringRefreshesRecency() {
        let pool = WarmDocumentPool(maxDocuments: 2, maxRetainedCharacters: 1_000_000)
        pool.store(makeDocument(id: "a", characters: 10))
        pool.store(makeDocument(id: "b", characters: 10))
        pool.store(makeDocument(id: "a", characters: 10)) // "a" used again
        pool.store(makeDocument(id: "c", characters: 10))

        #expect(pool.take("b") == nil) // "b" is now the least recently used
        #expect(pool.take("a") != nil)
        #expect(pool.take("c") != nil)
    }
}
