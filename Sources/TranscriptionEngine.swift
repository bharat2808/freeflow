import Foundation

enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case remote
    case localWhisper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .remote: return "Remote API"
        case .localWhisper: return "Local Whisper"
        }
    }
}
