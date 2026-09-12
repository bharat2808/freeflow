import AVFoundation
import AVKit
import AppKit
import MarkdownUI
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
                } else if !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Markdown(block, baseURL: store.noteFolderURL(for: note))
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
        return nil
    }
}

private enum NoteAttachmentReference {
    case image(String, URL)
    case video(String, URL)
    case audio(String, URL)
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
        }
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
