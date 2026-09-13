import Foundation
import MarkdownUI
import SwiftUI
import UniformTypeIdentifiers

enum MarkdownTableAlignment: String, CaseIterable, Identifiable {
    case none
    case left
    case center
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Default"
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        }
    }

    var systemImage: String {
        switch self {
        case .none, .left: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .right: return "text.alignright"
        }
    }

    var separator: String {
        switch self {
        case .none: return "---"
        case .left: return ":---"
        case .center: return ":---:"
        case .right: return "---:"
        }
    }
}

struct MarkdownTable: Equatable {
    var headers: [String]
    var alignments: [MarkdownTableAlignment]
    var rows: [[String]]

    var columnCount: Int { headers.count }

    mutating func addRow() {
        rows.append(Array(repeating: "", count: columnCount))
    }

    mutating func removeRow(at index: Int) {
        guard rows.indices.contains(index) else { return }
        rows.remove(at: index)
    }

    mutating func moveRow(from source: Int, to destination: Int) {
        guard rows.indices.contains(source), rows.indices.contains(destination), source != destination else { return }
        let row = rows.remove(at: source)
        rows.insert(row, at: destination)
    }

    mutating func addColumn() {
        headers.append("Column \(headers.count + 1)")
        alignments.append(.none)
        for index in rows.indices {
            rows[index].append("")
        }
    }

    mutating func removeColumn(at index: Int) {
        guard columnCount > 1, headers.indices.contains(index) else { return }
        headers.remove(at: index)
        alignments.remove(at: index)
        for rowIndex in rows.indices where rows[rowIndex].indices.contains(index) {
            rows[rowIndex].remove(at: index)
        }
    }

    mutating func moveColumn(from source: Int, to destination: Int) {
        guard headers.indices.contains(source), headers.indices.contains(destination), source != destination else { return }
        let header = headers.remove(at: source)
        headers.insert(header, at: destination)
        let alignment = alignments.remove(at: source)
        alignments.insert(alignment, at: destination)
        for rowIndex in rows.indices {
            let cell = rows[rowIndex].remove(at: source)
            rows[rowIndex].insert(cell, at: destination)
        }
    }

    var markdown: String {
        let headerLine = Self.renderRow(headers)
        let separatorLine = Self.renderRow(alignments.map(\.separator))
        let bodyLines = rows.map(Self.renderRow)
        return ([headerLine, separatorLine] + bodyLines).joined(separator: "\n")
    }

    private static func renderRow(_ cells: [String]) -> String {
        "| " + cells.map(escapeCell).joined(separator: " | ") + " |"
    }

    private static func escapeCell(_ value: String) -> String {
        var result = ""
        var precedingBackslashes = 0
        for character in value.replacingOccurrences(of: "\n", with: "<br>") {
            if character == "|", precedingBackslashes % 2 == 0 {
                result.append("\\")
            }
            result.append(character)
            if character == "\\" {
                precedingBackslashes += 1
            } else {
                precedingBackslashes = 0
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MarkdownTableLayout: Codable, Equatable {
    static let defaultColumnWidth = 180.0
    static let minimumColumnWidth = 120.0
    static let maximumColumnWidth = 640.0
    static let defaultRowHeight = 38.0
    static let minimumRowHeight = 30.0
    static let maximumRowHeight = 360.0

    var columnWidths: [Double]
    var rowHeights: [Double]

    static func defaultLayout(for table: MarkdownTable) -> MarkdownTableLayout {
        MarkdownTableLayout(
            columnWidths: Array(repeating: defaultColumnWidth, count: table.columnCount),
            rowHeights: Array(repeating: defaultRowHeight, count: table.rows.count)
        )
    }

    func normalized(for table: MarkdownTable) -> MarkdownTableLayout {
        MarkdownTableLayout(
            columnWidths: Self.normalizedValues(
                columnWidths,
                count: table.columnCount,
                defaultValue: Self.defaultColumnWidth,
                minimum: Self.minimumColumnWidth,
                maximum: Self.maximumColumnWidth
            ),
            rowHeights: Self.normalizedValues(
                rowHeights,
                count: table.rows.count,
                defaultValue: Self.defaultRowHeight,
                minimum: Self.minimumRowHeight,
                maximum: Self.maximumRowHeight
            )
        )
    }

    private static func normalizedValues(
        _ values: [Double],
        count: Int,
        defaultValue: Double,
        minimum: Double,
        maximum: Double
    ) -> [Double] {
        let clamped = values.prefix(count).map { min(max($0, minimum), maximum) }
        return clamped + Array(repeating: defaultValue, count: max(0, count - clamped.count))
    }
}

enum MarkdownTableLayoutStore {
    private static let fileName = ".freeflow-table-layouts.json"

    static func load(
        note: MarkdownNote,
        tableIndex: Int,
        table: MarkdownTable,
        store: MarkdownNoteStore = .standard
    ) -> MarkdownTableLayout {
        let fallback = MarkdownTableLayout.defaultLayout(for: table)
        let url = store.attachmentDirectory(for: note).appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let layouts = try? JSONDecoder().decode([String: MarkdownTableLayout].self, from: data),
              let layout = layouts[String(tableIndex)] else { return fallback }
        return layout.normalized(for: table)
    }

    static func save(
        _ layout: MarkdownTableLayout,
        note: MarkdownNote,
        tableIndex: Int,
        table: MarkdownTable,
        store: MarkdownNoteStore = .standard
    ) throws {
        let directory = try store.prepareAttachmentDirectory(for: note)
        let url = directory.appendingPathComponent(fileName)
        var layouts: [String: MarkdownTableLayout] = [:]
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: MarkdownTableLayout].self, from: data) {
            layouts = decoded
        }
        layouts[String(tableIndex)] = layout.normalized(for: table)
        try JSONEncoder().encode(layouts).write(to: url, options: .atomic)
    }
}

struct MarkdownTableBlock: Identifiable, Equatable {
    let tableIndex: Int
    let range: NSRange
    let source: String
    let table: MarkdownTable

    var id: Int { range.location }

    init(tableIndex: Int = 0, range: NSRange, source: String, table: MarkdownTable) {
        self.tableIndex = tableIndex
        self.range = range
        self.source = source
        self.table = table
    }

    static func == (lhs: MarkdownTableBlock, rhs: MarkdownTableBlock) -> Bool {
        lhs.range == rhs.range && lhs.source == rhs.source && lhs.table == rhs.table
    }
}

enum MarkdownTableParser {
    private struct Line {
        let text: String
        let start: Int
        let contentLength: Int
    }

    static func tables(in markdown: String) -> [MarkdownTableBlock] {
        let source = markdown as NSString
        let lines = lineRecords(in: source)
        guard lines.count >= 2 else { return [] }

        var results: [MarkdownTableBlock] = []
        var index = 0
        var fenceMarker: Character?

        while index < lines.count {
            let trimmed = lines[index].text.trimmingCharacters(in: .whitespaces)
            if let marker = fenceMarker {
                if trimmed.hasPrefix(String(repeating: String(marker), count: 3)) {
                    fenceMarker = nil
                }
                index += 1
                continue
            }
            if trimmed.hasPrefix("```") {
                fenceMarker = "`"
                index += 1
                continue
            }
            if trimmed.hasPrefix("~~~") {
                fenceMarker = "~"
                index += 1
                continue
            }

            guard index + 1 < lines.count,
                  let headers = parseRow(lines[index].text),
                  headers.count > 0,
                  let alignments = parseSeparatorRow(lines[index + 1].text),
                  alignments.count == headers.count else {
                index += 1
                continue
            }

            var rows: [[String]] = []
            var endIndex = index + 1
            var candidateIndex = index + 2
            while candidateIndex < lines.count,
                  let cells = parseRow(lines[candidateIndex].text),
                  !lines[candidateIndex].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rows.append(normalized(cells, count: headers.count))
                endIndex = candidateIndex
                candidateIndex += 1
            }

            let start = lines[index].start
            let end = lines[endIndex].start + lines[endIndex].contentLength
            let range = NSRange(location: start, length: end - start)
            results.append(MarkdownTableBlock(
                tableIndex: results.count,
                range: range,
                source: source.substring(with: range),
                table: MarkdownTable(
                    headers: normalized(headers, count: headers.count),
                    alignments: alignments,
                    rows: rows
                )
            ))
            index = endIndex + 1
        }
        return results
    }

    private static func lineRecords(in source: NSString) -> [Line] {
        guard source.length > 0 else { return [] }
        var lines: [Line] = []
        var location = 0
        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            var contentRange = lineRange
            while contentRange.length > 0 {
                let finalCharacter = source.character(at: NSMaxRange(contentRange) - 1)
                guard finalCharacter == 10 || finalCharacter == 13 else { break }
                contentRange.length -= 1
            }
            lines.append(Line(
                text: source.substring(with: contentRange),
                start: contentRange.location,
                contentLength: contentRange.length
            ))
            location = NSMaxRange(lineRange)
        }
        return lines
    }

    private static func parseSeparatorRow(_ line: String) -> [MarkdownTableAlignment]? {
        guard let cells = parseRow(line), !cells.isEmpty else { return nil }
        var alignments: [MarkdownTableAlignment] = []
        for cell in cells {
            let value = cell.trimmingCharacters(in: .whitespaces)
            let left = value.hasPrefix(":")
            let right = value.hasSuffix(":")
            let dashes = value.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (left, right) {
            case (true, true): alignments.append(.center)
            case (true, false): alignments.append(.left)
            case (false, true): alignments.append(.right)
            case (false, false): alignments.append(.none)
            }
        }
        return alignments
    }

    private static func parseRow(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        var content = trimmed
        if content.first == "|" { content.removeFirst() }
        if content.last == "|", !isEscapedPipe(at: content.index(before: content.endIndex), in: content) {
            content.removeLast()
        }

        var cells: [String] = []
        var cell = ""
        var precedingBackslashes = 0
        for character in content {
            if character == "|", precedingBackslashes % 2 == 0 {
                cells.append(decodedCell(cell))
                cell = ""
                precedingBackslashes = 0
                continue
            }
            cell.append(character)
            if character == "\\" {
                precedingBackslashes += 1
            } else {
                precedingBackslashes = 0
            }
        }
        cells.append(decodedCell(cell))
        return cells
    }

    private static func decodedCell(_ cell: String) -> String {
        let value = cell.trimmingCharacters(in: .whitespaces)
        var result = ""
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(after: index)
            if value[index] == "\\", next < value.endIndex, value[next] == "|" {
                result.append("|")
                index = value.index(after: next)
            } else {
                result.append(value[index])
                index = next
            }
        }
        return result
    }

    private static func isEscapedPipe(at index: String.Index, in value: String) -> Bool {
        var backslashCount = 0
        var cursor = index
        while cursor > value.startIndex {
            let previous = value.index(before: cursor)
            guard value[previous] == "\\" else { break }
            backslashCount += 1
            cursor = previous
        }
        return backslashCount % 2 == 1
    }

    private static func normalized(_ cells: [String], count: Int) -> [String] {
        if cells.count == count { return cells }
        if cells.count > count { return Array(cells.prefix(count)) }
        return cells + Array(repeating: "", count: count - cells.count)
    }
}

struct MarkdownTableRenderedView: View {
    let block: MarkdownTableBlock
    let note: MarkdownNote
    private let layout: MarkdownTableLayout

    init(block: MarkdownTableBlock, note: MarkdownNote) {
        self.block = block
        self.note = note
        self.layout = MarkdownTableLayoutStore.load(
            note: note,
            tableIndex: block.tableIndex,
            table: block.table
        )
    }

    var body: some View {
        ScrollView(.horizontal) {
            MarkdownTableGrid(table: block.table, layout: layout)
        }
    }
}

private struct MarkdownTableGrid: View {
    let table: MarkdownTable
    let layout: MarkdownTableLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(cells: table.headers, height: MarkdownTableLayout.defaultRowHeight, isHeader: true)
            ForEach(table.rows.indices, id: \.self) { rowIndex in
                row(
                    cells: table.rows[rowIndex],
                    height: layout.rowHeights[rowIndex],
                    isHeader: false
                )
            }
        }
        .background(.quaternary.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.secondary.opacity(0.28), lineWidth: 1)
        }
    }

    private func row(cells: [String], height: Double, isHeader: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(cells.indices, id: \.self) { index in
                Markdown(cells[index])
                    .font(isHeader ? .body.weight(.semibold) : .body)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(
                        width: layout.columnWidths[index],
                        alignment: table.alignments[index].swiftUIAlignment
                    )
                    .frame(minHeight: height, alignment: .center)
                    .background(isHeader ? Color.secondary.opacity(0.10) : Color.clear)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color.secondary.opacity(0.20)).frame(width: 1)
                    }
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color.secondary.opacity(0.20)).frame(height: 1)
                    }
            }
        }
    }
}

private extension MarkdownTableAlignment {
    var swiftUIAlignment: Alignment {
        switch self {
        case .center: return .center
        case .right: return .trailing
        case .none, .left: return .leading
        }
    }
}

struct MarkdownTableInlineEditor: View {
    let block: MarkdownTableBlock
    let note: MarkdownNote
    let onSave: (MarkdownTable, MarkdownTableLayout) -> Bool
    let onCancel: () -> Void
    @State private var table: MarkdownTable
    @State private var layout: MarkdownTableLayout
    @State private var saveError: String?
    @State private var draggedRow: Int?
    @State private var draggedColumn: Int?

    init(
        block: MarkdownTableBlock,
        note: MarkdownNote,
        onSave: @escaping (MarkdownTable, MarkdownTableLayout) -> Bool,
        onCancel: @escaping () -> Void
    ) {
        self.block = block
        self.note = note
        self.onSave = onSave
        self.onCancel = onCancel
        _table = State(initialValue: block.table)
        _layout = State(initialValue: MarkdownTableLayoutStore.load(
            note: note,
            tableIndex: block.tableIndex,
            table: block.table
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Edit table").font(.title2.weight(.semibold))
                    Text("Drag rows or columns to reorder them. Changes remain a draft until saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add column") { addColumn() }
                Button("Add row") { addRow() }
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Save table") { save() }
                    .buttonStyle(.borderedProminent)
            }

            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 8) {
                    columnControls
                    tableRow(label: "Header", values: headerBindings, isHeader: true)
                    ForEach(table.rows.indices, id: \.self) { rowIndex in
                        editableRow(at: rowIndex)
                    }
                }
                .padding(2)
            }

            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label("Live preview", systemImage: "eye")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    MarkdownTableGrid(table: table, layout: layout.normalized(for: table))
                }
            }
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        }
    }

    private var columnControls: some View {
        HStack(spacing: 8) {
            Text("Columns")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            ForEach(table.headers.indices, id: \.self) { columnIndex in
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.secondary)
                        .help("Drag to reorder column")
                        .contentShape(Rectangle())
                        .onDrag {
                            draggedColumn = columnIndex
                            return NSItemProvider(object: "freeflow-table-column-\(columnIndex)" as NSString)
                        }
                    Picker("Alignment", selection: alignmentBinding(columnIndex)) {
                        ForEach(MarkdownTableAlignment.allCases) { alignment in
                            Label(alignment.title, systemImage: alignment.systemImage).tag(alignment)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 70)
                    Button(role: .destructive) {
                        removeColumn(at: columnIndex)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(table.columnCount <= 1)
                    .help("Delete column")
                    DimensionDragHandle(
                        systemImage: "arrow.left.and.right",
                        help: "Drag to resize column",
                        value: columnWidthBinding(columnIndex),
                        minimum: MarkdownTableLayout.minimumColumnWidth,
                        maximum: MarkdownTableLayout.maximumColumnWidth,
                        axis: .horizontal
                    )
                }
                .frame(width: layout.columnWidths[columnIndex])
                .contentShape(Rectangle())
                .opacity(draggedColumn == columnIndex ? 0.55 : 1)
                .onDrop(
                    of: [UTType.text],
                    delegate: MarkdownTableColumnDropDelegate(
                        destination: columnIndex,
                        table: $table,
                        layout: $layout,
                        draggedColumn: $draggedColumn
                    )
                )
            }
        }
    }

    private func editableRow(at rowIndex: Int) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                Text("Row \(rowIndex + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DimensionDragHandle(
                    systemImage: "arrow.up.and.down",
                    help: "Drag to resize row",
                    value: rowHeightBinding(rowIndex),
                    minimum: MarkdownTableLayout.minimumRowHeight,
                    maximum: MarkdownTableLayout.maximumRowHeight,
                    axis: .vertical
                )
            }
            .frame(width: 72, alignment: .leading)
            .contentShape(Rectangle())
            .help("Drag to reorder row")
            .onDrag {
                draggedRow = rowIndex
                return NSItemProvider(object: "freeflow-table-row-\(rowIndex)" as NSString)
            }

            ForEach(table.headers.indices, id: \.self) { columnIndex in
                TextField("", text: cellBinding(row: rowIndex, column: columnIndex), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: layout.columnWidths[columnIndex])
                    .frame(minHeight: layout.rowHeights[rowIndex])
            }

            Button(role: .destructive) {
                removeRow(at: rowIndex)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete row")
        }
        .contentShape(Rectangle())
        .opacity(draggedRow == rowIndex ? 0.55 : 1)
        .onDrop(
            of: [UTType.text],
            delegate: MarkdownTableRowDropDelegate(
                destination: rowIndex,
                table: $table,
                layout: $layout,
                draggedRow: $draggedRow
            )
        )
    }

    private var headerBindings: [Binding<String>] {
        table.headers.indices.map { index in
            Binding(
                get: { table.headers[index] },
                set: { table.headers[index] = $0 }
            )
        }
    }

    private func cellBinding(row: Int, column: Int) -> Binding<String> {
        Binding(
            get: { table.rows[row][column] },
            set: { table.rows[row][column] = $0 }
        )
    }

    private func alignmentBinding(_ index: Int) -> Binding<MarkdownTableAlignment> {
        Binding(
            get: { table.alignments[index] },
            set: { table.alignments[index] = $0 }
        )
    }

    private func columnWidthBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { layout.columnWidths[index] },
            set: { layout.columnWidths[index] = $0 }
        )
    }

    private func rowHeightBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { layout.rowHeights[index] },
            set: { layout.rowHeights[index] = $0 }
        )
    }

    private func tableRow(label: String, values: [Binding<String>], isHeader: Bool) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption.weight(isHeader ? .semibold : .regular))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            ForEach(values.indices, id: \.self) { index in
                TextField("", text: values[index], axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(isHeader ? .body.weight(.semibold) : .body)
                    .frame(width: layout.columnWidths[index])
                    .frame(minHeight: 30)
            }
        }
    }

    private func save() {
        if onSave(table, layout.normalized(for: table)) {
            onCancel()
        } else {
            saveError = "The note changed while this table was being edited. Cancel and reopen the editor, then try again."
        }
    }

    private func addColumn() {
        table.addColumn()
        layout.columnWidths.append(MarkdownTableLayout.defaultColumnWidth)
    }

    private func removeColumn(at index: Int) {
        table.removeColumn(at: index)
        if layout.columnWidths.indices.contains(index) {
            layout.columnWidths.remove(at: index)
        }
    }

    private func addRow() {
        table.addRow()
        layout.rowHeights.append(MarkdownTableLayout.defaultRowHeight)
    }

    private func removeRow(at index: Int) {
        table.removeRow(at: index)
        if layout.rowHeights.indices.contains(index) {
            layout.rowHeights.remove(at: index)
        }
    }
}

private struct DimensionDragHandle: View {
    enum Axis { case horizontal, vertical }

    let systemImage: String
    let help: String
    @Binding var value: Double
    let minimum: Double
    let maximum: Double
    let axis: Axis
    @State private var dragStart: Double?

    var body: some View {
        Image(systemName: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 24)
            .contentShape(Rectangle())
            .help(help)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        if dragStart == nil { dragStart = value }
                        let delta = axis == .horizontal ? drag.translation.width : drag.translation.height
                        value = min(max((dragStart ?? value) + delta, minimum), maximum)
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }
}

private struct MarkdownTableRowDropDelegate: DropDelegate {
    let destination: Int
    @Binding var table: MarkdownTable
    @Binding var layout: MarkdownTableLayout
    @Binding var draggedRow: Int?

    func dropEntered(info: DropInfo) {
        guard let source = draggedRow, source != destination,
              table.rows.indices.contains(source), table.rows.indices.contains(destination) else { return }
        table.moveRow(from: source, to: destination)
        let height = layout.rowHeights.remove(at: source)
        layout.rowHeights.insert(height, at: destination)
        draggedRow = destination
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedRow = nil
        return true
    }
}

private struct MarkdownTableColumnDropDelegate: DropDelegate {
    let destination: Int
    @Binding var table: MarkdownTable
    @Binding var layout: MarkdownTableLayout
    @Binding var draggedColumn: Int?

    func dropEntered(info: DropInfo) {
        guard let source = draggedColumn, source != destination,
              table.headers.indices.contains(source), table.headers.indices.contains(destination) else { return }
        table.moveColumn(from: source, to: destination)
        let width = layout.columnWidths.remove(at: source)
        layout.columnWidths.insert(width, at: destination)
        draggedColumn = destination
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedColumn = nil
        return true
    }
}
