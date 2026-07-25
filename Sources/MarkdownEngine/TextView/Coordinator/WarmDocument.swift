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
//  document — which is why this holds exactly ONE document and is off unless
//  `MD_WARM_SWITCH=1` is set.
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
        self.baseContentHeight = textView.baseContentHeight
        self.activeBottomOverscroll = textView.activeBottomOverscroll
        self.lastFullMeasure = textView.lastFullMeasure
    }

    /// Opt-in while this is experimental. A real embedder-facing switch belongs
    /// in `MarkdownEditorConfiguration` once the memory cost is settled.
    ///
    /// Announces itself once, so a run can never leave you wondering whether the
    /// feature was on — an absent `warmSwap` counter otherwise looks identical
    /// whether the flag is off, the document was never open before, or the swap
    /// silently failed.
#if DEBUG
    private static let resolved: Bool = {
        // Two ways in, because the env var depends on Xcode having re-read the
        // scheme — it caches schemes at project-open, so editing the .xcscheme
        // file under a running Xcode silently has no effect. The user default
        // needs no Xcode at all and survives restarts.
        let env = ProcessInfo.processInfo.environment["MD_WARM_SWITCH"] == "1"
        let pref = UserDefaults.standard.bool(forKey: "MDWarmSwitch")
        let on = env || pref
        print("🔥 PERF warmSwitch \(on ? "ENABLED" : "off")"
              + " (env=\(env ? "1" : "0") default=\(pref ? "1" : "0"))")
        return on
    }()
    static var isEnabled: Bool { resolved }
#else
    static var isEnabled: Bool { false }
#endif
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
