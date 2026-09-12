import AVFoundation
import AVKit
import AppKit
import MarkdownUI
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct NoteMarkdownPreview: View {
    let markdown: String
    let note: MarkdownNote
    private let store = MarkdownNoteStore.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(markdown.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, block in
                if let attachment = attachment(in: block) {
                    NoteAttachmentView(attachment: attachment)
                } else if let webLink = webLink(in: block) {
                    ExternalLinkView(label: webLink.label, url: webLink.url)
                } else if !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Markdown(markdownWithLinkAffordances(block), baseURL: store.noteFolderURL(for: note))
                        .environment(\.openURL, OpenURLAction { url in
                            NSWorkspace.shared.open(url)
                            return .handled
                        })
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func attachment(in block: String) -> NoteAttachmentReference? {
        let value = block.trimmingCharacters(in: .whitespacesAndNewlines)
        let isImage = value.hasPrefix("![")
        let open = value.firstIndex(of: "(")
        guard (isImage || value.hasPrefix("[")), let open,
              value.last == ")",
              let close = value[..<open].lastIndex(of: "]") else { return nil }
        let pathStart = value.index(after: open)
        let path = String(value[pathStart..<value.index(before: value.endIndex)])
        guard let url = store.attachmentURL(for: note, relativePath: path),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        let labelStart = value.index(value.startIndex, offsetBy: isImage ? 2 : 1)
        let label = String(value[labelStart..<close])
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true { return .image(label, url) }
        if type?.conforms(to: .movie) == true { return .video(label, url) }
        if type?.conforms(to: .audio) == true { return .audio(label, url) }
        if type?.conforms(to: .pdf) == true { return .pdf(label, url) }
        if type?.conforms(to: .text) == true { return .text(label, url) }
        return .file(label, url)
    }

    private func webLink(in block: String) -> (label: String, url: URL)? {
        let value = block.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("["), value.last == ")",
              let close = value.firstIndex(of: "]"),
              value.index(after: close) < value.endIndex,
              value[value.index(after: close)] == "(",
              let urlEnd = value.lastIndex(of: ")") else { return nil }
        let label = String(value[value.index(after: value.startIndex)..<close])
        let urlStart = value.index(close, offsetBy: 2)
        guard urlStart < urlEnd,
              let url = URL(string: String(value[urlStart..<urlEnd])),
              url.scheme == "http" || url.scheme == "https" else { return nil }
        return (label, url)
    }

    private func markdownWithLinkAffordances(_ source: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return source
        }
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = detector.matches(in: source, options: [], range: fullRange)
        var result = source
        for match in matches.reversed() {
            guard let url = match.url else { continue }
            let range = match.range
            let prefixStart = max(0, range.location - 2)
            let prefix = (result as NSString).substring(with: NSRange(location: prefixStart, length: range.location - prefixStart))
            // Markdown links are already handled by the standalone link view or
            // retain their original label; only decorate bare URLs here.
            guard prefix != "](" else { continue }
            let visibleURL = (result as NSString).substring(with: range)
            let replacement = "[\(visibleURL) ↗](\(url.absoluteString))"
            result = (result as NSString).replacingCharacters(in: range, with: replacement)
        }
        return result
    }
}

private struct ExternalLinkView: View {
    let label: String
    let url: URL
    @State private var isHovered = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 6) {
                Text(label)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .opacity(isHovered ? 1 : 0.7)
                    .offset(x: isHovered ? 2 : 0)
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onDisappear {
            if isHovered { NSCursor.pop() }
        }
        .help("Open in browser")
    }
}

private enum NoteAttachmentReference {
    case image(String, URL)
    case video(String, URL)
    case audio(String, URL)
    case text(String, URL)
    case pdf(String, URL)
    case file(String, URL)
}

private struct NoteAttachmentView: View {
    let attachment: NoteAttachmentReference

    var body: some View {
        switch attachment {
        case let .image(label, url):
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 720, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(label)
            }
        case let .video(label, url):
            VStack(alignment: .leading, spacing: 6) {
                NativeVideoView(url: url)
                    .frame(maxWidth: 720, minHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        case let .audio(label, url):
            AudioAttachmentView(label: label, url: url)
        case let .text(label, url):
            TextAttachmentView(label: label, url: url)
        case let .pdf(label, url):
            FocusablePDFAttachmentView(label: label, url: url)
        case let .file(label, url):
            GenericAttachmentView(label: label, url: url)
        }
    }
}

private struct NativeVideoView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player?.currentItem?.asset as? AVURLAsset == nil ||
            (nsView.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            nsView.player?.pause()
            nsView.player = AVPlayer(url: url)
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}

private struct TextAttachmentView: View {
    let label: String
    let url: URL
    @State private var isFocused = false

    var body: some View {
        if ["html", "htm"].contains(url.pathExtension.lowercased()) {
            HTMLAttachmentView(label: label, url: url)
        } else {
            textSourceView
        }
    }

    private var textSourceView: some View {
        VStack(alignment: .leading, spacing: 6) {
            AttachmentHeader(label: label, icon: "doc.text", url: url)
            if let contents = try? String(contentsOf: url, encoding: .utf8) {
                FocusToggleTextScrollView(contents: contents, isFocused: $isFocused)
                .frame(maxWidth: .infinity, minHeight: 420, maxHeight: 800)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 1)
                }
            } else {
                Text("This text file could not be decoded as UTF-8.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct FocusToggleTextScrollView: NSViewRepresentable {
    let contents: String
    @Binding var isFocused: Bool

    func makeNSView(context: Context) -> FocusGatedScrollView {
        let scrollView = FocusGatedScrollView()
        let textView = FocusToggleTextView()

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.isDocumentFocused = isFocused

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.string = contents
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.focusScrollView = scrollView
        textView.onToggleFocus = {
            isFocused.toggle()
            return isFocused
        }

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: FocusGatedScrollView, context: Context) {
        nsView.isDocumentFocused = isFocused
        guard let textView = nsView.documentView as? FocusToggleTextView else { return }
        if textView.string != contents {
            textView.string = contents
        }
    }
}

private final class FocusGatedScrollView: NSScrollView {
    var isDocumentFocused = false

    override func layout() {
        super.layout()
        guard let textView = documentView as? NSTextView else { return }
        var frame = textView.frame
        frame.size.width = max(frame.width, contentSize.width)
        frame.size.height = max(frame.height, contentSize.height)
        textView.frame = frame
    }

    override func scrollWheel(with event: NSEvent) {
        guard isDocumentFocused else { return }
        super.scrollWheel(with: event)
    }
}

private final class FocusToggleTextView: NSTextView {
    weak var focusScrollView: FocusGatedScrollView?
    var onToggleFocus: (() -> Bool)?

    override func mouseDown(with event: NSEvent) {
        if let focused = onToggleFocus?() {
            focusScrollView?.isDocumentFocused = focused
        }
        super.mouseDown(with: event)
    }
}

private struct HTMLAttachmentView: View {
    let label: String
    let url: URL
    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AttachmentHeader(label: label, icon: "globe", url: url)
            HTMLWebView(url: url, isFocused: $isFocused)
                .frame(maxWidth: .infinity, minHeight: 520, maxHeight: 900)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isFocused ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
                }
        }
    }
}

private struct HTMLWebView: NSViewRepresentable {
    let url: URL
    @Binding var isFocused: Bool

    func makeNSView(context: Context) -> FocusToggleWebView {
        let webView = FocusToggleWebView(frame: .zero)
        webView.onToggleFocus = { isFocused.toggle() }
        webView.isDocumentFocused = isFocused
        webView.allowsMagnification = true
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return webView
    }

    func updateNSView(_ nsView: FocusToggleWebView, context: Context) {
        nsView.isDocumentFocused = isFocused
        guard nsView.url?.standardizedFileURL != url.standardizedFileURL else { return }
        nsView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
}

private final class FocusToggleWebView: WKWebView {
    var isDocumentFocused = false
    var onToggleFocus: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onToggleFocus?()
        isDocumentFocused.toggle()
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard isDocumentFocused else { return }
        super.scrollWheel(with: event)
    }
}

private struct AttachmentHeader: View {
    let label: String
    let icon: String
    let url: URL

    var body: some View {
        HStack(spacing: 8) {
            Label(label, systemImage: icon)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("Open externally", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help("Open in the default app")
        }
    }
}

private struct FocusablePDFAttachmentView: View {
    let label: String
    let url: URL
    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AttachmentHeader(label: label, icon: "doc.richtext", url: url)
            PDFKitView(url: url, isFocused: $isFocused)
                .frame(maxWidth: .infinity, minHeight: 420, maxHeight: 800)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isFocused ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
                }
        }
    }
}

private struct PDFKitView: NSViewRepresentable {
    let url: URL
    @Binding var isFocused: Bool

    func makeNSView(context: Context) -> FocusTogglePDFView {
        let view = FocusTogglePDFView()
        view.onToggleFocus = { isFocused.toggle() }
        view.isDocumentFocused = isFocused
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ nsView: FocusTogglePDFView, context: Context) {
        nsView.isDocumentFocused = isFocused
    }
}

private final class FocusTogglePDFView: PDFView {
    var isDocumentFocused = false
    var onToggleFocus: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onToggleFocus?()
        isDocumentFocused.toggle()
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard isDocumentFocused else { return }
        super.scrollWheel(with: event)
    }
}

private struct GenericAttachmentView: View {
    let label: String
    let url: URL

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.badge.arrow.up")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).lineLimit(1)
                Text(fileDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open") { NSWorkspace.shared.open(url) }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 520)
    }

    private var fileDescription: String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let bytes = values?.fileSize {
            return "\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) · Opens in the default app"
        }
        return "Opens in the default app"
    }
}

private struct AudioAttachmentView: View {
    let label: String
    let url: URL
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if isPlaying {
                    player?.pause()
                    isPlaying = false
                } else {
                    if player == nil { player = try? AVAudioPlayer(contentsOf: url) }
                    player?.play()
                    isPlaying = true
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderedProminent)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).lineLimit(1)
                Text("Voice note").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 420)
        .onDisappear { player?.stop() }
    }
}
