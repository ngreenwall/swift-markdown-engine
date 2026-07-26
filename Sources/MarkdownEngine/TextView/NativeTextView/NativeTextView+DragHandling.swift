//
//  NativeTextView+DragHandling.swift
//  MarkdownEngine
//
//  Drag-and-drop image support, mirroring NativeTextView+PasteHandling's
//  onPasteImage-based flow: a dropped image goes through the same embedder
//  hook a pasted one does, so both window types and the sandbox-access
//  gating an embedder wraps around it apply identically to drops.
//

import AppKit

extension NativeTextView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEditable, PasteboardImageReader.canPasteImage(from: sender.draggingPasteboard) else {
            return super.draggingEntered(sender)
        }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEditable, PasteboardImageReader.canPasteImage(from: sender.draggingPasteboard) else {
            return super.draggingUpdated(sender)
        }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isEditable, let embed = onPasteImage?(sender.draggingPasteboard), !embed.isEmpty else {
            return super.performDragOperation(sender)
        }
        // Insert at the actual drop point rather than wherever the caret
        // last was, matching native drag-and-drop expectations.
        let dropIndex = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        setSelectedRange(NSRange(location: dropIndex, length: 0))
        insertBlockEmbed(embed)
        return true
    }
}
