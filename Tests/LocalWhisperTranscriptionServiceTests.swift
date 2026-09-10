import Foundation

enum LocalWhisperTranscriptionServiceTests {
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

            } catch {
                failure = error
            }
            semaphore.signal()
        }

        semaphore.wait()
        if let failure { fatalError("Local Whisper test failed: \(failure)") }
    }
}
