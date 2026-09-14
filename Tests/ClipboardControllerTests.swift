import AppKit
import Foundation

enum ClipboardControllerTests {
    static func run() {
        testWritingAndRestoringTranscript()
        testNewClipboardContentIsNotOverwritten()
        testTransientClipboardMarkers()
    }

    private static func testWritingAndRestoringTranscript() {
        let pasteboard = makePasteboard()
        pasteboard.setString("Synthetic original", forType: .string)
        let controller = ClipboardController(pasteboard: pasteboard, clipboardRestoreDelay: 0)

        let pendingRestore = controller.writeTranscript(
            "Synthetic dictation.",
            preserveClipboard: true,
            keepInClipboardHistory: true
        )
        TestSupport.expectEqual(pasteboard.string(forType: .string), "Synthetic dictation. ")

        controller.restoreIfNeeded(pendingRestore)
        runMainLoopBriefly()
        TestSupport.expectEqual(pasteboard.string(forType: .string), "Synthetic original")
    }

    private static func testNewClipboardContentIsNotOverwritten() {
        let pasteboard = makePasteboard()
        pasteboard.setString("Synthetic original", forType: .string)
        let controller = ClipboardController(pasteboard: pasteboard, clipboardRestoreDelay: 0)
        let pendingRestore = controller.writeTranscript(
            "Synthetic dictation",
            preserveClipboard: true,
            keepInClipboardHistory: true
        )

        pasteboard.clearContents()
        pasteboard.setString("Synthetic user copy", forType: .string)
        controller.restoreIfNeeded(pendingRestore)
        runMainLoopBriefly()
        TestSupport.expectEqual(pasteboard.string(forType: .string), "Synthetic user copy")
    }

    private static func testTransientClipboardMarkers() {
        let pasteboard = makePasteboard()
        let controller = ClipboardController(pasteboard: pasteboard)
        _ = controller.writeTranscript(
            "Synthetic dictation",
            preserveClipboard: false,
            keepInClipboardHistory: false
        )

        TestSupport.expect(pasteboard.types?.contains(.string) == true, "String type should be declared")
        TestSupport.expect(
            pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) == true,
            "Transient clipboard marker should be declared"
        )
        TestSupport.expect(
            pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true,
            "Concealed clipboard marker should be declared"
        )
    }

    private static func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("FreeFlowTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    private static func runMainLoopBriefly() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    }
}
