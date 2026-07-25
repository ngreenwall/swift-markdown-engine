//
//  WarmDocument.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 25.07.26.
//
//  Keeps a document's laid-out TextKit 2 stack alive across a switch, so coming
//  back is a pointer swap instead of a rebuild.
//
//  The fragment cache lives on the NSTextLayoutManager and `NSTextView
//  .textLayoutManager` is derived from its container, so repointing
//  `container.textView` hands the view an already-laid-out stack. Measured on a
//  7,715-paragraph document: 4.5–14.8 ms against 483 ms to rebuild.
//
//  Two alternatives were measured and rejected: swapping the content manager
//  (`tlm.replace(_:)`) does not keep layout — 378 ms, a full cold rebuild — and
//  pooling whole NSTextViews would multiply undo, spell-checking, first-responder
//  and WritingTools state.
//
//  Affordable here because reading-width mode pins the wrap width, so retained
//  layout does not reflow on resize, and undo is keyed by documentId not by view.
//

import AppKit

/// A complete TextKit 2 stack plus the document state that belongs with it.
///
/// The session must travel with the stack: restoring text without
/// `DocumentSession.lastComputedStorage` — the writeback splice base — would
/// write this document spliced with another's edit, to disk, silently.
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
    /// A second bound, because a count alone ignores that one 346 KB note costs
    /// more than twenty ordinary ones. Characters are only a proxy for the real
    /// cost — retained layout, dominated by rendered elements — but TextKit
    /// offers no cheap way to weigh a laid-out document, so this bounds what can
    /// be measured. A document exceeding it alone is still admitted; refusing it
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
/// One slot is not enough for how people move: it makes A↔B free and A→B→C→A a
/// full rebuild. Measured on the note this was built for: 50 ms warm, 732 ms
/// after one detour. Bounds come from ``WarmDocumentPolicy``.
final class WarmDocumentPool {

    /// Least-recently-used first, so eviction is `removeFirst()`.
    private var documents: [WarmDocument] = []

    /// Set from ``WarmDocumentPolicy``, which the embedder may change at runtime.
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

    /// Remove and return the stack held for `documentId`. Removal is the
    /// contract, not an optimisation: the caller hands this stack back to the
    /// text view, and a pool still holding it could re-issue or evict it live.
    func take(_ documentId: String) -> WarmDocument? {
        guard let index = documents.firstIndex(where: { $0.documentId == documentId }) else { return nil }
        return documents.remove(at: index)
    }

    /// Keep `document` warm, evicting least-recently-used until back inside both
    /// bounds.
    func store(_ document: WarmDocument) {
        // A second stack for the same document is a second answer to one
        // question — drop the older rather than race it.
        documents.removeAll { $0.documentId == document.documentId }
        documents.append(document)

        while documents.count > maxDocuments {
            documents.removeFirst()
        }
        // `count > 1`: never evict the newest for being large on its own — that
        // is exactly the note worth keeping warm.
        while documents.count > 1,
              documents.reduce(0, { $0 + $1.retainedCharacters }) > maxRetainedCharacters {
            documents.removeFirst()
        }
    }

    func removeAll() {
        documents.removeAll()
    }

    /// Drop stacks for documents the embedder no longer needs — a closed window,
    /// a deleted file. Not called by the engine; see NativeTextViewWrapper.
    func prune(keeping retained: Set<String>, current: String?) {
        documents.removeAll { document in
            document.documentId != current && !retained.contains(document.documentId)
        }
    }

    /// Least- to most-recently-used ids, for the switch trace: a miss should say
    /// what was held instead, not only what was wanted.
    var traceSummary: String {
        documents.isEmpty ? "none" : documents.map(\.documentId).joined(separator: ",")
    }
}

extension NativeTextViewCoordinator {

    /// A fresh stack configured exactly like `makeNSView`'s, so a document that
    /// is not warm gets its own instead of reusing the outgoing document's.
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

    /// Capture the stack on `textView` with its session and view geometry.
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
            // Usually a trailing-newline difference or a rename sweep having
            // rewritten the file; the trace distinguishes them.
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

        // Required: repointing the container schedules no viewport pass, so
        // without this the old document's pixels stay on screen.
        warm.layoutManager.textViewportLayoutController.layoutViewport()
        return true
    }
}
