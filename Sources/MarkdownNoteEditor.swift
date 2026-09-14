import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum NoteAttachmentKind {
    case image
    case video
    case audio
    case text
    case pdf
    case file
}

struct NoteAttachmentPayload {
    let sourceURL: URL?
    let imageData: Data?
    let fileName: String
    let kind: NoteAttachmentKind
}

struct MarkdownNoteEditor: NSViewRepresentable {
    let text: Binding<String>
    let selectedRange: Binding<NSRange>
    let importAttachment: (NoteAttachmentPayload) -> String?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: text, selectedRange: selectedRange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = AttachmentTextView()
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.registerForDraggedTypes([.fileURL, .tiff, .png])
        textView.onAttachment = { payload, textView in
            guard let insertion = importAttachment(payload) else { return false }
            textView.insertText(insertion, replacementRange: textView.selectedRange())
            return true
        }
        textView.string = text.wrappedValue
        textView.setSelectedRange(clampedSelection(selectedRange.wrappedValue, for: textView.string))

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? AttachmentTextView else { return }
        if textView.string != text.wrappedValue {
            textView.string = text.wrappedValue
        }
        let targetSelection = clampedSelection(selectedRange.wrappedValue, for: textView.string)
        if textView.selectedRange() != targetSelection {
            textView.setSelectedRange(targetSelection)
        }
    }

    private func clampedSelection(_ range: NSRange, for string: String) -> NSRange {
        let length = (string as NSString).length
        let location = min(max(range.location, 0), length)
        let selectionLength = min(max(range.length, 0), length - location)
        return NSRange(location: location, length: selectionLength)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>
        let selectedRange: Binding<NSRange>

        init(text: Binding<String>, selectedRange: Binding<NSRange>) {
            self.text = text
            self.selectedRange = selectedRange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            selectedRange.wrappedValue = textView.selectedRange()
        }
    }
}

final class AttachmentTextView: NSTextView {
    var onAttachment: ((NoteAttachmentPayload, NSTextView) -> Bool)?

    override func paste(_ sender: Any?) {
        if handleAttachment(in: NSPasteboard.general) { return }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if handleAttachment(in: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    private func handleAttachment(in pasteboard: NSPasteboard) -> Bool {
        guard let payload = Self.payload(from: pasteboard),
              onAttachment?(payload, self) == true else { return false }
        return true
    }

    private static func payload(from pasteboard: NSPasteboard) -> NoteAttachmentPayload? {
        if let nsURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL], let url = nsURLs.first as URL? {
            let type = UTType(filenameExtension: url.pathExtension)
            let kind: NoteAttachmentKind?
            if type?.conforms(to: .image) == true { kind = .image }
            else if type?.conforms(to: .movie) == true { kind = .video }
            else if type?.conforms(to: .audio) == true { kind = .audio }
            else if type?.conforms(to: .pdf) == true { kind = .pdf }
            else if type?.conforms(to: .text) == true { kind = .text }
            else { kind = .file }
            if let kind {
                return NoteAttachmentPayload(sourceURL: url, imageData: nil, fileName: url.lastPathComponent, kind: kind)
            }
        }

        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return NoteAttachmentPayload(sourceURL: nil, imageData: png, fileName: "pasted-image.png", kind: .image)
    }
}
