import Foundation

enum MarkdownTableEditorTests {
    static func run() {
        testParsesAndSerializesTable()
        testPreservesExactSourceRange()
        testIgnoresFencedCode()
        testReordersRowsAndColumns()
        testPersistsTableLayoutBesideNoteAttachments()
    }

    private static func testParsesAndSerializesTable() {
        let markdown = """
        | Name | Score | Notes |
        | :--- | ---: | :---: |
        | Ada | 10 | A \\| B |
        """
        let block = MarkdownTableParser.tables(in: markdown).first
        TestSupport.expectEqual(block?.table.headers, ["Name", "Score", "Notes"])
        TestSupport.expectEqual(block?.table.alignments, [.left, .right, .center])
        TestSupport.expectEqual(block?.table.rows, [["Ada", "10", "A | B"]])
        TestSupport.expectEqual(block?.table.markdown, markdown)
    }

    private static func testPreservesExactSourceRange() {
        let markdown = "Before\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\nAfter"
        guard let block = MarkdownTableParser.tables(in: markdown).first else {
            fatalError("Expected a Markdown table")
        }
        TestSupport.expectEqual(block.source, "| A | B |\n| --- | --- |\n| 1 | 2 |")
        let source = markdown as NSString
        TestSupport.expectEqual(source.substring(with: block.range), block.source)
        TestSupport.expectEqual(
            source.replacingCharacters(in: block.range, with: "| C |\n| --- |"),
            "Before\n\n| C |\n| --- |\n\nAfter"
        )
    }

    private static func testIgnoresFencedCode() {
        let markdown = """
        ```
        | A | B |
        | --- | --- |
        ```

        | Real | Table |
        | --- | --- |
        """
        let tables = MarkdownTableParser.tables(in: markdown)
        TestSupport.expectEqual(tables.count, 1)
        TestSupport.expectEqual(tables.first?.table.headers, ["Real", "Table"])
    }

    private static func testReordersRowsAndColumns() {
        var table = MarkdownTable(
            headers: ["A", "B", "C"],
            alignments: [.left, .center, .right],
            rows: [["1A", "1B", "1C"], ["2A", "2B", "2C"]]
        )
        table.moveRow(from: 1, to: 0)
        TestSupport.expectEqual(table.rows, [["2A", "2B", "2C"], ["1A", "1B", "1C"]])
        table.moveColumn(from: 2, to: 0)
        TestSupport.expectEqual(table.headers, ["C", "A", "B"])
        TestSupport.expectEqual(table.alignments, [.right, .left, .center])
        TestSupport.expectEqual(table.rows, [["2C", "2A", "2B"], ["1C", "1A", "1B"]])
    }

    private static func testPersistsTableLayoutBesideNoteAttachments() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MarkdownNoteStore(directory: directory)
        let note = MarkdownNote(id: UUID(), markdown: "# Table", modified: Date())
        let table = MarkdownTable(
            headers: ["A", "B"],
            alignments: [.left, .right],
            rows: [["1", "2"]]
        )
        let layout = MarkdownTableLayout(columnWidths: [240, 320], rowHeights: [72])
        do {
            try MarkdownTableLayoutStore.save(layout, note: note, tableIndex: 0, table: table, store: store)
        } catch {
            fatalError("Expected table layout to save: \(error)")
        }
        TestSupport.expectEqual(
            MarkdownTableLayoutStore.load(note: note, tableIndex: 0, table: table, store: store),
            layout
        )
    }
}
