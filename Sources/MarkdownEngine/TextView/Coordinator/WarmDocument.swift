//
//  WarmDocument.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 25.07.26.
//
//  Keeps one document's laid-out TextKit 2 stack alive across a tab switch, so
//  switching back is a pointer swap instead of a rebuild.
//
//  Why this works: the fragment cache lives on the NSTextLayoutManager, and
//  `NSTextView.textLayoutManager` is derived from its text container. Repointing
//  `container.textView` therefore hands the view a different, already-laid-out
//  stack. Measured on a 7,715-paragraph document: 4.5–14.8 ms, against 483 ms to
//  rebuild it. Swapping the *content manager* instead (`tlm.replace(_:)`) does
//  NOT keep layout — that measured 378 ms, a full cold rebuild — and pooling
//  whole NSTextViews would multiply undo, spell-checking, first-responder and
//  WritingTools state, so neither is used here.
//
//  Two things make this affordable in this editor specifically: the reading-width
//  mode pins the wrap width (`widthTracksTextView = false`), so retained layout
//  does not reflow when the window or sidebar resizes; and undo is already keyed
//  by documentId rather than by view.
//
//  The price is memory — roughly 66–95 MB of retained layout for a 346 KB
//  document — which is why `WarmDocumentPool` below holds a handful rather than
//  everything, and why the whole thing is off unless `MD_WARM_SWITCH=1` is set.
//

import AppKit

/// A complete TextKit 2 stack plus the document state that belongs with it.
///
/// The session travels with the stack deliberately. Restoring a document's text
/// without `DocumentSession.lastComputedStorage` — the splice base for the
/// incremental writeback — would make the next keystroke write this document's
/// text spliced with another's edit, to disk, silently. Bundling them makes that
/// mistake unrepresentable rather than merely unlikely.
final class WarmDocument {
    let documentId: String
    let contentStorage: NSTextContentStorage
    let layoutManager: NSTextLayoutManager
    let container: NSTextContainer
    let session: DocumentSession

    /// Storage-form text this stack was built from. The stack is reused ONLY if
    /// this still equals the incoming text: a note rewritten on disk behind the
    /// app's back (a rename sweep, an external editor) must rebuild, not reuse.
    let storageText: String

    /// `storageText`'s length, computed once. The pool's budget reads this on
    /// every store, and `String.count` walks the whole string each time.
    let retainedCharacters: Int

    // Geometry the TEXT VIEW caches, which the stack does not carry. A stale
    // height here is the long→short scroll-jump class of bug, so it travels too.
    let baseContentHeight: CGFloat
    let activeBottomOverscroll: CGFloat
    let lastFullMeasure: (length: Int, width: CGFloat, height: CGFloat)?

    init(
        documentId: String,
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager,
        container: NSTextContainer,
        session: DocumentSession,
        storageText: String,
        textView: NativeTextView
    ) {
        self.documentId = documentId
        self.contentStorage = contentStorage
        self.layoutManager = layoutManager
        self.container = container
        self.session = session
        self.storageText = storageText
        self.retainedCharacters = (storageText as NSString).length
        self.baseContentHeight = textView.baseContentHeight
        self.activeBottomOverscroll = textView.activeBottomOverscroll
        self.lastFullMeasure = textView.lastFullMeasure
    }

}

/// Whether documents keep their laid-out TextKit 2 stack across a switch, and
/// how many may be held.
///
/// Measured on a 346 KB / 7,715-paragraph note: 723 ms to rebuild against 5–15
/// ms to restore, with not one layout fragment re-created. The price is memory —
/// roughly 66–95 MB of retained layout for a document that size — so it is
/// opt-in, and bounded on both count and total retained text. Embedders whose
/// notes are all small gain little and should leave it off.
public struct WarmDocumentPolicy: Sendable {
    public var isEnabled: Bool

    /// Upper bound on documents held.
    ///
    /// An embedder with a tab strip usually wants this to equal the number of
    /// tabs: a tab the user can click is a document they can switch back to, and
    /// a pool smaller than the strip guarantees that some of those clicks pay a
    /// full rebuild. Below that, size it by how far back people actually go.
    public var maxDocuments: Int

    /// Upper bound on total retained TEXT across the pool.
    ///
    /// A second bound is needed because neither measure alone is honest: a count
    /// ignores that one 346 KB note costs more than twenty ordinary ones, while
    /// text length is only a proxy for the real cost — retained layout, which is
    /// dominated by rendered elements rather than by characters. There is no
    /// cheap way to ask TextKit what a laid-out document weighs, so this bounds
    /// the two things that can be measured, conservatively.
    ///
    /// A document that exceeds this on its own is still admitted; refusing it
    /// would leave the slowest case the only one that never benefits.
    public var maxCharacters: Int

    public init(isEnabled: Bool = false, maxDocuments: Int = 3, maxCharacters: Int = 600_000) {
        self.isEnabled = isEnabled
        self.maxDocuments = maxDocuments
        self.maxCharacters = maxCharacters
    }

    public static let disabled = WarmDocumentPolicy()
}

/// A small least-recently-used set of documents kept laid out.
///
/// One slot is not enough for how people actually move: it makes A↔B free and
/// A→B→C→A a full rebuild, because the third document evicts the first.
/// Measured on the note this was built for — 50 ms warm, 732 ms after one
/// detour.
///
/// Bounded on BOTH count and total retained text, because neither alone is
/// honest. Count ignores that one 346 KB note costs more than twenty ordinary
/// ones; text length is only a proxy for the real cost, which is retained
/// layout and is dominated by rendered elements (images, tables) rather than by
/// characters. There is no cheap way to ask TextKit what a laid-out document
/// weighs, so this bounds the two things it CAN measure and stays conservative:
/// three documents, and roughly two large notes' worth of text between them.
final class WarmDocumentPool {

    /// Least-recently-used first, so eviction is `removeFirst()`.
    private var documents: [WarmDocument] = []

    /// Bounds, not constants: the embedder sets them through
    /// ``WarmDocumentPolicy`` and may change them at runtime (a tab-strip size
    /// is a user-visible setting in some apps). Applied on the next `store`.
    var maxDocuments: Int
    var maxRetainedCharacters: Int

    init(maxDocuments: Int = 3, maxRetainedCharacters: Int = 600_000) {
        self.maxDocuments = maxDocuments
        self.maxRetainedCharacters = maxRetainedCharacters
    }

    /// Adopt the embedder's bounds, trimming immediately if they shrank.
    func apply(_ policy: WarmDocumentPolicy) {
        guard maxDocuments != policy.maxDocuments || maxRetainedCharacters != policy.maxCharacters else { return }
        maxDocuments = max(1, policy.maxDocuments)
        maxRetainedCharacters = max(1, policy.maxCharacters)
        while documents.count > maxDocuments { documents.removeFirst() }
        while documents.count > 1,
              documents.reduce(0, { $0 + $1.retainedCharacters }) > maxRetainedCharacters {
            documents.removeFirst()
        }
    }

    /// Remove and return the stack held for `documentId`, if any.
    ///
    /// Removal is not an optimisation, it is the contract: the caller is about
    /// to hand this stack back to the text view, and a pool still holding it
    /// would be free to hand the same one out again or evict it while live.
    func take(_ documentId: String) -> WarmDocument? {
        guard let index = documents.firstIndex(where: { $0.documentId == documentId }) else { return nil }
        return documents.remove(at: index)
    }

    /// Keep `document` warm, evicting the least recently used until the pool is
    /// back inside both bounds.
    func store(_ document: WarmDocument) {
        // A second stack for the same document would be a second answer to the
        // same question — drop the older one rather than race it.
        documents.removeAll { $0.documentId == document.documentId }
        documents.append(document)

        while documents.count > maxDocuments {
            documents.removeFirst()
        }
        // `count > 1` so the newest document is never evicted for being large on
        // its own. A note that exceeds the budget by itself is exactly the note
        // worth keeping warm; refusing it would leave the slowest case slow.
        while documents.count > 1,
              documents.reduce(0, { $0 + $1.retainedCharacters }) > maxRetainedCharacters {
            documents.removeFirst()
        }
    }

    func removeAll() {
        documents.removeAll()
    }

    /// Drop stacks for documents the embedder no longer retains.
    ///
    /// Without this the pool is a leak with a very large constant: a document
    /// closed in the app keeps tens of megabytes of laid-out fragments alive
    /// until two other documents happen to push it out. The embedder already
    /// tells the editor which documents matter, via `retainedScrollDocumentIds`.
    func prune(keeping retained: Set<String>, current: String?) {
        documents.removeAll { document in
            document.documentId != current && !retained.contains(document.documentId)
        }
    }

    /// Least- to most-recently-used ids, for the switch trace. Without it a miss
    /// only says what was wanted, not what was held instead — which is the half
    /// that explains WHY it missed.
    var traceSummary: String {
        documents.isEmpty ? "none" : documents.map(\.documentId).joined(separator: ",")
    }
}

extension NativeTextViewCoordinator {

    /// Build a fresh, empty TextKit 2 stack configured exactly like the one
    /// `makeNSView` sets up, so a document that is not warm gets an equivalent
    /// home instead of reusing the outgoing document's.
    func makeTextKitStack() -> (NSTextContentStorage, NSTextLayoutManager, NSTextContainer) {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        contentStorage.addTextLayoutManager(layoutManager)
        layoutManager.textContainer = container
        layoutManager.delegate = layoutDelegate
        container.lineFragmentPadding = 0
        container.heightTracksTextView = false
        if let readingWidth = configuration.readingWidth {
            container.widthTracksTextView = false
            container.size = NSSize(width: readingWidth, height: CGFloat.greatestFiniteMagnitude)
        } else {
            container.widthTracksTextView = true
        }
        return (contentStorage, layoutManager, container)
    }

    /// Capture the stack currently on `textView`, together with this document's
    /// session and the view-cached geometry, so a later switch back can restore it.
    func captureWarmDocument(_ textView: NativeTextView, documentId: String, storageText: String) -> WarmDocument? {
        guard let contentStorage = textView.textContentStorage,
              let layoutManager = textView.textLayoutManager,
              let container = textView.textContainer else { return nil }
        return WarmDocument(
            documentId: documentId,
            contentStorage: contentStorage,
            layoutManager: layoutManager,
            container: container,
            session: session,
            storageText: storageText,
            textView: textView
        )
    }

    /// Point the text view at a warm stack and restore everything that belongs
    /// with it. Returns false if the stack no longer matches the text.
    func restoreWarmDocument(_ warm: WarmDocument, into textView: NativeTextView, expecting text: String) -> Bool {
        guard warm.storageText == text else {
            // The commonest real cause is that the app hands `text` in a form that
            // differs from the stored `lastSyncedText` — a trailing newline, or a
            // rename sweep having rewritten the file meanwhile. Print enough to
            // tell those apart without another round trip.
            let stored = warm.storageText
            let common = zip(stored, text).prefix { $0 == $1 }.count
            PerfTrace.stamp("warmSwap.rejected", 0,
                            "id=\(warm.documentId) storedLen=\(stored.count) incomingLen=\(text.count) commonPrefix=\(common)")
            return false
        }

        warm.container.textView = textView
        session = warm.session
        textView.baseContentHeight = warm.baseContentHeight
        textView.activeBottomOverscroll = warm.activeBottomOverscroll
        textView.lastFullMeasure = warm.lastFullMeasure

        // Required. Repointing the container does NOT schedule a viewport pass:
        // without this the old document's pixels stay on screen and `viewportRange`
        // reads nil, which looks exactly like the swap silently failing.
        warm.layoutManager.textViewportLayoutController.layoutViewport()
        return true
    }
}
