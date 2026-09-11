import Foundation
import os.lock

enum LocalWhisperModelDownloader {
    static let baseEnglishModelURL = URL(
        string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin?download=true"
    )!

    static var baseEnglishModelPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/whisper/ggml-base.en.bin")
    }

    static func downloadBaseEnglishModel(
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let destination = baseEnglishModelPath
        if FileManager.default.fileExists(atPath: destination.path) {
            progress(1)
            return destination
        }

        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = try await downloadToTemporaryFile(progress: progress)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        progress(1)
        return destination
    }

    private static func downloadToTemporaryFile(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FreeFlowWhisperDownload", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let temporaryURL = temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = ModelDownloadDelegate(
                destinationURL: temporaryURL,
                progress: progress,
                continuation: continuation
            )
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            delegate.session = session
            let task = session.downloadTask(with: baseEnglishModelURL)
            task.resume()
        }
    }
}

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destinationURL: URL
    let progress: @Sendable (Double) -> Void
    let continuation: CheckedContinuation<URL, Error>
    var session: URLSession?
    private var downloadedURL: URL?
    private var downloadError: Error?

    init(
        destinationURL: URL,
        progress: @escaping @Sendable (Double) -> Void,
        continuation: CheckedContinuation<URL, Error>
    ) {
        self.destinationURL = destinationURL
        self.progress = progress
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try FileManager.default.removeItem(at: destinationURL)
        } catch let error as NSError where error.code == NSFileNoSuchFileError {
            // Expected for the first download.
        } catch {
            downloadError = error
            return
        }

        do {
            try FileManager.default.copyItem(at: location, to: destinationURL)
            downloadedURL = destinationURL
        } catch {
            downloadError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.invalidateAndCancel() }
        if let error = error ?? downloadError {
            continuation.resume(throwing: error)
        } else if let downloadedURL {
            continuation.resume(returning: downloadedURL)
        } else {
            continuation.resume(throwing: URLError(.cannotDecodeContentData))
        }
    }
}

enum LocalWhisperError: LocalizedError {
    case executableNotFound(String)
    case modelNotFound(String)
    case processLaunchFailed(String)
    case processFailed(Int32, String)
    case timedOut(TimeInterval)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let path):
            return "Local Whisper executable was not found at \(path). Set the executable path in Settings."
        case .modelNotFound(let path):
            return "Local Whisper model was not found at \(path). Set the model path in Settings."
        case .processLaunchFailed(let message):
            return "Could not start local Whisper: \(message)"
        case .processFailed(let status, let output):
            let detail = output.isEmpty ? "No diagnostic output was returned." : output
            return "Local Whisper exited with status \(status): \(detail)"
        case .timedOut(let seconds):
            return "Local Whisper timed out after \(Int(seconds)) seconds. Try a smaller model or shorter recording."
        case .emptyTranscript:
            return "Local Whisper returned no transcript."
        }
    }
}

final class LocalWhisperTranscriptionService: AudioTranscriber {
    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?

        func set(_ process: Process) {
            lock.lock()
            self.process = process
            lock.unlock()
        }

        func terminate() {
            lock.lock()
            let process = self.process
            lock.unlock()
            guard let process, process.isRunning else { return }
            process.terminate()
        }
    }

    private let executableURL: URL
    private let modelURL: URL
    private let language: String?
    private let timeoutSeconds: TimeInterval

    init(
        executablePath: String,
        modelPath: String,
        language: String? = nil,
        timeoutSeconds: TimeInterval = 120
    ) throws {
        let executable = Self.resolvePath(executablePath)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LocalWhisperError.executableNotFound(executable.path)
        }

        let model = Self.resolvePath(modelPath)
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw LocalWhisperError.modelNotFound(model.path)
        }

        self.executableURL = executable
        self.modelURL = model
        let trimmedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = (trimmedLanguage?.isEmpty == false) ? trimmedLanguage : nil
        self.timeoutSeconds = max(1, timeoutSeconds)
    }

    func transcribe(fileURL: URL) async throws -> String {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let processBox = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { [self] in
                    try await self.runProcess(fileURL: fileURL, processBox: processBox)
                }
                group.addTask { [timeoutSeconds] in
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    throw LocalWhisperError.timedOut(timeoutSeconds)
                }
                defer { group.cancelAll() }
                do {
                    guard let result = try await group.next() else {
                        throw LocalWhisperError.emptyTranscript
                    }
                    return result
                } catch {
                    processBox.terminate()
                    throw error
                }
            }
        } onCancel: {
            processBox.terminate()
        }
    }

    /// Transcribes a short in-memory PCM16 snapshot. AudioRecorder emits
    /// 24 kHz mono PCM16 for realtime consumers, so the snapshot is wrapped
    /// in a minimal WAV container before invoking whisper-cli.
    func transcribePCM16(_ samples: Data, sampleRate: Int = 24_000) async throws -> String {
        guard !samples.isEmpty else { throw LocalWhisperError.emptyTranscript }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("freeflow-whisper-preview-\(UUID().uuidString).wav")
        try Self.makeWAVData(pcm16: samples, sampleRate: sampleRate).write(to: temporaryURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        return try await transcribe(fileURL: temporaryURL)
    }

    func makeLivePreviewSession(
        onUpdate: @escaping @Sendable (String) -> Void
    ) -> LocalWhisperPreviewSession {
        LocalWhisperPreviewSession(transcriber: self, onUpdate: onUpdate)
    }

    static func makeWAVData(pcm16: Data, sampleRate: Int) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = UInt32(bitsPerSample / 8)
        let byteRate = UInt32(sampleRate) * UInt32(channels) * bytesPerSample
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(min(UInt64(pcm16.count), UInt64(UInt32.max)))

        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.appendLittleEndian(UInt32(36) &+ dataSize)
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        wav.appendLittleEndian(UInt32(16)) // PCM fmt chunk size
        wav.appendLittleEndian(UInt16(1)) // PCM format
        wav.appendLittleEndian(channels)
        wav.appendLittleEndian(UInt32(sampleRate))
        wav.appendLittleEndian(byteRate)
        wav.appendLittleEndian(blockAlign)
        wav.appendLittleEndian(bitsPerSample)
        wav.append(contentsOf: Array("data".utf8))
        wav.appendLittleEndian(dataSize)
        wav.append(pcm16.prefix(Int(dataSize)))
        return wav
    }

    private func runProcess(fileURL: URL, processBox: ProcessBox) async throws -> String {
        try Task.checkCancellation()

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments(for: fileURL)
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        processBox.set(process)

        do {
            try process.run()
        } catch {
            throw LocalWhisperError.processLaunchFailed(error.localizedDescription)
        }

        while process.isRunning {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw LocalWhisperError.processFailed(process.terminationStatus, cleanDiagnosticOutput(output))
        }

        let transcript = Self.cleanTranscript(output)
        guard !transcript.isEmpty else { throw LocalWhisperError.emptyTranscript }
        return transcript
    }

    private func arguments(for fileURL: URL) -> [String] {
        var arguments = ["-m", modelURL.path, "-f", fileURL.path, "-nt", "-np"]
        if let language { arguments += ["-l", language] }
        return arguments
    }

    private static func resolvePath(_ value: String) -> URL {
        let requested = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (requested as NSString).expandingTildeInPath
        if expanded.contains("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }

        // Finder-launched apps often receive a reduced PATH that omits
        // Homebrew. Keep PATH support for custom installs, then search the
        // standard macOS/Homebrew locations explicitly.
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let searchDirectories = environmentPath.split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let names = expanded.isEmpty ? ["whisper-cli", "whisper-cpp"] : [expanded]
        for name in names {
            for directory in Set(searchDirectories) {
                let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate.standardizedFileURL
                }
            }
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    private static func cleanTranscript(_ output: String) -> String {
        output
            .components(separatedBy: .newlines)
            .map { line in
                line.replacingOccurrences(
                    of: #"^\s*\[\d{2}:\d{2}:\d{2}\.\d{3}\s*-->\s*\d{2}:\d{2}:\d{2}\.\d{3}\]\s*"#,
                    with: "",
                    options: .regularExpression
                )
            }
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && !trimmed.hasPrefix("whisper_") && !trimmed.hasPrefix("main:")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanDiagnosticOutput(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 240 else { return trimmed }
        return String(trimmed.prefix(239)) + "…"
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}

/// Incremental local Whisper preview used while a note is still recording.
/// It deliberately treats each result as provisional: the complete recording
/// is transcribed again after stop, so preview latency never changes the
/// authoritative note contents.
final class LocalWhisperPreviewSession: @unchecked Sendable {
    private let transcriber: LocalWhisperTranscriptionService
    private let onUpdate: @Sendable (String) -> Void
    private let stateLock = OSAllocatedUnfairLock(initialState: ())
    private var audio = Data()
    private var totalBytesReceived = 0
    private var lastSubmittedTotalBytes = 0
    private var processing = false
    private var pending = false
    private var stopped = false
    private var workerTask: Task<Void, Never>?

    private let sampleRate = 24_000
    private let processEveryFrames = 24_000 * 3
    private let maxPreviewFrames = 24_000 * 45

    init(
        transcriber: LocalWhisperTranscriptionService,
        onUpdate: @escaping @Sendable (String) -> Void
    ) {
        self.transcriber = transcriber
        self.onUpdate = onUpdate
    }

    func appendPCM16(_ samples: Data) {
        guard !samples.isEmpty else { return }
        let snapshot: Data? = stateLock.withLock {
            guard !stopped else { return nil }
            audio.append(samples)
            totalBytesReceived += samples.count
            let bytesPerFrame = MemoryLayout<Int16>.size
            let maxBytes = maxPreviewFrames * bytesPerFrame
            if audio.count > maxBytes {
                audio.removeFirst(audio.count - maxBytes)
            }
            let minimumBytes = processEveryFrames * bytesPerFrame
            let hasNewAudio = totalBytesReceived - lastSubmittedTotalBytes >= minimumBytes
            let shouldProcess = audio.count >= minimumBytes && hasNewAudio
                && !processing
            if shouldProcess {
                processing = true
                lastSubmittedTotalBytes = totalBytesReceived
                return audio
            }
            if processing && hasNewAudio { pending = true }
            return nil
        }

        guard let snapshot else { return }
        workerTask = Task { [weak self] in
            await self?.process(snapshot)
        }
    }

    func stop() {
        stateLock.withLock {
            stopped = true
            pending = false
            workerTask?.cancel()
            workerTask = nil
        }
    }

    private func process(_ snapshot: Data) async {
        do {
            let transcript = try await transcriber.transcribePCM16(snapshot, sampleRate: sampleRate)
            try Task.checkCancellation()
            if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onUpdate(transcript)
            }
        } catch is CancellationError {
            // Recording cancellation is expected and should not surface as an error.
        } catch {
            // Preview failures are non-fatal; the final stop-time transcription
            // still reports actionable errors to the user.
        }

        let nextSnapshot: Data? = stateLock.withLock {
            if stopped {
                processing = false
                return nil
            }
            let minimumBytes = processEveryFrames * MemoryLayout<Int16>.size
            if pending,
               audio.count >= minimumBytes,
               totalBytesReceived - lastSubmittedTotalBytes >= minimumBytes {
                pending = false
                lastSubmittedTotalBytes = totalBytesReceived
                return audio
            }
            processing = false
            return nil
        }

        if let nextSnapshot {
            workerTask = Task { [weak self] in
                await self?.process(nextSnapshot)
            }
        }
    }
}
