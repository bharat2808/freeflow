import Foundation

@main
struct FreeFlowTests {
    static func main() {
        MarkdownNoteStoreTests.run()
        LocalWhisperTranscriptionServiceTests.run()
        AppContextServiceTests.run()
        ModelConfigurationTests.run()
        ShortcutCoreTests.run()
        SemanticVersionTests.run()
        LLMCooldownManagerTests.run()
        TranscriptionErrorPresentationCoreTests.run()
        TranscriptTextCoreTests.run()
        print("FreeFlowTests passed")
    }
}
