import Foundation

enum LocalWhisperTranscriptionServiceTests {
    private final class PreviewTestState: @unchecked Sendable {
        private let lock = NSLock()
        private var transcriptionCount = 0
        private var updates = [String]()
        private var sampleByteCounts = [Int]()

        func nextTranscript(sampleByteCount: Int) -> String {
            lock.withLock {
                transcriptionCount += 1
                sampleByteCounts.append(sampleByteCount)
                return (1...transcriptionCount).map { "chunk \($0)" }.joined(separator: " ")
            }
        }

        func record(_ transcript: String) {
            lock.withLock {
                updates.append(transcript)
            }
        }

        var updateCount: Int {
            lock.withLock { updates.count }
        }

        var recordedUpdates: [String] {
            lock.withLock { updates }
        }

        var recordedSampleByteCounts: [Int] {
            lock.withLock { sampleByteCounts }
        }
    }

    static func run() {
        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?

        Task {
            do {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }

                let executable = directory.appendingPathComponent("mock-whisper")
                try "#!/bin/sh\necho '[00:00:00.000 --> 00:00:01.000] hello from local whisper'\n".write(to: executable, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
                let model = directory.appendingPathComponent("model.bin")
                let audio = directory.appendingPathComponent("audio.wav")
                try Data().write(to: model)
                try Data().write(to: audio)

                let service = try LocalWhisperTranscriptionService(
                    executablePath: executable.path,
                    modelPath: model.path,
                    timeoutSeconds: 5
                )
                let transcript = try await service.transcribe(fileURL: audio)
                TestSupport.expectEqual(transcript, "hello from local whisper")

                let pcm = Data(repeating: 0, count: 8)
                let wav = LocalWhisperTranscriptionService.makeWAVData(pcm16: pcm, sampleRate: 24_000)
                TestSupport.expectEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
                TestSupport.expectEqual(String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE")
                TestSupport.expectEqual(wav.count, 44 + pcm.count)
                let previewTranscript = try await service.transcribePCM16(pcm, sampleRate: 24_000)
                TestSupport.expectEqual(previewTranscript, "hello from local whisper")

                try await verifyPreviewContinuesAcrossChunks()

            } catch {
                failure = error
            }
            semaphore.signal()
        }

        semaphore.wait()
        if let failure { fatalError("Local Whisper test failed: \(failure)") }
    }

    private static func verifyPreviewContinuesAcrossChunks() async throws {
        let state = PreviewTestState()
        let session = LocalWhisperPreviewSession(
            transcribe: { samples, sampleRate in
                TestSupport.expectEqual(sampleRate, 16_000)
                return state.nextTranscript(sampleByteCount: samples.count)
            },
            onUpdate: { transcript in
                state.record(transcript)
            }
        )

        var sample: Int16 = 8_000
        let chunk = Data(bytes: &sample, count: MemoryLayout<Int16>.size)
        let threeSeconds = Data(repeating: chunk[0], count: 16_000 * 3 * MemoryLayout<Int16>.size)
        session.appendPCM16(threeSeconds)

        for _ in 0..<200 where state.updateCount < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        session.appendPCM16(threeSeconds)

        for _ in 0..<200 where state.updateCount < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let twentyOneSeconds = Data(
            repeating: chunk[0],
            count: 16_000 * 21 * MemoryLayout<Int16>.size
        )
        session.appendPCM16(twentyOneSeconds)

        for _ in 0..<200 where state.updateCount < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        session.stop()
        TestSupport.expectEqual(
            state.recordedUpdates,
            ["chunk 1", "chunk 1 chunk 2", "chunk 1 chunk 2 chunk 3"]
        )
        TestSupport.expectEqual(
            state.recordedSampleByteCounts,
            [
                threeSeconds.count,
                threeSeconds.count * 2,
                16_000 * 20 * MemoryLayout<Int16>.size,
            ]
        )
    }
}
