import Foundation

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case prompts
    case macros
    case runLog
    case debug
    case notesConnector

    var id: String { rawValue }

    static var visibleCases: [SettingsTab] {
        allCases.filter { tab in
            tab != .debug || AppBuild.isDevBundle
        }
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .prompts: return "Prompts"
        case .macros: return "Voice Macros"
        case .runLog: return "Run Log"
        case .debug: return "Debug"
        case .notesConnector: return "Notes Connector"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .prompts: return "text.bubble"
        case .macros: return "music.mic"
        case .runLog: return "clock.arrow.circlepath"
        case .debug: return "wrench.and.screwdriver"
        case .notesConnector: return "externaldrive.connected.to.line.below"
        }
    }
}

enum AppBuild {
    static var isDevBundle: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) == "FreeFlow Dev"
    }
}

enum NoteVoiceAction: Sendable, Equatable {
    case update
    case append
}

enum TextActionPreset: String, CaseIterable, Identifiable, Sendable {
    case proofread
    case rewrite
    case friendly
    case professional
    case concise

    var id: String { rawValue }

    var title: String {
        switch self {
        case .proofread: return "Proofread"
        case .rewrite: return "Rewrite"
        case .friendly: return "Friendly"
        case .professional: return "Professional"
        case .concise: return "Concise"
        }
    }

    var icon: String {
        switch self {
        case .proofread: return "text.magnifyingglass"
        case .rewrite: return "pencil.and.outline"
        case .friendly: return "face.smiling"
        case .professional: return "briefcase"
        case .concise: return "arrow.down.left.and.arrow.up.right"
        }
    }

    var instruction: String {
        switch self {
        case .proofread:
            return "Proofread the selected text. Correct grammar, spelling, punctuation, and obvious typos while preserving the meaning, structure, and tone. Return only the corrected text."
        case .rewrite:
            return "Rewrite the selected text for clarity and flow while preserving its meaning and important details. Return only the rewritten text."
        case .friendly:
            return "Rewrite the selected text in a warm, friendly, conversational tone while preserving its meaning and important details. Return only the rewritten text."
        case .professional:
            return "Rewrite the selected text in a clear, polished, professional tone while preserving its meaning and important details. Return only the rewritten text."
        case .concise:
            return "Make the selected text more concise without losing important meaning, facts, or requested actions. Return only the concise version."
        }
    }
}

struct PendingNoteUpdate: Identifiable {
    let id = UUID()
    let noteID: UUID
    let action: NoteVoiceAction
    let markdown: String
}

enum CommandInvocation: String, Sendable {
    case automatic
    case manual
}

enum SessionIntent {
    case dictation
    case generate
    case command(invocation: CommandInvocation, selectedText: String)

    var isCommandMode: Bool {
        switch self {
        case .dictation:
            return false
        case .generate:
            return false
        case .command:
            return true
        }
    }

    var isGenerateMode: Bool {
        if case .generate = self { return true }
        return false
    }

    var persistedIntent: PipelineHistoryItemIntent {
        switch self {
        case .dictation:
            return .dictation
        case .generate:
            return .generate
        case .command(let invocation, _):
            switch invocation {
            case .automatic:
                return .commandAutomatic
            case .manual:
                return .commandManual
            }
        }
    }

    var persistedSelectedText: String? {
        switch self {
        case .dictation, .generate:
            return nil
        case .command(_, let selectedText):
            return selectedText
        }
    }

    var isManualCommand: Bool {
        switch self {
        case .command(invocation: .manual, _):
            return true
        default:
            return false
        }
    }

    static func fromPersisted(intent: PipelineHistoryItemIntent, selectedText: String?) -> SessionIntent {
        if intent == .generate {
            return .generate
        }
        if intent == .commandAutomatic, let selectedText {
            return .command(invocation: .automatic, selectedText: selectedText)
        }
        if intent == .commandManual, let selectedText {
            return .command(invocation: .manual, selectedText: selectedText)
        }
        return .dictation
    }
}
