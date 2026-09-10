import Foundation

enum MarkdownNoteStoreTests {
    static func run() {
        testTextChunking()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MarkdownNoteStore(directory: directory)
        do {
            let initial = try store.load()
            TestSupport.expectEqual(initial.count, 0)
            let note = MarkdownNote(id: UUID(), markdown: "# Synthetic plan\n\n## Tasks\n- [ ] Review draft\n\n**Keep formatting**", modified: Date())
            try store.save(note)
            let reopened = try store.load()
            TestSupport.expectEqual(reopened.count, 1)
            TestSupport.expectEqual(reopened.first?.markdown, note.markdown)
            TestSupport.expectEqual(reopened.first?.title, "Synthetic plan")
            var edited = note
            edited.markdown += "\n\nAn edit."
            try store.save(edited)
            let afterEdit = try store.load()
            TestSupport.expectEqual(afterEdit.count, 1)
            TestSupport.expectEqual(afterEdit.first?.markdown, edited.markdown)
            let folderNote = MarkdownNote(id: UUID(), markdown: "# Folder note", modified: Date(), folder: "Projects/Ideas")
            try store.save(folderNote)
            let nested = try store.load().first(where: { $0.id == folderNote.id })
            TestSupport.expectEqual(nested?.folder, "Projects/Ideas")
            let moved = try store.move(folderNote, toFolder: "Archive/2026")
            TestSupport.expectEqual(moved.folder, "Archive/2026")
            let movedReloaded = try store.load().first(where: { $0.id == folderNote.id })
            TestSupport.expect(movedReloaded?.folder == "Archive/2026", "Moved notes must load from their new folder")
            try store.renameFolder(from: "Archive", to: "Done")
            let renamedReloaded = try store.load().first(where: { $0.id == folderNote.id })
            TestSupport.expect(renamedReloaded?.folder == "Done/2026", "Folder rename must move the directory atomically")
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("Existing"), withIntermediateDirectories: true)
            do {
                try store.renameFolder(from: "Done", to: "Existing")
                fatalError("A folder rename must not overwrite an existing destination")
            } catch { /* Expected: the destination collision leaves the source untouched. */ }
            let afterCollision = try store.load().first(where: { $0.id == folderNote.id })
            TestSupport.expect(afterCollision?.folder == "Done/2026", "A failed rename must leave the source folder intact")
            let sameTitle = MarkdownNote(id: UUID(), markdown: note.markdown, modified: Date())
            try store.save(sameTitle)
            let afterDuplicate = try store.load()
            TestSupport.expectEqual(afterDuplicate.count, 3)
            try store.delete(sameTitle)
            let afterDelete = try store.load()
            TestSupport.expectEqual(afterDelete.count, 2)
            TestSupport.expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(sameTitle.id.uuidString + ".md").path), "Deleted notes must remove their Markdown file")
            // Titles, including path-like text, never determine a file path.
            let pathTitle = MarkdownNote(id: UUID(), markdown: "# ../../outside", modified: Date())
            try store.save(pathTitle)
            TestSupport.expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(pathTitle.id.uuidString + ".md").path), "UUID filenames must contain titles safely")
            let blockedPath = directory.appendingPathComponent("blocked")
            try Data().write(to: blockedPath)
            do {
                try MarkdownNoteStore(directory: blockedPath).save(note)
                fatalError("A failed save must throw")
            } catch { /* Expected: a regular file cannot be the notes directory. */ }
        } catch { fatalError("Synthetic notes test failed: \(error)") }
    }

    private static func testTextChunking() {
        let chunks = MarkdownNoteStore.splitText("one\n\ntwo\n\nthree\n\nfour", maxCharacters: 7)
        TestSupport.expectEqual(chunks, ["one", "two", "three", "four"])
        TestSupport.expectEqual(MarkdownNoteStore.splitText("short", maxCharacters: 10), ["short"])
        TestSupport.expectEqual(MarkdownNoteStore.splitText("", maxCharacters: 10), [])
        TestSupport.expectEqual(
            MarkdownNoteStore.mergeTranscripts(["We should review the project plan", "project plan tomorrow and share it"]),
            "We should review the project plan tomorrow and share it"
        )
        TestSupport.expectEqual(
            MarkdownNoteStore.mergeTranscripts(["First section", "Second section"]),
            "First section\n\nSecond section"
        )
    }
}
