#!/usr/bin/env swift

import Foundation

struct CompilationCommand: Encodable {
    let directory: String
    let file: String
    let arguments: [String]
}

enum GeneratorError: Error, CustomStringConvertible {
    case commandFailed(String)
    case noSources

    var description: String {
        switch self {
        case .commandFailed(let command):
            return "Command failed: \(command)"
        case .noSources:
            return "No Swift sources were found under Sources."
        }
    }
}

func output(of executable: String, arguments: [String]) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw GeneratorError.commandFailed(([executable] + arguments).joined(separator: " "))
    }
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

do {
    let fileManager = FileManager.default
    let root = URL(fileURLWithPath: fileManager.currentDirectoryPath).standardizedFileURL
    let sourcesRoot = root.appendingPathComponent("Sources", isDirectory: true)
    guard let enumerator = fileManager.enumerator(
        at: sourcesRoot,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) else {
        throw GeneratorError.noSources
    }

    let sources = enumerator.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }
        .map(\.standardizedFileURL)
        .sorted { $0.path < $1.path }
    guard !sources.isEmpty else { throw GeneratorError.noSources }

    let sdkPath = try output(of: "/usr/bin/xcrun", arguments: ["--show-sdk-path"])
    let swiftCompiler = try output(of: "/usr/bin/xcrun", arguments: ["--find", "swiftc"])
    let architecture = try output(of: "/usr/bin/uname", arguments: ["-m"])
    let modulePath = root
        .appendingPathComponent(".build/\(architecture)-apple-macosx/debug/Modules")
        .path
    let sourcePaths = sources.map(\.path)
    let commonArguments = [
        swiftCompiler,
        "-parse-as-library",
        "-typecheck",
        "-sdk", sdkPath,
        "-target", "\(architecture)-apple-macosx13.0",
        "-I", modulePath
    ] + sourcePaths

    let commands = sources.map { source in
        CompilationCommand(
            directory: root.path,
            file: source.path,
            arguments: commonArguments
        )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(commands)
    try data.write(to: root.appendingPathComponent("compile_commands.json"), options: .atomic)
    print("Generated compile_commands.json for \(sources.count) Swift files.")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
