import Foundation

struct VoiceMacro: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var command: String
    var payload: String
}

final class VoiceMacroMatcher {
    private struct Entry {
        let macro: VoiceMacro
        let normalizedCommand: String
    }

    private var entries: [Entry] = []

    func update(_ macros: [VoiceMacro]) {
        entries = macros.map { macro in
            Entry(macro: macro, normalizedCommand: Self.normalize(macro.command))
        }
    }

    func match(transcript: String) -> VoiceMacro? {
        let normalizedTranscript = Self.normalize(transcript)
        guard !normalizedTranscript.isEmpty else { return nil }
        return entries.first { $0.normalizedCommand == normalizedTranscript }?.macro
    }

    static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.punctuationCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
