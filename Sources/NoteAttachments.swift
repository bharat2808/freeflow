import AVFoundation
import AVKit
import AppKit
import MarkdownUI
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

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
                    Markdown(block, baseURL: store.noteFolderURL(for: note))
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
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(maxWidth: 720, minHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        case let .audio(label, url):
            AudioAttachmentView(label: label, url: url)
        case let .text(label, url):
            TextAttachmentView(label: label, url: url)
        case let .pdf(label, url):
            PDFKitView(url: url)
                .frame(maxWidth: 720, minHeight: 420)
                .overlay(alignment: .topLeading) {
                    Text(label)
                        .font(.caption)
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .padding(8)
                }
        case let .file(label, url):
            GenericAttachmentView(label: label, url: url)
        }
    }
}

private struct TextAttachmentView: View {
    let label: String
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: "doc.text")
                .font(.headline)
            if let contents = try? String(contentsOf: url, encoding: .utf8) {
                ScrollView(.horizontal) {
                    Text(contents)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 300)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("This text file could not be decoded as UTF-8.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PDFKitView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {}
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
