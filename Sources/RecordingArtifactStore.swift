import Foundation
import os.log

private let recordingArtifactLog = OSLog(
    subsystem: "com.zachlatta.freeflow",
    category: "RecordingArtifacts"
)

struct SavedRecordingAudioFile {
    let fileName: String
    let fileURL: URL
}

final class RecordingArtifactStore {
    static let shared = RecordingArtifactStore()

    private let appDirectory: URL
    private let fileManager: FileManager
    private let flagQueue = DispatchQueue(
        label: "com.zachlatta.freeflow.recording-state-flag"
    )

    init(
        appDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.appDirectory = appDirectory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppName.displayName, isDirectory: true)
    }

    var audioDirectory: URL {
        let directory = appDirectory.appendingPathComponent("audio", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    var recordingStateFlagURL: URL {
        appDirectory.appendingPathComponent("is-recording")
    }

    func writeRecordingStateFlag(_ recording: Bool) {
        let timestamp = recording ? String(Date().timeIntervalSince1970) : nil
        let flagURL = recordingStateFlagURL
        flagQueue.async { [fileManager] in
            if let timestamp {
                let directory = flagURL.deletingLastPathComponent()
                try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try? timestamp.write(to: flagURL, atomically: true, encoding: .utf8)
            } else {
                try? fileManager.removeItem(at: flagURL)
            }
        }
    }

    func saveAudioFile(from temporaryURL: URL) -> SavedRecordingAudioFile? {
        let fileName = UUID().uuidString + ".wav"
        let destinationURL = audioDirectory.appendingPathComponent(fileName)
        do {
            try fileManager.copyItem(at: temporaryURL, to: destinationURL)
            return SavedRecordingAudioFile(fileName: fileName, fileURL: destinationURL)
        } catch {
            os_log(
                .error,
                log: recordingArtifactLog,
                "failed to persist audio file %{public}@ : %{public}@",
                fileName,
                error.localizedDescription
            )
            return nil
        }
    }

    func deleteAudioFile(named fileName: String) {
        let fileURL = audioDirectory.appendingPathComponent(fileName)
        try? fileManager.removeItem(at: fileURL)
    }
}
