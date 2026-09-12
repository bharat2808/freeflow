import Foundation
import XCTest
@testable import FreeFlowNotesCore

final class ConnectorTests: XCTestCase {
    func testNoteRoundTripAndRevisionConflict() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotesStore(root: root)
        let created = try store.save(title: "Plan", content: "# Plan\n\nReview the project")
        let revision = store.revision(for: created)
        XCTAssertEqual(try store.read(id: created.id).title, "Plan")
        XCTAssertThrowsError(try store.save(id: created.id, content: "changed", expectedRevision: "stale"))
        _ = try store.save(id: created.id, content: "changed", expectedRevision: revision)
    }

    func testBM25RanksTitleMatchAndPaginates() throws {
        let notes = [
            ConnectorNote(id: UUID().uuidString, title: "Project Planning", folder: "", content: "Roadmap", modified: Date()),
            ConnectorNote(id: UUID().uuidString, title: "Other", folder: "", content: "Project planning details", modified: Date())
        ]
        let first = BM25Search().search(notes, query: "project planning", folder: nil, limit: 1, cursor: nil)
        XCTAssertEqual(first.results.count, 1)
        XCTAssertEqual(first.results[0].title, "Project Planning")
        XCTAssertNotNil(first.next)
        let second = BM25Search().search(notes, query: "project planning", folder: nil, limit: 1, cursor: first.next)
        XCTAssertEqual(second.results.count, 1)
    }
}
