import AppKit
import PDFKit
import SwiftUI

struct NotePDFPreviewSheet: View {
    let note: MarkdownNote
    let document: PDFDocument
    let attachmentPresentation: NoteAttachmentPresentation
    let textScale: Double
    let textSpacing: Double
    let onAttachmentPresentationChange: (NoteAttachmentPresentation) -> Void
    let onTextScaleChange: (Double) -> Void
    let onTextSpacingChange: (Double) -> Void
    let onSave: () -> Void
    let onShare: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PDF Preview")
                        .font(.title2.weight(.semibold))
                    Text(note.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Menu {
                    ForEach(NoteAttachmentPresentation.allCases, id: \.rawValue) { presentation in
                        Button {
                            onAttachmentPresentationChange(presentation)
                        } label: {
                            HStack {
                                Text(presentation.title)
                                if presentation == attachmentPresentation {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label(
                        "Attachments: \(attachmentPresentation.title)",
                        systemImage: "paperclip"
                    )
                }
                .menuStyle(.borderlessButton)
                HStack(spacing: 6) {
                    Image(systemName: "textformat.size")
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { textScale },
                            set: onTextScaleChange
                        ),
                        in: 0.7...1.4,
                        step: 0.05
                    )
                    .frame(width: 120)
                    Text("\(Int(textScale * 100))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 38, alignment: .trailing)
                }
                .help("Scale normal Markdown text in the PDF")
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.and.down.text.horizontal")
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { textSpacing },
                            set: onTextSpacingChange
                        ),
                        in: 0.5...2.0,
                        step: 0.05
                    )
                    .frame(width: 100)
                    Text("\(Int(textSpacing * 100))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 38, alignment: .trailing)
                }
                .help("Adjust spacing between paragraphs and lines")
                Button("Cancel", action: onCancel)
                Button("Save as PDF…", action: onSave)
                    .buttonStyle(.bordered)
                Button("Share…", action: onShare)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
            Divider()
            PDFPreviewDocumentView(document: document)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
        }
        .frame(minWidth: 900, minHeight: 720)
    }
}

private struct PDFPreviewDocumentView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .underPageBackgroundColor
        view.document = document
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document !== document {
            nsView.document = document
        }
        nsView.autoScales = true
    }
}
