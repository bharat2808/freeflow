import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

enum NoteAttachmentPresentation: String, CaseIterable {
    case expanded
    case collapsed
    case excluded

    var title: String {
        switch self {
        case .expanded: return "Expanded"
        case .collapsed: return "Collapsed"
        case .excluded: return "Excluded"
        }
    }
}

enum NoteExportError: LocalizedError {
    case couldNotCreatePDF

    var errorDescription: String? {
        "Could not create a PDF for this note."
    }
}

enum NoteExportService {
    private struct ExportPage {
        let page: PDFPage
        let fitToContent: Bool
    }

    static func pdfData(
        for note: MarkdownNote,
        attachmentPresentation: NoteAttachmentPresentation,
        textScale: CGFloat = 1,
        textSpacing: CGFloat = 1,
        store: MarkdownNoteStore = .standard
    ) throws -> Data {
        let assetDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("freeflow-note-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: assetDirectory) }
        let html = html(
            for: note,
            attachmentPresentation: attachmentPresentation,
            store: store,
            assetDirectory: assetDirectory,
            textScale: textScale,
            textSpacing: textSpacing
        )
        let attributed: NSAttributedString
        do {
            attributed = try NSAttributedString(
            data: Data(html.utf8),
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
                .baseURL: assetDirectory
            ],
            documentAttributes: nil
            )
        } catch {
            throw NoteExportError.couldNotCreatePDF
        }

        let renderedAttributed = NSMutableAttributedString(attributedString: attributed)
        applyTextSpacing(to: renderedAttributed, factor: textSpacing)
        replaceAssetTokens(in: renderedAttributed, assetDirectory: assetDirectory)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 100_000))
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 48, height: 48)
        textView.textStorage?.setAttributedString(renderedAttributed)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let usedHeight = max(
            96,
            (textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0) + 96
        )
        textView.frame.size.height = usedHeight

        let pageSize = NSSize(width: 612, height: 792) // US Letter at 72 points per inch.
        let pageChromeHeight: CGFloat = 80
        let contentPageHeight = pageSize.height - pageChromeHeight
        let pageCount = max(1, Int(ceil(usedHeight / contentPageHeight)))
        var pages: [ExportPage] = []
        for pageIndex in 0..<pageCount {
            let pageRect = NSRect(
                x: 0,
                y: CGFloat(pageIndex) * contentPageHeight,
                width: pageSize.width,
                height: contentPageHeight
            )
            let pageData = textView.dataWithPDF(inside: pageRect)
            guard let pageDocument = PDFDocument(data: pageData),
                  let page = pageDocument.page(at: 0) else {
                throw NoteExportError.couldNotCreatePDF
            }
            pages.append(ExportPage(page: page, fitToContent: false))
        }
        if attachmentPresentation == .expanded {
            pages.append(contentsOf: expandedPDFPages(
                for: note.markdown,
                note: note,
                baseURL: store.noteFolderURL(for: note),
                store: store
            ))
        }
        return try makePDFWithPageChrome(
            pages: pages,
            note: note,
            pageSize: pageSize,
            contentPageHeight: contentPageHeight
        )
    }

    private static func applyTextSpacing(
        to attributed: NSMutableAttributedString,
        factor: CGFloat
    ) {
        guard attributed.length > 0 else { return }

        let normalizedFactor = min(max(factor, 0.5), 2.0)
        var location = 0
        while location < attributed.length {
            let paragraphRange = (attributed.string as NSString).paragraphRange(
                for: NSRange(location: location, length: 0)
            )
            let currentStyle = attributed.attribute(
                .paragraphStyle,
                at: location,
                effectiveRange: nil
            ) as? NSParagraphStyle
            let style = (currentStyle?.mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            style.lineSpacing = 3 * normalizedFactor
            style.paragraphSpacing = 8 * normalizedFactor
            attributed.addAttribute(
                .paragraphStyle,
                value: style,
                range: paragraphRange
            )
            location = NSMaxRange(paragraphRange)
        }
    }

    private static func makePDFWithPageChrome(
        pages: [ExportPage],
        note: MarkdownNote,
        pageSize: NSSize,
        contentPageHeight: CGFloat
    ) throws -> Data {
        let mutableData = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: mutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NoteExportError.couldNotCreatePDF
        }

        let totalPages = pages.count
        for (index, page) in pages.enumerated() {
            context.beginPDFPage([kCGPDFContextMediaBox as String: mediaBox] as CFDictionary)
            if let pageRef = page.page.pageRef {
                context.saveGState()
                if page.fitToContent {
                    let sourceBounds = page.page.bounds(for: .mediaBox).standardized
                    let contentRect = CGRect(x: 48, y: 40, width: pageSize.width - 96, height: contentPageHeight)
                    let scale = min(contentRect.width / sourceBounds.width, contentRect.height / sourceBounds.height)
                    let drawWidth = sourceBounds.width * scale
                    let drawHeight = sourceBounds.height * scale
                    context.translateBy(
                        x: contentRect.minX + (contentRect.width - drawWidth) / 2,
                        y: contentRect.minY + (contentRect.height - drawHeight) / 2
                    )
                    context.scaleBy(x: scale, y: scale)
                    context.translateBy(x: -sourceBounds.minX, y: -sourceBounds.minY)
                    context.drawPDFPage(pageRef)
                } else {
                    context.translateBy(x: 0, y: 40)
                    context.drawPDFPage(pageRef)
                }
                context.restoreGState()
            }

            let header = "FreeFlow Notes  •  \(note.title)"
            let footer = "\(note.modified.formatted(date: .abbreviated, time: .shortened))  •  Page \(index + 1) of \(totalPages)"
            drawPDFText(header, at: CGPoint(x: 48, y: pageSize.height - 24), in: context, fontSize: 8, color: .secondaryLabelColor)
            drawPDFText(footer, at: CGPoint(x: 48, y: 14), in: context, fontSize: 8, color: .secondaryLabelColor)
            context.endPDFPage()
        }
        context.closePDF()
        return mutableData as Data
    }

    private static func drawPDFText(
        _ text: String,
        at point: CGPoint,
        in context: CGContext,
        fontSize: CGFloat,
        color: NSColor
    ) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: color
            ]
        ))
        context.saveGState()
        context.setFillColor(color.cgColor)
        context.textPosition = point
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func html(
        for note: MarkdownNote,
        attachmentPresentation: NoteAttachmentPresentation,
        store: MarkdownNoteStore,
        assetDirectory: URL,
        textScale: CGFloat,
        textSpacing: CGFloat
    ) -> String {
        let source = sourceWithoutTitle(note.markdown)
        let body = renderedBody(
            source,
            note: note,
            baseURL: store.noteFolderURL(for: note),
            attachmentPresentation: attachmentPresentation,
            store: store,
            assetDirectory: assetDirectory
        )

        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><style>
        @page { size: Letter; margin: 48px; }
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; color: #202124; font-size: \(12 * textScale)pt; }
        h1 { font-size: \(25 * textScale)pt; margin: 0 0 4px; }
        h2 { font-size: \(17 * textScale)pt; margin: 22px 0 7px; }
        h3 { font-size: \(14 * textScale)pt; margin: 16px 0 5px; }
        p { line-height: \(1.25 + (0.2 * textSpacing)); margin: \(6 * textSpacing)pt 0; }
        ul { margin-top: 5px; } li { margin: 3px 0; }
        .subtitle { color: #666; margin-bottom: 24px; }
        .attachment { border: 1px solid #b9b9b9; border-radius: 7px; padding: 10px 12px; margin: 14px 0; page-break-inside: avoid; }
        .attachment-title { font-weight: 600; }
        .attachment-meta { color: #666; font-size: 10pt; margin-top: 3px; }
        .attachment-widget { display: flex; align-items: center; gap: 10px; padding: 12px 14px; margin: 16px 0; }
        .attachment-icon { width: 24px; height: 24px; border-radius: 6px; background: #e8e8e8; color: #555; text-align: center; line-height: 24px; font-size: 16pt; }
        .attachment-copy { flex: 1; }
        .table-wrap { overflow: hidden; margin: 14px 0; page-break-inside: avoid; }
        table { border-collapse: collapse; font-size: 10pt; }
        th, td { border: 1px solid #b9b9b9; padding: 7px 10px; vertical-align: middle; }
        th { background: #e8e8e8; font-weight: 600; }
        img { max-width: 100%; max-height: 680px; object-fit: contain; }
        .pdf-page { display: block; width: auto; max-width: 516px; max-height: 680px; object-fit: contain; margin: 10px auto; page-break-inside: avoid; }
        .diagram { margin: 14px 0; page-break-inside: avoid; }
        .diagram-image { display: block; width: 100%; max-width: 516px; height: auto; }
        pre { white-space: pre-wrap; font-family: Menlo, monospace; font-size: 9pt; background: #f3f3f3; padding: 10px; }
        </style></head><body>
        <h1>\(htmlEscape(note.title))</h1>
        <div class="subtitle">\(note.modified.formatted(date: .long, time: .shortened))</div>
        \(body)
        </body></html>
        """
    }

    private static func sourceWithoutTitle(_ source: String) -> String {
        guard let firstLineEnd = source.firstIndex(of: "\n") else {
            return source.hasPrefix("# ") ? "" : source
        }
        let firstLine = String(source[..<firstLineEnd])
        guard firstLine.hasPrefix("# ") else { return source }
        return String(source[source.index(after: firstLineEnd)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func renderedBody(
        _ source: String,
        note: MarkdownNote?,
        baseURL: URL,
        attachmentPresentation: NoteAttachmentPresentation,
        store: MarkdownNoteStore,
        assetDirectory: URL
    ) -> String {
        let sourceNSString = source as NSString
        let tables = MarkdownTableParser.tables(in: source)
        guard !tables.isEmpty else {
            return renderedMarkdownRegion(
                source,
                note: note,
                baseURL: baseURL,
                attachmentPresentation: attachmentPresentation,
                store: store,
                assetDirectory: assetDirectory
            )
        }

        var output = ""
        var location = 0
        for table in tables {
            if table.range.location > location {
                output += renderedMarkdownRegion(
                    sourceNSString.substring(with: NSRange(
                        location: location,
                        length: table.range.location - location
                    )),
                    note: note,
                    baseURL: baseURL,
                    attachmentPresentation: attachmentPresentation,
                    store: store,
                    assetDirectory: assetDirectory
                )
            }
            output += renderedTable(table, note: note)
            location = NSMaxRange(table.range)
        }
        if location < sourceNSString.length {
            output += renderedMarkdownRegion(
                sourceNSString.substring(from: location),
                note: note,
                baseURL: baseURL,
                attachmentPresentation: attachmentPresentation,
                store: store,
                assetDirectory: assetDirectory
            )
        }
        return output
    }

    private static func renderedMarkdownRegion(
        _ source: String,
        note: MarkdownNote?,
        baseURL: URL,
        attachmentPresentation: NoteAttachmentPresentation,
        store: MarkdownNoteStore,
        assetDirectory: URL
    ) -> String {
        source.components(separatedBy: "\n\n").compactMap { block -> String? in
            let value = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }

            if let attachment = attachment(in: value, note: note, baseURL: baseURL, store: store) {
                switch attachmentPresentation {
                case .excluded:
                    return nil
                case .collapsed:
                    return attachmentCard(attachment)
                case .expanded:
                    return expandedAttachment(attachment, note: note, store: store, attachmentPresentation: attachmentPresentation, assetDirectory: assetDirectory)
                }
            }

            if let diagram = mermaidDiagramHTML(value, assetDirectory: assetDirectory) {
                return diagram
            }
            return markdownBlock(value)
        }.joined(separator: "\n\n")
    }

    private static func renderedTable(_ block: MarkdownTableBlock, note: MarkdownNote?) -> String {
        let layout = note.map {
            MarkdownTableLayoutStore.load(note: $0, tableIndex: block.tableIndex, table: block.table)
        } ?? MarkdownTableLayout.defaultLayout(for: block.table)
        let columnWidths = layout.columnWidths.map { String(format: "%.0fpx", $0) }
        let headerCells = block.table.headers.enumerated().map { index, value in
            "<th style=\"width:\(columnWidths[index]); text-align:\(cssAlignment(block.table.alignments[index]));\">\(inlineMarkdown(htmlEscape(value)))</th>"
        }.joined()
        let rows = block.table.rows.enumerated().map { rowIndex, row in
            let rowHeight = String(format: "%.0fpx", layout.rowHeights[rowIndex])
            let cells = row.enumerated().map { index, value in
                "<td style=\"width:\(columnWidths[index]); height:\(rowHeight); text-align:\(cssAlignment(block.table.alignments[index]));\">\(inlineMarkdown(htmlEscape(value)))</td>"
            }.joined()
            return "<tr>\(cells)</tr>"
        }.joined()
        return "<div class=\"table-wrap\"><table><thead><tr>\(headerCells)</tr></thead><tbody>\(rows)</tbody></table></div>"
    }

    private static func cssAlignment(_ alignment: MarkdownTableAlignment) -> String {
        switch alignment {
        case .center: return "center"
        case .right: return "right"
        case .none, .left: return "left"
        }
    }

    private static func mermaidDiagramHTML(_ value: String, assetDirectory: URL) -> String? {
        let lines = value.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "```mermaid",
              lines.last?.trimmingCharacters(in: .whitespaces) == "```" else { return nil }

        let diagramLines = Array(lines.dropFirst().dropLast())
        guard diagramLines.first?.trimmingCharacters(in: .whitespaces) == "sequenceDiagram" else {
            return "<pre>\(htmlEscape(diagramLines.joined(separator: "\n")))</pre>"
        }

        var participants: [(id: String, label: String)] = []
        var participantIDs = Set<String>()
        var messages: [(from: String, to: String, returnMessage: Bool, label: String)] = []
        let participantExpression = try? NSRegularExpression(
            pattern: #"^\s*participant\s+([A-Za-z0-9_-]+)(?:\s+as\s+(.+))?\s*$"#
        )
        let messageExpression = try? NSRegularExpression(
            pattern: #"^\s*([A-Za-z0-9_-]+)\s*(-->>|->>|-->|->)\s*([A-Za-z0-9_-]+)\s*:\s*(.+)$"#
        )

        for line in diagramLines.dropFirst() {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = participantExpression?.firstMatch(in: line, range: range) {
                let value = line as NSString
                let id = value.substring(with: match.range(at: 1))
                let label = match.range(at: 2).location == NSNotFound
                    ? id
                    : value.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                if participantIDs.insert(id).inserted {
                    participants.append((id: id, label: label))
                }
                continue
            }
            guard let match = messageExpression?.firstMatch(in: line, range: range) else { continue }
            let value = line as NSString
            let arrow = value.substring(with: match.range(at: 2))
            let from = value.substring(with: match.range(at: 1))
            let to = value.substring(with: match.range(at: 3))
            let label = value.substring(with: match.range(at: 4))
            if participantIDs.insert(from).inserted { participants.append((id: from, label: from)) }
            if participantIDs.insert(to).inserted { participants.append((id: to, label: to)) }
            messages.append((from: from, to: to, returnMessage: arrow.hasPrefix("--"), label: label))
        }

        guard participants.count > 1, !messages.isEmpty else { return "<pre>\(htmlEscape(diagramLines.joined(separator: "\n")))</pre>" }
        let columnWidth = 170
        let width = max(560, participants.count * columnWidth)
        let top = 72
        let rowHeight = 48
        let height = top + max(1, messages.count) * rowHeight + 40
        let positions = Dictionary(uniqueKeysWithValues: participants.enumerated().map { index, participant in
            (participant.id, 40 + index * columnWidth)
        })

        guard let png = sequenceDiagramPNG(
            participants: participants,
            messages: messages,
            positions: positions,
            width: width,
            height: height,
            top: top,
            rowHeight: rowHeight
        ) else { return "<pre>\(htmlEscape(diagramLines.joined(separator: "\n")))</pre>" }
        let diagramURL = assetDirectory.appendingPathComponent("diagram-\(UUID().uuidString).png")
        guard (try? png.write(to: diagramURL, options: .atomic)) != nil else {
            return "<pre>\(htmlEscape(diagramLines.joined(separator: "\n")))</pre>"
        }
        return "<div class=\"diagram\">\(assetToken(fileName: diagramURL.lastPathComponent, size: NSSize(width: width, height: height)))</div>"
    }

    private static func sequenceDiagramPNG(
        participants: [(id: String, label: String)],
        messages: [(from: String, to: String, returnMessage: Bool, label: String)],
        positions: [String: Int],
        width: Int,
        height: Int,
        top: Int,
        rowHeight: Int
    ) -> Data? {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocusFlipped(true)
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor(calibratedWhite: 0.08, alpha: 1)
        ]
        let messageAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor(calibratedWhite: 0.22, alpha: 1)
        ]
        for participant in participants {
            let x = CGFloat(positions[participant.id] ?? 0)
            let box = NSRect(x: x - 55, y: 16, width: 110, height: 30)
            NSColor(calibratedWhite: 0.9, alpha: 1).setFill()
            NSColor(calibratedWhite: 0.42, alpha: 1).setStroke()
            NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
            NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).stroke()
            let labelSize = (participant.label as NSString).size(withAttributes: labelAttributes)
            (participant.label as NSString).draw(
                at: NSPoint(x: x - labelSize.width / 2, y: 25),
                withAttributes: labelAttributes
            )
            let lifeline = NSBezierPath()
            lifeline.move(to: NSPoint(x: x, y: 46))
            lifeline.line(to: NSPoint(x: x, y: CGFloat(height - 18)))
            lifeline.setLineDash([5, 5], count: 2, phase: 0)
            NSColor(calibratedWhite: 0.62, alpha: 1).setStroke()
            lifeline.stroke()
        }

        for (index, message) in messages.enumerated() {
            guard let fromValue = positions[message.from], let toValue = positions[message.to] else { continue }
            let from = CGFloat(fromValue)
            let to = CGFloat(toValue)
            let y = CGFloat(top + index * rowHeight)
            let line = NSBezierPath()
            line.move(to: NSPoint(x: from, y: y))
            line.line(to: NSPoint(x: to, y: y))
            if message.returnMessage { line.setLineDash([6, 4], count: 2, phase: 0) }
            NSColor(calibratedWhite: 0.29, alpha: 1).setStroke()
            line.stroke()

            let direction: CGFloat = to >= from ? 1 : -1
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: to, y: y))
            arrow.line(to: NSPoint(x: to - direction * 8, y: y - 4))
            arrow.move(to: NSPoint(x: to, y: y))
            arrow.line(to: NSPoint(x: to - direction * 8, y: y + 4))
            arrow.stroke()

            let messageSize = (message.label as NSString).size(withAttributes: messageAttributes)
            (message.label as NSString).draw(
                at: NSPoint(x: (from + to) / 2 - messageSize.width / 2, y: y - 18),
                withAttributes: messageAttributes
            )
        }
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func markdownBlock(_ value: String) -> String {
        let lines = value.components(separatedBy: "\n")
        var output = ""
        var inList = false

        for line in lines {
            let escaped = htmlEscape(line)
            if line.hasPrefix("### ") {
                if inList { output += "</ul>"; inList = false }
                output += "<h3>\(htmlEscape(String(line.dropFirst(4))))</h3>"
            } else if line.hasPrefix("## ") {
                if inList { output += "</ul>"; inList = false }
                output += "<h2>\(htmlEscape(String(line.dropFirst(3))))</h2>"
            } else if line.hasPrefix("# ") {
                if inList { output += "</ul>"; inList = false }
                output += "<h1>\(htmlEscape(String(line.dropFirst(2))))</h1>"
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                if !inList { output += "<ul>"; inList = true }
                output += "<li>\(inlineMarkdown(String(line.dropFirst(2))))</li>"
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                if inList { output += "</ul>"; inList = false }
                output += "<p>\(inlineMarkdown(escaped))</p>"
            }
        }
        if inList { output += "</ul>" }
        return output
    }

    private static func inlineMarkdown(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
            .replacingOccurrences(of: #"\*(.+?)\*"#, with: "<em>$1</em>", options: .regularExpression)
    }

    private struct Attachment {
        let label: String
        let url: URL
        let isImage: Bool
    }

    private static func attachment(
        in value: String,
        note: MarkdownNote?,
        baseURL: URL,
        store: MarkdownNoteStore
    ) -> Attachment? {
        let pattern = #"^(!?)\[([^\]]*)\]\(([^)]+)\)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)) else {
            return nil
        }
        let nsValue = value as NSString
        let path = nsValue.substring(with: match.range(at: 3))
        let url: URL?
        if let note {
            url = store.attachmentURL(for: note, relativePath: path)
        } else {
            let candidate = baseURL.appendingPathComponent(path).standardizedFileURL
            url = candidate.path.hasPrefix(baseURL.standardizedFileURL.path + "/") ? candidate : nil
        }
        guard let url,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return Attachment(
            label: nsValue.substring(with: match.range(at: 2)),
            url: url,
            isImage: nsValue.substring(with: match.range(at: 1)) == "!"
        )
    }

    private static func attachmentCard(_ attachment: Attachment) -> String {
        let extensionName = attachment.url.pathExtension.lowercased()
        let kind = extensionName.isEmpty ? "Attachment" : extensionName.uppercased()
        let symbol: String
        let detail: String
        switch extensionName {
        case "pdf":
            symbol = "▣"
            if let pageCount = PDFDocument(url: attachment.url)?.pageCount {
                let pageLabel = pageCount == 1 ? "page" : "pages"
                detail = "PDF · \(pageCount) \(pageLabel)"
            } else {
                detail = "PDF document"
            }
        case "md", "markdown", "mdown", "mkd":
            symbol = "≡"
            detail = "Markdown document"
        case "png", "jpg", "jpeg", "gif", "heic", "webp":
            symbol = "▧"
            detail = "Image"
        default:
            symbol = "⌕"
            detail = "\(kind) attachment"
        }
        return "<div class=\"attachment attachment-widget\"><div class=\"attachment-icon\">\(symbol)</div><div class=\"attachment-copy\"><div class=\"attachment-title\">\(htmlEscape(attachment.label))</div><div class=\"attachment-meta\">\(detail)</div></div></div>"
    }

    private static func expandedAttachment(
        _ attachment: Attachment,
        note: MarkdownNote?,
        store: MarkdownNoteStore,
        attachmentPresentation: NoteAttachmentPresentation,
        assetDirectory: URL
    ) -> String {
        if attachment.isImage,
           let data = try? Data(contentsOf: attachment.url) {
            let extensionName = attachment.url.pathExtension.isEmpty ? "png" : attachment.url.pathExtension
            let imageURL = assetDirectory.appendingPathComponent("image-\(UUID().uuidString).\(extensionName)")
            guard (try? data.write(to: imageURL, options: .atomic)) != nil else { return attachmentCard(attachment) }
            return "<div class=\"attachment\"><div class=\"attachment-title\">\(htmlEscape(attachment.label))</div>\(assetToken(fileName: imageURL.lastPathComponent, size: NSSize(width: 516, height: 516)))</div>"
        }

        if ["md", "markdown", "mdown", "mkd"].contains(attachment.url.pathExtension.lowercased()),
           let contents = try? String(contentsOf: attachment.url, encoding: .utf8) {
            let nested = renderedBody(
                contents,
                note: nil,
                baseURL: attachment.url.deletingLastPathComponent(),
                attachmentPresentation: attachmentPresentation,
                store: store,
                assetDirectory: assetDirectory
            )
            return "<div class=\"attachment\"><div class=\"attachment-title\">\(htmlEscape(attachment.label))</div>\(nested)</div>"
        }

        if let pdf = PDFDocument(url: attachment.url) {
            if pdf.pageCount > 0 {
                return "<div class=\"attachment\"><div class=\"attachment-title\">\(htmlEscape(attachment.label))</div><div class=\"attachment-meta\">PDF pages included after the note</div></div>"
            }
        }

        return attachmentCard(attachment)
    }

    private static func expandedPDFPages(
        for source: String,
        note: MarkdownNote?,
        baseURL: URL,
        store: MarkdownNoteStore
    ) -> [ExportPage] {
        var pages: [ExportPage] = []
        for block in source.components(separatedBy: "\n\n") {
            let value = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let attachment = attachment(in: value, note: note, baseURL: baseURL, store: store) else { continue }
            if let pdf = PDFDocument(url: attachment.url) {
                pages.append(contentsOf: (0..<pdf.pageCount).compactMap { index in
                    guard let page = pdf.page(at: index) else { return nil }
                    return ExportPage(page: page, fitToContent: true)
                })
            } else if ["md", "markdown", "mdown", "mkd"].contains(attachment.url.pathExtension.lowercased()),
                      let contents = try? String(contentsOf: attachment.url, encoding: .utf8) {
                pages.append(contentsOf: expandedPDFPages(
                    for: contents,
                    note: nil,
                    baseURL: attachment.url.deletingLastPathComponent(),
                    store: store
                ))
            }
        }
        return pages
    }

    private static func renderPDFPage(_ page: PDFPage, fitting maxSize: NSSize) -> (data: Data, size: NSSize)? {
        let bounds = page.bounds(for: .mediaBox).standardized
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(maxSize.width / bounds.width, maxSize.height / bounds.height)
        let proposedSize = NSSize(width: max(1, ceil(bounds.width * scale)), height: max(1, ceil(bounds.height * scale)))
        let image = page.thumbnail(of: proposedSize, for: .mediaBox)
        var proposedRect = NSRect(origin: .zero, size: proposedSize)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else { return nil }
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return (data, size)
    }

    private static func assetToken(fileName: String, size: NSSize) -> String {
        "[[FREEFLOW_ASSET:\(fileName):\(Int(size.width)):\(Int(size.height))]]"
    }

    private static func replaceAssetTokens(in attributed: NSMutableAttributedString, assetDirectory: URL) {
        let pattern = #"\[\[FREEFLOW_ASSET:([^:\]]+):(\d+):(\d+)\]\]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        while true {
            let range = NSRange(location: 0, length: attributed.length)
            guard let match = expression.firstMatch(in: attributed.string, range: range) else { return }
            let value = attributed.string as NSString
            let fileName = value.substring(with: match.range(at: 1))
            let width = CGFloat(Double(value.substring(with: match.range(at: 2))) ?? 1)
            let height = CGFloat(Double(value.substring(with: match.range(at: 3))) ?? 1)
            let imageURL = assetDirectory.appendingPathComponent(fileName)
            if let imageData = try? Data(contentsOf: imageURL),
               let image = NSImage(data: imageData) {
                let attachment = NSTextAttachment()
                attachment.contents = imageData
                attachment.fileType = UTType.png.identifier
                attachment.image = image
                attachment.attachmentCell = ExportImageAttachmentCell(image: image, size: NSSize(width: width, height: height))
                attachment.bounds = NSRect(x: 0, y: 0, width: width, height: height)
                let attachmentString = NSMutableAttributedString(attachment: attachment)
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.alignment = .center
                attachmentString.addAttribute(
                    .paragraphStyle,
                    value: paragraphStyle,
                    range: NSRange(location: 0, length: attachmentString.length)
                )
                attributed.replaceCharacters(in: match.range, with: attachmentString)
            } else {
                attributed.replaceCharacters(in: match.range, with: "[Attachment unavailable]")
            }
        }
    }

    private static func htmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private final class ExportImageAttachmentCell: NSTextAttachmentCell {
    private let desiredSize: NSSize
    private let sourceImage: NSImage

    init(image: NSImage, size: NSSize) {
        self.sourceImage = image
        self.desiredSize = size
        super.init(imageCell: image)
    }

    required init(coder: NSCoder) {
        self.sourceImage = NSImage(size: .zero)
        self.desiredSize = .zero
        super.init(coder: coder)
    }

    override func cellSize(forBounds rect: NSRect) -> NSSize {
        desiredSize
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        sourceImage.draw(
            in: cellFrame,
            from: NSRect(origin: .zero, size: sourceImage.size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }
}
