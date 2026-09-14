import Foundation

enum RecordingArtifactStoreTests {
    static func run() {
        testArtifactLocationsAndAudioLifecycle()
    }

    private static func testArtifactLocationsAndAudioLifecycle() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FreeFlowTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RecordingArtifactStore(appDirectory: root)
        TestSupport.expectEqual(
            store.audioDirectory.standardizedFileURL,
            root.appendingPathComponent("audio", isDirectory: true).standardizedFileURL
        )
        TestSupport.expectEqual(
            store.recordingStateFlagURL.standardizedFileURL,
            root.appendingPathComponent("is-recording").standardizedFileURL
        )

        let sourceURL = root.appendingPathComponent("synthetic-source.wav")
        let sourceData = Data("synthetic audio fixture".utf8)
        try? sourceData.write(to: sourceURL)

        guard let savedFile = store.saveAudioFile(from: sourceURL) else {
            TestSupport.expect(false, "Expected synthetic audio fixture to be saved")
            return
        }
        TestSupport.expect(savedFile.fileName.hasSuffix(".wav"), "Saved audio should retain WAV extension")
        TestSupport.expectEqual(try? Data(contentsOf: savedFile.fileURL), sourceData)

        store.deleteAudioFile(named: savedFile.fileName)
        TestSupport.expect(
            !FileManager.default.fileExists(atPath: savedFile.fileURL.path),
            "Deleting a saved recording should remove its file"
        )
    }
}
