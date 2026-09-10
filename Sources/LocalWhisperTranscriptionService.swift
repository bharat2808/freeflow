import Foundation

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
        let expanded = (value as NSString).expandingTildeInPath
        if expanded.contains("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }

        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(expanded)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.standardizedFileURL
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
