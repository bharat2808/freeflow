import Foundation
import Combine
import AppKit
import AVFoundation
import ServiceManagement
import ApplicationServices
import ScreenCaptureKit
import os.log
private let recordingLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "Recording")

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case prompts
    case macros
    case runLog
    case debug

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
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .prompts: return "text.bubble"
        case .macros: return "music.mic"
        case .runLog: return "clock.arrow.circlepath"
        case .debug: return "wrench.and.screwdriver"
        }
    }
}

enum AppBuild {
    static var isDevBundle: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) == "FreeFlow Dev"
    }
}

fileprivate struct NoteFormattingResult: Sendable {
    let finalTranscript: String
    let outcome: TranscriptProcessingOutcome
    let prompt: String
}

private enum NoteProcessingRaceResult: Sendable {
    case completed(finalTranscript: String, outcome: TranscriptProcessingOutcome, prompt: String)
    case timedOut
}

enum NoteVoiceAction: Sendable, Equatable {
    case update
    case append
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
    case command(invocation: CommandInvocation, selectedText: String)

    var isCommandMode: Bool {
        switch self {
        case .dictation:
            return false
        case .command:
            return true
        }
    }

    var persistedIntent: PipelineHistoryItemIntent {
        switch self {
        case .dictation:
            return .dictation
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
        case .dictation:
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
        if intent == .commandAutomatic, let selectedText {
            return .command(invocation: .automatic, selectedText: selectedText)
        }
        if intent == .commandManual, let selectedText {
            return .command(invocation: .manual, selectedText: selectedText)
        }
        return .dictation
    }
}

final class AppState: ObservableObject, @unchecked Sendable {
    private enum ActiveAudioInterruption {
        case muted(previouslyMuted: Bool)
    }

    private let apiKeyStorageKey = "groq_api_key"
    private let apiBaseURLStorageKey = "api_base_url"
    private let transcriptionModelStorageKey = "transcription_model"
    private let transcriptionEngineStorageKey = "transcription_engine"
    private let localWhisperExecutablePathStorageKey = "local_whisper_executable_path"
    private let localWhisperModelPathStorageKey = "local_whisper_model_path"
    private let transcriptionAPIURLStorageKey = "transcription_api_url"
    private let transcriptionAPIKeyStorageKey = "transcription_api_key"
    private let postProcessingModelStorageKey = "post_processing_model"
    private let postProcessingFallbackModelStorageKey = "post_processing_fallback_model"
    private let contextModelStorageKey = "context_model"
    private let holdShortcutStorageKey = "hold_shortcut"
    private let toggleShortcutStorageKey = "toggle_shortcut"
    private let copyAgainShortcutStorageKey = "copy_again_shortcut"
    private let savedHoldCustomShortcutStorageKey = "saved_hold_custom_shortcut"
    private let savedToggleCustomShortcutStorageKey = "saved_toggle_custom_shortcut"
    private let savedCopyAgainCustomShortcutStorageKey = "saved_copy_again_custom_shortcut"
    private let customVocabularyStorageKey = "custom_vocabulary"
    private let transcriptionLanguageStorageKey = "transcription_language"
    private let selectedMicrophoneStorageKey = "selected_microphone_id"
    private let customSystemPromptStorageKey = "custom_system_prompt"
    private let noteSystemPromptStorageKey = "note_system_prompt"
    private let customContextPromptStorageKey = "custom_context_prompt"
    private let instructionExecutionGuardEnabledStorageKey = "instruction_execution_guard_enabled"
    private let customSystemPromptLastModifiedStorageKey = "custom_system_prompt_last_modified"
    private let customContextPromptLastModifiedStorageKey = "custom_context_prompt_last_modified"
    private let contextScreenshotMaxDimensionStorageKey = "context_screenshot_max_dimension"
    private let shortcutStartDelayStorageKey = "shortcut_start_delay"
    private let preserveClipboardStorageKey = "preserve_clipboard"
    private let preserveExactWordingStorageKey = "preserve_exact_wording"
    private let keepDictationInClipboardHistoryStorageKey = "keep_dictation_in_clipboard_history"
    private let pressEnterVoiceCommandStorageKey = "press_enter_voice_command_enabled"
    private let alertSoundsEnabledStorageKey = "alert_sounds_enabled"
    private let soundVolumeStorageKey = "sound_volume"
    private let voiceMacrosStorageKey = "voice_macros"
    private let commandModeEnabledStorageKey = "command_mode_enabled"
    private let commandModeStyleStorageKey = "command_mode_style"
    private let commandModeManualModifierStorageKey = "command_mode_manual_modifier"
    private let outputLanguageStorageKey = "output_language"
    private let realtimeStreamingEnabledStorageKey = "realtime_streaming_enabled"
    private let realtimeStreamingModelStorageKey = "realtime_streaming_model"
    private let dictationAudioInterruptionEnabledStorageKey = "dictation_audio_interruption_enabled"
    let maxPipelineHistoryCount = 20
    static let defaultContextScreenshotMaxDimension = Int(AppContextService.defaultScreenshotMaxDimension)
    static let contextScreenshotDimensionOptions = [1024, 768, 640, 512]
    static let defaultTranscriptionModel = "whisper-large-v3"
    static let defaultLocalWhisperExecutablePath = "whisper-cli"
    static var defaultLocalWhisperModelPath: String {
        let cacheModel = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/whisper/ggml-base.en.bin")
        return FileManager.default.fileExists(atPath: cacheModel.path) ? cacheModel.path : ""
    }
    static let transcriptionLanguageOptions: [(code: String, name: String)] = [
        ("", "Auto-detect"),
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("ru", "Russian"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh", "Chinese"),
        ("ar", "Arabic"),
        ("hi", "Hindi"),
        ("tr", "Turkish"),
        ("pl", "Polish"),
        ("uk", "Ukrainian"),
        ("sv", "Swedish"),
        ("no", "Norwegian"),
        ("da", "Danish"),
        ("fi", "Finnish"),
        ("cs", "Czech"),
        ("el", "Greek"),
        ("he", "Hebrew"),
        ("vi", "Vietnamese"),
        ("th", "Thai"),
        ("id", "Indonesian"),
        ("ro", "Romanian"),
        ("hu", "Hungarian"),
        ("ca", "Catalan")
    ]
    static let defaultPostProcessingModel = "openai/gpt-oss-20b"
    static let defaultPostProcessingFallbackModel = "qwen/qwen3.6-27b"
    static let defaultContextModel = "qwen/qwen3.6-27b"
    static let noteProcessingTimeoutSeconds: TimeInterval = 120
    static let notePreviewTimeoutSeconds: TimeInterval = 20
    static var noteProcessingOverallTimeoutSeconds: TimeInterval {
        let override = UserDefaults.standard.double(forKey: "note_processing_total_timeout_seconds")
        return override > 0 ? override : 90
    }
    @Published var hasCompletedSetup: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedSetup, forKey: "hasCompletedSetup")
        }
    }

    @Published var apiKey: String {
        didSet {
            persistAPIKey(apiKey)
            rebuildContextService()
        }
    }

    @Published var apiBaseURL: String {
        didSet {
            persistAPIBaseURL(apiBaseURL)
            rebuildContextService()
        }
    }

    @Published var transcriptionAPIURL: String {
        didSet {
            persistOptionalAPIValue(transcriptionAPIURL, account: transcriptionAPIURLStorageKey)
        }
    }

    @Published var transcriptionAPIKey: String {
        didSet {
            persistOptionalAPIValue(transcriptionAPIKey, account: transcriptionAPIKeyStorageKey)
        }
    }

    @Published var transcriptionModel: String {
        didSet {
            UserDefaults.standard.set(transcriptionModel, forKey: transcriptionModelStorageKey)
        }
    }

    @Published var transcriptionEngine: TranscriptionEngine {
        didSet {
            UserDefaults.standard.set(transcriptionEngine.rawValue, forKey: transcriptionEngineStorageKey)
            if transcriptionEngine == .localWhisper {
                realtimeStreamingEnabled = false
            }
        }
    }

    @Published var localWhisperExecutablePath: String {
        didSet { UserDefaults.standard.set(localWhisperExecutablePath, forKey: localWhisperExecutablePathStorageKey) }
    }

    @Published var localWhisperModelPath: String {
        didSet { UserDefaults.standard.set(localWhisperModelPath, forKey: localWhisperModelPathStorageKey) }
    }

    @Published var postProcessingModel: String {
        didSet {
            UserDefaults.standard.set(postProcessingModel, forKey: postProcessingModelStorageKey)
        }
    }

    @Published var postProcessingFallbackModel: String {
        didSet {
            UserDefaults.standard.set(postProcessingFallbackModel, forKey: postProcessingFallbackModelStorageKey)
        }
    }

    @Published var contextModel: String {
        didSet {
            UserDefaults.standard.set(contextModel, forKey: contextModelStorageKey)
            rebuildContextService()
        }
    }

    @Published var holdShortcut: ShortcutBinding {
        didSet {
            persistShortcut(holdShortcut, key: holdShortcutStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var toggleShortcut: ShortcutBinding {
        didSet {
            persistShortcut(toggleShortcut, key: toggleShortcutStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var copyAgainShortcut: ShortcutBinding {
        didSet {
            persistShortcut(copyAgainShortcut, key: copyAgainShortcutStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var savedHoldCustomShortcut: ShortcutBinding? {
        didSet {
            persistOptionalShortcut(savedHoldCustomShortcut, key: savedHoldCustomShortcutStorageKey)
        }
    }

    @Published var savedToggleCustomShortcut: ShortcutBinding? {
        didSet {
            persistOptionalShortcut(savedToggleCustomShortcut, key: savedToggleCustomShortcutStorageKey)
        }
    }

    @Published var savedCopyAgainCustomShortcut: ShortcutBinding? {
        didSet {
            persistOptionalShortcut(savedCopyAgainCustomShortcut, key: savedCopyAgainCustomShortcutStorageKey)
        }
    }

    @Published var isCommandModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isCommandModeEnabled, forKey: commandModeEnabledStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var commandModeStyle: CommandModeStyle {
        didSet {
            UserDefaults.standard.set(commandModeStyle.rawValue, forKey: commandModeStyleStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var commandModeManualModifier: CommandModeManualModifier {
        didSet {
            UserDefaults.standard.set(commandModeManualModifier.rawValue, forKey: commandModeManualModifierStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var customVocabulary: String {
        didSet {
            UserDefaults.standard.set(customVocabulary, forKey: customVocabularyStorageKey)
        }
    }

    @Published var transcriptionLanguage: String {
        didSet {
            let normalized = AppSettingsLoader.normalizeTranscriptionLanguage(transcriptionLanguage)
            if normalized != transcriptionLanguage {
                transcriptionLanguage = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: transcriptionLanguageStorageKey)
        }
    }

    @Published var customSystemPrompt: String {
        didSet {
            UserDefaults.standard.set(customSystemPrompt, forKey: customSystemPromptStorageKey)
        }
    }

    @Published var noteSystemPrompt: String {
        didSet {
            UserDefaults.standard.set(noteSystemPrompt, forKey: noteSystemPromptStorageKey)
        }
    }

    @Published var customContextPrompt: String {
        didSet {
            UserDefaults.standard.set(customContextPrompt, forKey: customContextPromptStorageKey)
            rebuildContextService()
        }
    }

    @Published var instructionExecutionGuardEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                instructionExecutionGuardEnabled,
                forKey: instructionExecutionGuardEnabledStorageKey
            )
        }
    }

    @Published var contextScreenshotMaxDimension: Int {
        didSet {
            let normalizedDimension = Self.normalizedContextScreenshotMaxDimension(contextScreenshotMaxDimension)
            if normalizedDimension != contextScreenshotMaxDimension {
                contextScreenshotMaxDimension = normalizedDimension
            }
            UserDefaults.standard.set(contextScreenshotMaxDimension, forKey: contextScreenshotMaxDimensionStorageKey)
            rebuildContextService()
        }
    }

    @Published var customSystemPromptLastModified: String {
        didSet {
            UserDefaults.standard.set(customSystemPromptLastModified, forKey: customSystemPromptLastModifiedStorageKey)
        }
    }

    @Published var customContextPromptLastModified: String {
        didSet {
            UserDefaults.standard.set(customContextPromptLastModified, forKey: customContextPromptLastModifiedStorageKey)
        }
    }

    @Published var outputLanguage: String {
        didSet {
            UserDefaults.standard.set(outputLanguage, forKey: outputLanguageStorageKey)
        }
    }

    @Published var shortcutStartDelay: TimeInterval {
        didSet {
            UserDefaults.standard.set(shortcutStartDelay, forKey: shortcutStartDelayStorageKey)
        }
    }

    /// Stream audio to the transcription backend during recording via the
    /// OpenAI Realtime WebSocket. Reduces wall-clock latency between "stop"
    /// and text-ready because most of the transcription work happens while
    /// the user is still speaking.
    @Published var realtimeStreamingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(realtimeStreamingEnabled, forKey: realtimeStreamingEnabledStorageKey)
        }
    }

    /// Model ID the realtime WebSocket should transcribe with. Empty means
    /// "use the server's default".
    @Published var realtimeStreamingModel: String {
        didSet {
            UserDefaults.standard.set(realtimeStreamingModel, forKey: realtimeStreamingModelStorageKey)
        }
    }

    @Published var dictationAudioInterruptionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                dictationAudioInterruptionEnabled,
                forKey: dictationAudioInterruptionEnabledStorageKey
            )
        }
    }

    @Published var preserveClipboard: Bool {
        didSet {
            UserDefaults.standard.set(preserveClipboard, forKey: preserveClipboardStorageKey)
        }
    }

    @Published var preserveExactWording: Bool {
        didSet {
            UserDefaults.standard.set(preserveExactWording, forKey: preserveExactWordingStorageKey)
        }
    }

    @Published var keepDictationInClipboardHistory: Bool {
        didSet {
            UserDefaults.standard.set(keepDictationInClipboardHistory, forKey: keepDictationInClipboardHistoryStorageKey)
        }
    }

    @Published var isPressEnterVoiceCommandEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isPressEnterVoiceCommandEnabled, forKey: pressEnterVoiceCommandStorageKey)
        }
    }

    @Published var alertSoundsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(alertSoundsEnabled, forKey: alertSoundsEnabledStorageKey)
        }
    }

    @Published var soundVolume: Float {
        didSet {
            UserDefaults.standard.set(soundVolume, forKey: soundVolumeStorageKey)
        }
    }

    private let macroMatcher = VoiceMacroMatcher()

    @Published var voiceMacros: [VoiceMacro] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(voiceMacros) {
                UserDefaults.standard.set(data, forKey: voiceMacrosStorageKey)
            }
            macroMatcher.update(voiceMacros)
        }
    }

    @Published var isRecording = false {
        didSet {
            guard oldValue != isRecording else { return }
            AppState.writeRecordingStateFlag(isRecording)
        }
    }
    @Published var isTranscribing = false
    @Published var retryingItemIDs: Set<UUID> = []
    @Published var lastTranscript: String = ""
    @Published var errorMessage: String?
    @Published var statusText: String = "Ready"
    @Published var hasAccessibility = false
    @Published var hotkeyMonitoringErrorMessage: String?
    @Published var isDebugOverlayActive = false
    @Published var selectedSettingsTab: SettingsTab? = .general
    @Published var pipelineHistory: [PipelineHistoryItem] = []
    @Published var debugStatusMessage = "Idle"
    @Published var debugShowsUpdateReminderAfterDictation = false
    @Published var lastRawTranscript = ""
    @Published var lastPostProcessedTranscript = ""
    @Published var lastPostProcessingPrompt = ""
    @Published var lastContextSummary = ""
    @Published var lastPostProcessingStatus = ""
    @Published var lastContextScreenshotDataURL: String? = nil
    @Published var lastContextScreenshotStatus = "No screenshot"
    @Published var lastContextAppName: String = ""
    @Published var lastContextBundleIdentifier: String = ""
    @Published var lastContextWindowTitle: String = ""
    @Published var lastContextSelectedText: String = ""
    @Published var lastContextLLMPrompt: String = ""
    @Published var liveNoteTranscript: String = ""
    @Published var noteUpdateTargetID: UUID?
    @Published var noteVoiceAction: NoteVoiceAction?
    @Published var pendingNoteUpdate: PendingNoteUpdate?
    @Published var hasScreenRecordingPermission = false
    @Published var launchAtLogin: Bool {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }

    @Published var selectedMicrophoneID: String {
        didSet {
            UserDefaults.standard.set(selectedMicrophoneID, forKey: selectedMicrophoneStorageKey)
        }
    }
    @Published var availableMicrophones: [AudioDevice] = []

    let audioRecorder = AudioRecorder()
    let hotkeyManager = HotkeyManager()
    let overlayManager = RecordingOverlayManager()
    private let clipboardController = ClipboardController()
    var accessibilityTimer: Timer?
    var audioLevelCancellable: AnyCancellable?
    private var debugOverlayTimer: Timer?
    private var recordingInitializationTimer: DispatchSourceTimer?
    private var transcriptionTask: Task<Void, Never>?
    private var transcribingAudioFileName: String?
    var contextService: AppContextService
    var contextCaptureTask: Task<AppContext?, Never>?
    var capturedContext: AppContext?
    var hasShownScreenshotPermissionAlert = false
    private var hasPresentedAutomaticAccessibilityAlert = false
    var audioDeviceObservers: [NSObjectProtocol] = []
    var needsMicrophoneRefreshAfterRecording = false
    private let pipelineHistoryStore = PipelineHistoryStore()
    let shortcutSessionController = DictationShortcutSessionController()
    var activeRecordingTriggerMode: RecordingTriggerMode?
    var currentSessionIntent: SessionIntent = .dictation
    private var pendingSelectionSnapshot: AppSelectionSnapshot?
    private var pendingManualCommandInvocation = false
    private var pendingNoteRecording = false
    private var activeNoteRecording = false
    private var activeNewNoteID: UUID?
    private var activeNoteUpdateTargetID: UUID?
    private var activeNoteUpdateAction: NoteVoiceAction?
    private var pendingShortcutStartTask: Task<Void, Never>?
    var pendingShortcutStartMode: RecordingTriggerMode?
    var realtimeService: RealtimeTranscriptionService?
    var localPreviewService: LocalWhisperPreviewSession?
    private var automaticTerminationDisabled = false
    private var activeAudioInterruption: ActiveAudioInterruption?
    private var pendingOverlayDismissToken: UUID?
    var shouldMonitorHotkeys = false
    var isCapturingShortcut = false
    var isAwaitingMicrophonePermission = false
    private var pendingMicrophonePermissionTriggerMode: RecordingTriggerMode?
    private var pendingMicrophonePermissionSelectionSnapshot: AppSelectionSnapshot?
    private var pendingMicrophonePermissionManualCommandRequested: Bool?
    private let postTranscriptionUpdateReminderDuration: TimeInterval = 7

    init() {
        UserDefaults.standard.removeObject(forKey: "force_http2_transcription")
        let hasCompletedSetup = UserDefaults.standard.bool(forKey: "hasCompletedSetup")
        let apiKey = AppSettingsLoader.loadStoredAPIKey(account: apiKeyStorageKey)
        let apiBaseURL = AppSettingsLoader.loadStoredAPIBaseURL(account: "api_base_url")
        let transcriptionModel = UserDefaults.standard.string(forKey: transcriptionModelStorageKey) ?? Self.defaultTranscriptionModel
        let transcriptionEngine = TranscriptionEngine(
            rawValue: UserDefaults.standard.string(forKey: transcriptionEngineStorageKey) ?? ""
        ) ?? .remote
        let localWhisperExecutablePath = UserDefaults.standard.string(forKey: localWhisperExecutablePathStorageKey)
            ?? Self.defaultLocalWhisperExecutablePath
        let localWhisperModelPath = UserDefaults.standard.string(forKey: localWhisperModelPathStorageKey)
            ?? Self.defaultLocalWhisperModelPath
        let transcriptionAPIURL = AppSettingsLoader.loadOptionalStoredAPIValue(account: transcriptionAPIURLStorageKey)
        let transcriptionAPIKey = AppSettingsLoader.loadStoredAPIKey(account: transcriptionAPIKeyStorageKey)
        let postProcessingModel = UserDefaults.standard.string(forKey: postProcessingModelStorageKey) ?? Self.defaultPostProcessingModel
        let postProcessingFallbackModel = AppSettingsLoader.loadStoredPostProcessingFallbackModel(
            key: postProcessingFallbackModelStorageKey
        )
        let contextModel = AppSettingsLoader.loadStoredContextModel(key: contextModelStorageKey)
        let shortcuts = AppSettingsLoader.loadShortcutConfiguration(
            holdKey: holdShortcutStorageKey,
            toggleKey: toggleShortcutStorageKey,
            copyAgainKey: copyAgainShortcutStorageKey
        )
        let savedHoldCustomShortcut = AppSettingsLoader.loadSavedCustomShortcut(
            forKey: savedHoldCustomShortcutStorageKey,
            fallback: shortcuts.hold.isCustom ? shortcuts.hold : nil
        )
        let savedToggleCustomShortcut = AppSettingsLoader.loadSavedCustomShortcut(
            forKey: savedToggleCustomShortcutStorageKey,
            fallback: shortcuts.toggle.isCustom ? shortcuts.toggle : nil
        )
        let savedCopyAgainCustomShortcut = AppSettingsLoader.loadSavedCustomShortcut(
            forKey: savedCopyAgainCustomShortcutStorageKey,
            fallback: shortcuts.copyAgain.isCustom ? shortcuts.copyAgain : nil
        )
        let customVocabulary = UserDefaults.standard.string(forKey: customVocabularyStorageKey) ?? ""
        let transcriptionLanguage = AppSettingsLoader.normalizeTranscriptionLanguage(
            UserDefaults.standard.string(forKey: transcriptionLanguageStorageKey) ?? ""
        )
        let customSystemPrompt = UserDefaults.standard.string(forKey: customSystemPromptStorageKey) ?? ""
        let noteSystemPrompt = UserDefaults.standard.string(forKey: noteSystemPromptStorageKey) ?? ""
        let customContextPrompt = UserDefaults.standard.string(forKey: customContextPromptStorageKey) ?? ""
        let instructionExecutionGuardEnabled = UserDefaults.standard.object(
            forKey: instructionExecutionGuardEnabledStorageKey
        ) == nil
            ? true
            : UserDefaults.standard.bool(forKey: instructionExecutionGuardEnabledStorageKey)
        let customSystemPromptLastModified = UserDefaults.standard.string(forKey: customSystemPromptLastModifiedStorageKey) ?? ""
        let customContextPromptLastModified = UserDefaults.standard.string(forKey: customContextPromptLastModifiedStorageKey) ?? ""
        let outputLanguage = UserDefaults.standard.string(forKey: outputLanguageStorageKey) ?? ""
        let storedContextScreenshotMaxDimension = UserDefaults.standard.object(forKey: contextScreenshotMaxDimensionStorageKey) != nil
            ? UserDefaults.standard.integer(forKey: contextScreenshotMaxDimensionStorageKey)
            : Self.defaultContextScreenshotMaxDimension
        let contextScreenshotMaxDimension = Self.normalizedContextScreenshotMaxDimension(storedContextScreenshotMaxDimension)
        let shortcutStartDelay = max(0, UserDefaults.standard.double(forKey: shortcutStartDelayStorageKey))
        let isCommandModeEnabled = UserDefaults.standard.object(forKey: commandModeEnabledStorageKey) == nil
            ? false
            : UserDefaults.standard.bool(forKey: commandModeEnabledStorageKey)
        let commandModeStyle = CommandModeStyle(
            rawValue: UserDefaults.standard.string(forKey: commandModeStyleStorageKey) ?? ""
        ) ?? .automatic
        let commandModeManualModifier = CommandModeManualModifier(
            rawValue: UserDefaults.standard.string(forKey: commandModeManualModifierStorageKey) ?? ""
        ) ?? .option
        let preserveClipboard = UserDefaults.standard.object(forKey: preserveClipboardStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: preserveClipboardStorageKey)
        let preserveExactWording = UserDefaults.standard.bool(forKey: preserveExactWordingStorageKey)
        let keepDictationInClipboardHistory = UserDefaults.standard.bool(forKey: keepDictationInClipboardHistoryStorageKey)
        let realtimeStreamingEnabled = UserDefaults.standard.bool(forKey: realtimeStreamingEnabledStorageKey)
        let realtimeStreamingModel = UserDefaults.standard.string(forKey: realtimeStreamingModelStorageKey) ?? ""
        let dictationAudioInterruptionEnabled = UserDefaults.standard.bool(
            forKey: dictationAudioInterruptionEnabledStorageKey
        )
        let isPressEnterVoiceCommandEnabled = UserDefaults.standard.object(forKey: pressEnterVoiceCommandStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: pressEnterVoiceCommandStorageKey)
        let soundVolume: Float = UserDefaults.standard.object(forKey: soundVolumeStorageKey) != nil
            ? UserDefaults.standard.float(forKey: soundVolumeStorageKey) : 1.0
        let alertSoundsEnabled = UserDefaults.standard.object(forKey: alertSoundsEnabledStorageKey) != nil
            ? UserDefaults.standard.bool(forKey: alertSoundsEnabledStorageKey)
            : soundVolume > 0
        
        let initialMacros: [VoiceMacro]
        if let data = UserDefaults.standard.data(forKey: "voice_macros"),
           let decoded = try? JSONDecoder().decode([VoiceMacro].self, from: data) {
            initialMacros = decoded
        } else {
            initialMacros = []
        }

        let initialAccessibility = AXIsProcessTrusted()
        let initialScreenCapturePermission = CGPreflightScreenCaptureAccess()
        var removedAudioFileNames: [String] = []
        do {
            removedAudioFileNames = try pipelineHistoryStore.trim(to: maxPipelineHistoryCount)
        } catch {
            print("Failed to trim pipeline history during init: \(error)")
        }
        for audioFileName in removedAudioFileNames {
            Self.deleteAudioFile(audioFileName)
        }
        let savedHistory = pipelineHistoryStore.loadAllHistory()

        let selectedMicrophoneID = UserDefaults.standard.string(forKey: selectedMicrophoneStorageKey) ?? "default"

        self.contextService = Self.makeAppContextService(
            apiKey: apiKey,
            baseURL: apiBaseURL,
            customContextPrompt: customContextPrompt,
            contextModel: contextModel,
            contextScreenshotMaxDimension: contextScreenshotMaxDimension
        )
        self.hasCompletedSetup = hasCompletedSetup
        self.apiKey = apiKey
        self.apiBaseURL = apiBaseURL
        self.transcriptionAPIURL = transcriptionAPIURL
        self.transcriptionAPIKey = transcriptionAPIKey
        self.transcriptionModel = transcriptionModel
        self.transcriptionEngine = transcriptionEngine
        self.localWhisperExecutablePath = localWhisperExecutablePath
        self.localWhisperModelPath = localWhisperModelPath
        self.postProcessingModel = postProcessingModel
        self.postProcessingFallbackModel = postProcessingFallbackModel
        self.contextModel = contextModel
        self.holdShortcut = shortcuts.hold
        self.toggleShortcut = shortcuts.toggle
        self.copyAgainShortcut = shortcuts.copyAgain
        self.savedHoldCustomShortcut = savedHoldCustomShortcut.binding
        self.savedToggleCustomShortcut = savedToggleCustomShortcut.binding
        self.savedCopyAgainCustomShortcut = savedCopyAgainCustomShortcut.binding
        self.isCommandModeEnabled = isCommandModeEnabled
        self.commandModeStyle = commandModeStyle
        self.commandModeManualModifier = commandModeManualModifier
        self.customVocabulary = customVocabulary
        self.transcriptionLanguage = transcriptionLanguage
        self.customSystemPrompt = customSystemPrompt
        self.noteSystemPrompt = noteSystemPrompt
        self.customContextPrompt = customContextPrompt
        self.instructionExecutionGuardEnabled = instructionExecutionGuardEnabled
        self.contextScreenshotMaxDimension = contextScreenshotMaxDimension
        self.customSystemPromptLastModified = customSystemPromptLastModified
        self.customContextPromptLastModified = customContextPromptLastModified
        self.outputLanguage = outputLanguage
        self.shortcutStartDelay = shortcutStartDelay
        self.preserveClipboard = preserveClipboard
        self.preserveExactWording = preserveExactWording
        self.keepDictationInClipboardHistory = keepDictationInClipboardHistory
        self.realtimeStreamingEnabled = realtimeStreamingEnabled
        self.realtimeStreamingModel = realtimeStreamingModel
        self.dictationAudioInterruptionEnabled = dictationAudioInterruptionEnabled
        self.isPressEnterVoiceCommandEnabled = isPressEnterVoiceCommandEnabled
        self.alertSoundsEnabled = alertSoundsEnabled
        self.soundVolume = soundVolume
        self.voiceMacros = initialMacros
        self.pipelineHistory = savedHistory
        self.hasAccessibility = initialAccessibility
        self.hasScreenRecordingPermission = initialScreenCapturePermission
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.selectedMicrophoneID = selectedMicrophoneID
        self.macroMatcher.update(initialMacros)
        refreshAvailableMicrophones()
        installAudioDeviceObservers()

        if shortcuts.didUpdateHoldStoredValue {
            persistShortcut(shortcuts.hold, key: holdShortcutStorageKey)
        }
        if shortcuts.didUpdateToggleStoredValue {
            persistShortcut(shortcuts.toggle, key: toggleShortcutStorageKey)
        }
        if shortcuts.didUpdateCopyAgainStoredValue {
            persistShortcut(shortcuts.copyAgain, key: copyAgainShortcutStorageKey)
        }
        if savedHoldCustomShortcut.didUpdateStoredValue {
            persistOptionalShortcut(savedHoldCustomShortcut.binding, key: savedHoldCustomShortcutStorageKey)
        }
        if savedToggleCustomShortcut.didUpdateStoredValue {
            persistOptionalShortcut(savedToggleCustomShortcut.binding, key: savedToggleCustomShortcutStorageKey)
        }
        if savedCopyAgainCustomShortcut.didUpdateStoredValue {
            persistOptionalShortcut(savedCopyAgainCustomShortcut.binding, key: savedCopyAgainCustomShortcutStorageKey)
        }

        overlayManager.onStopButtonPressed = { [weak self] in
            DispatchQueue.main.async {
                self?.handleOverlayStopButtonPressed()
            }
        }
        overlayManager.onUpdateOverlayPressed = { [weak self] in
            DispatchQueue.main.async {
                self?.handleUpdateOverlayPressed()
            }
        }

        // Clear any stale recording flag left over from an unclean exit.
        AppState.writeRecordingStateFlag(false)
    }

    deinit {
        removeAudioDeviceObservers()
        AppState.writeRecordingStateFlag(false)
    }

    private func persistAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            AppSettingsStorage.delete(account: apiKeyStorageKey)
        } else {
            AppSettingsStorage.save(trimmed, account: apiKeyStorageKey)
        }
    }

    static let defaultAPIBaseURL = "https://api.groq.com/openai/v1"

    static func normalizedContextScreenshotMaxDimension(_ value: Int) -> Int {
        contextScreenshotDimensionOptions.contains(value)
            ? value
            : defaultContextScreenshotMaxDimension
    }

    static func makeAppContextService(
        apiKey: String,
        baseURL: String,
        customContextPrompt: String,
        contextModel: String,
        contextScreenshotMaxDimension: Int
    ) -> AppContextService {
        AppContextService(
            apiKey: apiKey,
            baseURL: baseURL,
            customContextPrompt: customContextPrompt,
            contextModel: contextModel,
            screenshotMaxDimension: CGFloat(normalizedContextScreenshotMaxDimension(contextScreenshotMaxDimension))
        )
    }

    func makeAppContextService() -> AppContextService {
        Self.makeAppContextService(
            apiKey: apiKey,
            baseURL: apiBaseURL,
            customContextPrompt: customContextPrompt,
            contextModel: contextModel,
            contextScreenshotMaxDimension: contextScreenshotMaxDimension
        )
    }

    private func rebuildContextService() {
        contextService = makeAppContextService()
    }

    private func persistAPIBaseURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == Self.defaultAPIBaseURL {
            AppSettingsStorage.delete(account: apiBaseURLStorageKey)
        } else {
            AppSettingsStorage.save(trimmed, account: apiBaseURLStorageKey)
        }
    }

    private func persistOptionalAPIValue(_ value: String, account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            AppSettingsStorage.delete(account: account)
        } else {
            AppSettingsStorage.save(trimmed, account: account)
        }
    }

    var resolvedTranscriptionBaseURL: String {
        let trimmed = transcriptionAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? apiBaseURL : trimmed
    }

    var resolvedTranscriptionAPIKey: String {
        let trimmed = transcriptionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? apiKey : trimmed
    }

    func makeTranscriptionService(noteProcessing: Bool = false) throws -> AudioTranscriber {
        if transcriptionEngine == .localWhisper {
            let configuredTimeout = UserDefaults.standard.double(forKey: "transcription_timeout_seconds")
            let timeout = configuredTimeout > 0
                ? configuredTimeout
                : (noteProcessing ? Self.noteProcessingTimeoutSeconds : 20)
            return try LocalWhisperTranscriptionService(
                executablePath: localWhisperExecutablePath,
                modelPath: localWhisperModelPath,
                language: resolvedTranscriptionLanguage,
                timeoutSeconds: timeout
            )
        }
        return try TranscriptionService(
            apiKey: resolvedTranscriptionAPIKey,
            baseURL: resolvedTranscriptionBaseURL,
            transcriptionModel: transcriptionModel,
            language: resolvedTranscriptionLanguage,
            timeoutSecondsOverride: noteProcessing ? Self.noteProcessingTimeoutSeconds : nil
        )
    }

    var resolvedTranscriptionLanguage: String? {
        let normalized = AppSettingsLoader.normalizeTranscriptionLanguage(transcriptionLanguage)
        return normalized.isEmpty ? nil : normalized
    }

    private func persistShortcut(_ binding: ShortcutBinding, key: String) {
        let normalizedBinding = binding.normalizedForStorageMigration()
        guard let data = try? JSONEncoder().encode(normalizedBinding) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func persistOptionalShortcut(_ binding: ShortcutBinding?, key: String) {
        guard let binding else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        persistShortcut(binding, key: key)
    }

    struct SavedAudioFile {
        let fileName: String
        let fileURL: URL
    }

    static func audioStorageDirectory() -> URL {
        RecordingArtifactStore.shared.audioDirectory
    }

    /// URL of the flag file written while FreeFlow is actively recording.
    ///
    /// External tools (voice assistants, TTS barge-in pipelines, conversation
    /// apps) can poll this file to know when the user is dictating. The file
    /// exists while `isRecording` is true and is removed when it flips false.
    /// Contents are the UNIX timestamp (seconds, float) of when recording
    /// started — useful for stale-flag detection after an unclean exit.
    ///
    /// Path: `~/Library/Application Support/FreeFlow/is-recording`
    /// (or `FreeFlow Dev/is-recording` when running the dev bundle).
    static func recordingStateFlagURL() -> URL {
        RecordingArtifactStore.shared.recordingStateFlagURL
    }

    /// Write or clear the `is-recording` flag file. Called from the
    /// `isRecording` didSet. Dispatches to a background queue so disk
    /// I/O never adds latency to recording start/stop. Failures are
    /// swallowed — this is advisory IPC and must never interrupt the
    /// recording pipeline.
    static func writeRecordingStateFlag(_ recording: Bool) {
        RecordingArtifactStore.shared.writeRecordingStateFlag(recording)
    }

    static func saveAudioFile(from tempURL: URL) -> SavedAudioFile? {
        guard let savedFile = RecordingArtifactStore.shared.saveAudioFile(from: tempURL) else {
            return nil
        }
        return SavedAudioFile(fileName: savedFile.fileName, fileURL: savedFile.fileURL)
    }

    private static func deleteAudioFile(_ fileName: String) {
        RecordingArtifactStore.shared.deleteAudioFile(named: fileName)
    }

    func clearPipelineHistory() {
        do {
            let removedAudioFileNames = try pipelineHistoryStore.clearAll()
            for audioFileName in removedAudioFileNames {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory = []
        } catch {
            errorMessage = "Unable to clear run history: \(error.localizedDescription)"
        }
    }

    func deleteHistoryEntry(id: UUID) {
        guard let index = pipelineHistory.firstIndex(where: { $0.id == id }) else { return }
        do {
            if let audioFileName = try pipelineHistoryStore.delete(id: id) {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory.remove(at: index)
        } catch {
            errorMessage = "Unable to delete run history entry: \(error.localizedDescription)"
        }
    }

    func retryTranscription(item: PipelineHistoryItem) {
        guard let audioFileName = item.audioFileName else { return }
        guard !retryingItemIDs.contains(item.id) else { return }

        retryingItemIDs.insert(item.id)

        let audioURL = Self.audioStorageDirectory().appendingPathComponent(audioFileName)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            retryingItemIDs.remove(item.id)
            errorMessage = "Audio file not found for retry."
            return
        }

        let restoredContext = AppContext(
            appName: nil,
            bundleIdentifier: nil,
            windowTitle: nil,
            selectedText: nil,
            currentActivity: item.contextSummary,
            contextSystemPrompt: item.contextSystemPrompt,
            contextPrompt: item.contextPrompt,
            screenshotDataURL: item.contextScreenshotDataURL,
            screenshotMimeType: item.contextScreenshotDataURL != nil ? "image/jpeg" : nil,
            screenshotError: nil
        )

        let postProcessingService = PostProcessingService(
            apiKey: apiKey,
            baseURL: apiBaseURL,
            preferredModel: postProcessingModel,
            preferredFallbackModel: postProcessingFallbackModel,
            instructionExecutionGuardEnabled: instructionExecutionGuardEnabled
        )
        let capturedCustomVocabulary = customVocabulary
        let capturedCustomSystemPrompt = customSystemPrompt

        Task {
            do {
                let transcriptionService = try makeTranscriptionService()
                let rawTranscript = try await transcriptionService.transcribe(fileURL: audioURL)
                let parsedTranscript = TranscriptCommandParser.parse(
                    from: rawTranscript,
                    pressEnterCommandEnabled: self.isPressEnterVoiceCommandEnabled
                )

                let finalTranscript: String
                let processingStatus: String
                let postProcessingPrompt: String
                let restoredIntent = SessionIntent.fromPersisted(
                    intent: item.intent,
                    selectedText: item.selectedText
                )
                let result = await self.processTranscript(
                    parsedTranscript.transcript,
                    intent: restoredIntent,
                    context: restoredContext,
                    postProcessingService: postProcessingService,
                    customVocabulary: capturedCustomVocabulary,
                    customSystemPrompt: capturedCustomSystemPrompt,
                    outputLanguage: self.outputLanguage,
                    preserveExactWording: self.preserveExactWording
                )
                finalTranscript = result.finalTranscript
                processingStatus = Self.statusMessage(
                    for: result.outcome,
                    parsedTranscript: parsedTranscript,
                    isRetry: true
                )
                postProcessingPrompt = result.prompt

                await MainActor.run {
                    let updatedItem = PipelineHistoryItem(
                        intent: item.intent,
                        selectedText: item.selectedText,
                        capturedSelection: item.capturedSelection,
                        id: item.id,
                        timestamp: item.timestamp,
                        rawTranscript: parsedTranscript.transcript,
                        postProcessedTranscript: finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
                        postProcessingPrompt: postProcessingPrompt,
                        systemPrompt: item.systemPrompt,
                        contextSummary: item.contextSummary,
                        contextSystemPrompt: item.contextSystemPrompt,
                        contextPrompt: item.contextPrompt,
                        contextScreenshotDataURL: item.contextScreenshotDataURL,
                        contextScreenshotStatus: item.contextScreenshotStatus,
                        postProcessingStatus: processingStatus,
                        debugStatus: "Retried",
                        customVocabulary: item.customVocabulary,
                        audioFileName: item.audioFileName,
                        contextAppName: item.contextAppName,
                        contextBundleIdentifier: item.contextBundleIdentifier,
                        contextWindowTitle: item.contextWindowTitle
                    )
                    do {
                        try pipelineHistoryStore.update(updatedItem)
                        pipelineHistory = pipelineHistoryStore.loadAllHistory()
                        let trimmedRetryTranscript = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedRetryTranscript.isEmpty {
                            lastTranscript = trimmedRetryTranscript
                            clipboardController.copy(trimmedRetryTranscript)
                        }
                    } catch {
                        errorMessage = "Failed to save retry result: \(error.localizedDescription)"
                    }
                    retryingItemIDs.remove(item.id)
                }
            } catch {
                await MainActor.run {
                    let updatedItem = PipelineHistoryItem(
                        intent: item.intent,
                        selectedText: item.selectedText,
                        capturedSelection: item.capturedSelection,
                        id: item.id,
                        timestamp: item.timestamp,
                        rawTranscript: item.rawTranscript,
                        postProcessedTranscript: item.postProcessedTranscript,
                        postProcessingPrompt: item.postProcessingPrompt,
                        systemPrompt: item.systemPrompt,
                        contextSummary: item.contextSummary,
                        contextSystemPrompt: item.contextSystemPrompt,
                        contextPrompt: item.contextPrompt,
                        contextScreenshotDataURL: item.contextScreenshotDataURL,
                        contextScreenshotStatus: item.contextScreenshotStatus,
                        postProcessingStatus: "Error: \(error.localizedDescription)",
                        debugStatus: "Retry failed",
                        customVocabulary: item.customVocabulary,
                        audioFileName: item.audioFileName,
                        contextAppName: item.contextAppName,
                        contextBundleIdentifier: item.contextBundleIdentifier,
                        contextWindowTitle: item.contextWindowTitle
                    )
                    do {
                        try pipelineHistoryStore.update(updatedItem)
                        pipelineHistory = pipelineHistoryStore.loadAllHistory()
                    } catch {}
                    retryingItemIDs.remove(item.id)
                }
            }
        }
    }

    let notesLibrary = NotesLibrary()

    func toggleRecording() {
        os_log(.info, log: recordingLog, "toggleRecording() called, isRecording=%{public}d", isRecording)
        cancelPendingShortcutStart()
        if isRecording {
            stopAndTranscribe()
        } else {
            shortcutSessionController.beginManual(mode: .toggle)
            startRecording(triggerMode: .toggle)
        }
    }

    /// Starts a recording requested from the Notes window. Normal shortcut and
    /// menu-bar dictation continues to paste into the focused text field.
    func startNoteRecording() {
        guard !isRecording, !isTranscribing else { return }
        guard let noteID = notesLibrary.createEmpty() else { return }
        activeNewNoteID = noteID
        activeNoteUpdateTargetID = nil
        activeNoteUpdateAction = nil
        pendingNoteRecording = true
        toggleRecording()
    }

    func toggleNoteRecording() {
        if isRecording {
            // Do not let the Notes toolbar stop a normal dictation session
            // that happens to be visible while the Notes window is open.
            guard activeNoteRecording else { return }
            toggleRecording()
        } else {
            startNoteRecording()
        }
    }

    func startNoteUpdate(noteID: UUID) {
        guard !isRecording, !isTranscribing,
              notesLibrary.notes.contains(where: { $0.id == noteID }) else { return }
        noteUpdateTargetID = noteID
        noteVoiceAction = .update
        activeNoteUpdateTargetID = noteID
        activeNoteUpdateAction = .update
        liveNoteTranscript = ""
        pendingNoteRecording = true
        toggleRecording()
    }

    func startNoteAppend(noteID: UUID) {
        guard !isRecording, !isTranscribing,
              notesLibrary.notes.contains(where: { $0.id == noteID }) else { return }
        noteUpdateTargetID = noteID
        noteVoiceAction = .append
        activeNoteUpdateTargetID = noteID
        activeNoteUpdateAction = .append
        liveNoteTranscript = ""
        pendingNoteRecording = true
        toggleRecording()
    }

    func confirmPendingNoteUpdate() {
        guard let pendingNoteUpdate else { return }
        let saved = notesLibrary.update(id: pendingNoteUpdate.noteID, markdown: pendingNoteUpdate.markdown)
        statusText = saved ? "Note updated" : "Note could not be updated"
        self.pendingNoteUpdate = nil
        noteUpdateTargetID = nil
        noteVoiceAction = nil
        activeNoteUpdateTargetID = nil
        activeNoteUpdateAction = nil
        if saved {
            NotificationCenter.default.post(name: .showNotes, object: nil)
        }
    }

    func cancelPendingNoteUpdate() {
        pendingNoteUpdate = nil
        noteUpdateTargetID = nil
        noteVoiceAction = nil
        activeNoteUpdateTargetID = nil
        activeNoteUpdateAction = nil
        statusText = "Update cancelled"
    }

    private func handleOverlayStopButtonPressed() {
        guard isRecording, activeRecordingTriggerMode == .toggle else { return }
        stopAndTranscribe()
    }

    func cancelToggleShortcutSession() {
        guard pendingShortcutStartMode == .toggle || activeRecordingTriggerMode == .toggle else { return }

        cancelPendingShortcutStart()
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        cancelRecordingInitializationTimer()
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        capturedContext = nil
        currentSessionIntent = .dictation
        noteUpdateTargetID = nil
        noteVoiceAction = nil
        liveNoteTranscript = ""
        isRecording = false
        errorMessage = nil
        debugStatusMessage = "Cancelled"
        statusText = "Cancelled"
        overlayManager.dismiss()
        tearDownRealtimeService()
        audioRecorder.cancelRecording()
        restoreAudioInterruptionIfNeeded()
        endCriticalDictationActivity()
        refreshAvailableMicrophonesIfNeeded()
        if !isRecording && !isTranscribing && statusText == "Cancelled" {
            scheduleReadyStatusReset(after: 2, matching: ["Cancelled"])
        }
    }

    func cancelTranscription() {
        guard isTranscribing else { return }

        transcriptionTask?.cancel()
        transcriptionTask = nil
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        capturedContext = nil
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        currentSessionIntent = .dictation
        noteUpdateTargetID = nil
        noteVoiceAction = nil
        liveNoteTranscript = ""
        isRecording = false
        isTranscribing = false
        errorMessage = nil
        debugStatusMessage = "Cancelled"
        statusText = "Cancelled"
        overlayManager.dismiss()
        audioRecorder.cleanup()
        if let transcribingAudioFileName {
            Self.deleteAudioFile(transcribingAudioFileName)
            self.transcribingAudioFileName = nil
        }
        endCriticalDictationActivity()
        refreshAvailableMicrophonesIfNeeded()
        if !isRecording && !isTranscribing && statusText == "Cancelled" {
            scheduleReadyStatusReset(after: 2, matching: ["Cancelled"])
        }
    }

    func scheduleShortcutStart(mode: RecordingTriggerMode) {
        cancelPendingShortcutStart(resetMode: false)
        pendingSelectionSnapshot = contextService.collectSelectionSnapshot()
        pendingManualCommandInvocation = hotkeyManager.currentPressedModifiers.contains(
            commandModeManualModifier.shortcutModifier
        )
        pendingShortcutStartMode = mode
        let delay = shortcutStartDelay

        guard delay > 0 else {
            pendingShortcutStartMode = nil
            startRecording(triggerMode: mode)
            return
        }

        pendingShortcutStartTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }

            await MainActor.run { [weak self] in
                guard let self, let pendingMode = self.pendingShortcutStartMode else { return }
                self.pendingShortcutStartTask = nil
                self.pendingShortcutStartMode = nil
                self.startRecording(triggerMode: pendingMode)
            }
        }
    }

    func cancelPendingShortcutStart(resetMode: Bool = true) {
        pendingShortcutStartTask?.cancel()
        pendingShortcutStartTask = nil
        pendingSelectionSnapshot = nil
        pendingManualCommandInvocation = false
        if resetMode {
            pendingShortcutStartMode = nil
        }
    }

    private func resolveSessionIntent(
        triggerMode: RecordingTriggerMode,
        selectionSnapshot: AppSelectionSnapshot,
        manualCommandRequested: Bool
    ) -> SessionIntent? {
        guard isCommandModeEnabled else {
            return .dictation
        }

        let rawSelectedText = selectionSnapshot.selectedText ?? ""
        let trimmedSelectedText = rawSelectedText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch commandModeStyle {
        case .automatic:
            if !trimmedSelectedText.isEmpty {
                return .command(invocation: .automatic, selectedText: rawSelectedText)
            }
            return .dictation
        case .manual:
            // If the binding IS the manual modifier, the "modifier pressed"
            // signal is the binding's own press. Fall back to plain dictation.
            let activeBinding: ShortcutBinding = (triggerMode == .toggle) ? toggleShortcut : holdShortcut
            if activeBinding.kind == .modifierKey,
               let bindingModifier = ShortcutBinding.modifier(forKeyCode: activeBinding.keyCode),
               bindingModifier == commandModeManualModifier.shortcutModifier {
                return .dictation
            }
            if let message = commandModeManualModifierCollisionMessage(for: commandModeManualModifier) {
                rejectInvalidCommandModeModifier(triggerMode: triggerMode, message: message)
                return nil
            }
            guard manualCommandRequested else {
                return .dictation
            }
            guard !trimmedSelectedText.isEmpty else {
                rejectCommandModeSelectionRequirement(triggerMode: triggerMode)
                return nil
            }
            return .command(invocation: .manual, selectedText: rawSelectedText)
        }
    }

    private func rejectCommandModeSelectionRequirement(triggerMode: RecordingTriggerMode) {
        currentSessionIntent = .dictation
        activeRecordingTriggerMode = nil
        pendingSelectionSnapshot = nil
        pendingManualCommandInvocation = false
        errorMessage = "Select text to transform first."
        statusText = "Select text to transform first"
        debugStatusMessage = "Edit mode requires selected text"
        shortcutSessionController.reset()
        if triggerMode == .toggle {
            cancelPendingShortcutStart()
        }
        playAlertSound(named: "Basso")
        scheduleReadyStatusReset(after: 2, matching: ["Select text to transform first"])
    }

    private func rejectInvalidCommandModeModifier(triggerMode: RecordingTriggerMode, message: String) {
        currentSessionIntent = .dictation
        activeRecordingTriggerMode = nil
        pendingSelectionSnapshot = nil
        pendingManualCommandInvocation = false
        errorMessage = message
        statusText = "Fix Edit Mode modifier"
        debugStatusMessage = "Edit mode modifier conflicts with dictation shortcuts"
        shortcutSessionController.reset()
        if triggerMode == .toggle {
            cancelPendingShortcutStart()
        }
        playAlertSound(named: "Basso")
        scheduleReadyStatusReset(after: 2, matching: ["Fix Edit Mode modifier"])
    }

    private func startRecording(triggerMode: RecordingTriggerMode) {
        let t0 = CFAbsoluteTimeGetCurrent()
        os_log(.info, log: recordingLog, "startRecording() entered")
        guard !isRecording && !isTranscribing else { return }
        activeNoteRecording = pendingNoteRecording
        pendingNoteRecording = false
        liveNoteTranscript = ""
        let scheduledSelectionSnapshot = pendingSelectionSnapshot
        let scheduledManualCommandInvocation = pendingManualCommandInvocation
        cancelPendingShortcutStart()
        guard prepareRecordingStart(
            triggerMode: triggerMode,
            selectionSnapshot: scheduledSelectionSnapshot,
            manualCommandRequested: scheduledSelectionSnapshot == nil
                ? hotkeyManager.currentPressedModifiers.contains(commandModeManualModifier.shortcutModifier)
                : scheduledManualCommandInvocation,
            startedAt: t0
        ) else {
            activeNoteRecording = false
            noteUpdateTargetID = nil
            noteVoiceAction = nil
            return
        }
        guard ensureMicrophoneAccess() else {
            noteUpdateTargetID = nil
            noteVoiceAction = nil
            if !isAwaitingMicrophonePermission {
                activeNoteRecording = false
            }
            return
        }
        os_log(.info, log: recordingLog, "mic access check passed: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        applyAudioInterruptionIfNeeded()
        beginRecording(triggerMode: triggerMode)
        os_log(.info, log: recordingLog, "startRecording() finished: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    private func prepareRecordingStart(
        triggerMode: RecordingTriggerMode,
        selectionSnapshot: AppSelectionSnapshot? = nil,
        manualCommandRequested: Bool? = nil,
        startedAt: CFAbsoluteTime? = nil
    ) -> Bool {
        activeRecordingTriggerMode = triggerMode
        if !activeNoteRecording {
            let isAccessibilityTrusted = AXIsProcessTrusted()
            hasAccessibility = isAccessibilityTrusted
            guard isAccessibilityTrusted else {
                errorMessage = "Accessibility permission required. Grant access in System Settings > Privacy & Security > Accessibility."
                statusText = "No Accessibility"
                activeRecordingTriggerMode = nil
                currentSessionIntent = .dictation
                shortcutSessionController.reset()
                DispatchQueue.main.async { [weak self] in
                    self?.showAccessibilityAlertIfNeeded()
                }
                return false
            }
            if let startedAt {
                os_log(.info, log: recordingLog, "accessibility check passed: %.3fms", (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            }
        }

        let resolvedIntent: SessionIntent
        if activeNoteRecording {
            // Note recordings never transform selected text or paste into the
            // frontmost app, so they do not need Accessibility or selection
            // capture at all.
            resolvedIntent = .dictation
        } else {
            let selectionSnapshot = selectionSnapshot ?? contextService.collectSelectionSnapshot()
            let manualCommandRequested = manualCommandRequested
                ?? hotkeyManager.currentPressedModifiers.contains(commandModeManualModifier.shortcutModifier)
            guard let intent = resolveSessionIntent(
                triggerMode: triggerMode,
                selectionSnapshot: selectionSnapshot,
                manualCommandRequested: manualCommandRequested
            ) else {
                noteUpdateTargetID = nil
                noteVoiceAction = nil
                return false
            }
            resolvedIntent = intent
        }

        if resolvedIntent.isCommandMode {
            guard ensureScreenCaptureAccess() else { return false }
            if let startedAt {
                os_log(.info, log: recordingLog, "screen capture check passed: %.3fms", (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            }
        } else {
            hasScreenRecordingPermission = hasScreenCapturePermission()
        }

        currentSessionIntent = resolvedIntent
        overlayManager.setRecordingTriggerMode(triggerMode, animated: false)
        return true
    }

    private func ensureScreenCaptureAccess() -> Bool {
        let granted = hasScreenCapturePermission()
        hasScreenRecordingPermission = granted
        guard granted else {
            let message = "Screen recording permission not granted. Enable in System Settings > Privacy & Security > Screen Recording."
            errorMessage = message
            statusText = "Screenshot Required"
            activeRecordingTriggerMode = nil
            currentSessionIntent = .dictation
            shortcutSessionController.reset()
            playAlertSound(named: "Basso")
            showScreenshotPermissionAlert(message: message)
            return false
        }

        return true
    }

    private func ensureMicrophoneAccess() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            guard let triggerMode = activeRecordingTriggerMode else {
                return false
            }

            prepareForMicrophonePermissionPrompt(
                triggerMode: triggerMode,
                selectionSnapshot: pendingSelectionSnapshot ?? contextService.collectSelectionSnapshot(),
                manualCommandRequested: currentSessionIntent.isManualCommand
            )
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let strongSelf = self else { return }
                    let pendingTriggerMode = strongSelf.pendingMicrophonePermissionTriggerMode
                    let pendingSelectionSnapshot = strongSelf.pendingMicrophonePermissionSelectionSnapshot
                    let pendingManualCommandRequested = strongSelf.pendingMicrophonePermissionManualCommandRequested
                    strongSelf.pendingMicrophonePermissionTriggerMode = nil
                    strongSelf.pendingMicrophonePermissionSelectionSnapshot = nil
                    strongSelf.pendingMicrophonePermissionManualCommandRequested = nil
                    strongSelf.isAwaitingMicrophonePermission = false
                    strongSelf.restartHotkeyMonitoring()

                    guard let triggerMode = pendingTriggerMode else { return }
                    if granted {
                        strongSelf.errorMessage = nil
                        if triggerMode == .toggle {
                            guard strongSelf.prepareRecordingStart(
                                triggerMode: .toggle,
                                selectionSnapshot: pendingSelectionSnapshot,
                                manualCommandRequested: pendingManualCommandRequested
                            ) else { return }
                            strongSelf.shortcutSessionController.beginManual(mode: .toggle)
                            strongSelf.applyAudioInterruptionIfNeeded()
                            strongSelf.beginRecording(triggerMode: .toggle)
                        } else {
                            strongSelf.currentSessionIntent = .dictation
                            strongSelf.statusText = "Microphone access granted. Press and hold again to record."
                            strongSelf.scheduleReadyStatusReset(
                                after: 2,
                                matching: ["Microphone access granted. Press and hold again to record."]
                            )
                        }
                    } else {
                        strongSelf.errorMessage = "Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone."
                        strongSelf.statusText = "No Microphone"
                        strongSelf.activeRecordingTriggerMode = nil
                        strongSelf.currentSessionIntent = .dictation
                        strongSelf.activeNoteRecording = false
                        strongSelf.shortcutSessionController.reset()
                        strongSelf.showMicrophonePermissionAlert()
                    }
                }
            }
            return false
        default:
            errorMessage = "Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone."
            statusText = "No Microphone"
            activeRecordingTriggerMode = nil
            currentSessionIntent = .dictation
            activeNoteRecording = false
            shortcutSessionController.reset()
            showMicrophonePermissionAlert()
            return false
        }
    }

    private func prepareForMicrophonePermissionPrompt(
        triggerMode: RecordingTriggerMode,
        selectionSnapshot: AppSelectionSnapshot?,
        manualCommandRequested: Bool?
    ) {
        isAwaitingMicrophonePermission = true
        pendingMicrophonePermissionTriggerMode = triggerMode
        pendingMicrophonePermissionSelectionSnapshot = selectionSnapshot
        pendingMicrophonePermissionManualCommandRequested = manualCommandRequested
        hotkeyManager.stop()
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        cancelRecordingInitializationTimer()
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        overlayManager.dismiss()
    }

    private func applyAudioInterruptionIfNeeded() {
        guard dictationAudioInterruptionEnabled, activeAudioInterruption == nil else { return }

        let wasMuted = SystemAudioStatus.isDefaultOutputMuted()
        if wasMuted {
            activeAudioInterruption = .muted(previouslyMuted: true)
        } else if SystemAudioStatus.setDefaultOutputMuted(true) {
            activeAudioInterruption = .muted(previouslyMuted: false)
        }
    }

    func restoreAudioInterruptionIfNeeded() {
        guard let activeAudioInterruption else { return }
        self.activeAudioInterruption = nil

        switch activeAudioInterruption {
        case .muted(let previouslyMuted):
            if !previouslyMuted {
                _ = SystemAudioStatus.setDefaultOutputMuted(false)
            }
        }
    }

    private func beginCriticalDictationActivity() {
        guard !automaticTerminationDisabled else { return }
        ProcessInfo.processInfo.disableAutomaticTermination("FreeFlow dictation in progress")
        automaticTerminationDisabled = true
    }

    func endCriticalDictationActivity() {
        guard automaticTerminationDisabled else { return }
        ProcessInfo.processInfo.enableAutomaticTermination("FreeFlow dictation in progress")
        automaticTerminationDisabled = false
    }

    private func beginRecording(triggerMode: RecordingTriggerMode) {
        os_log(.info, log: recordingLog, "beginRecording() entered")
        beginCriticalDictationActivity()
        clearPendingOverlayDismissToken()
        errorMessage = nil

        isRecording = true
        statusText = "Starting..."
        hasShownScreenshotPermissionAlert = false

        // Show initializing dots only if engine takes longer than 0.2s to start
        var overlayShown = false
        cancelRecordingInitializationTimer()
        let initTimer = DispatchSource.makeTimerSource(queue: .main)
        recordingInitializationTimer = initTimer
        initTimer.schedule(deadline: .now() + 0.2)
        initTimer.setEventHandler { [weak self] in
            guard let self, !overlayShown else { return }
            overlayShown = true
            os_log(.info, log: recordingLog, "engine slow — showing initializing overlay")
            self.clearPendingOverlayDismissToken()
            self.overlayManager.showInitializing(
                mode: self.activeRecordingTriggerMode ?? triggerMode,
                isCommandMode: self.currentSessionIntent.isCommandMode
            )
        }
        initTimer.resume()

        // Transition to waveform when first real audio arrives (any non-zero RMS)
        let deviceUID = selectedMicrophoneID
        audioRecorder.onRecordingReady = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cancelRecordingInitializationTimer()
                os_log(.info, log: recordingLog, "first real audio — transitioning to waveform")
                self.statusText = "Recording..."
                self.clearPendingOverlayDismissToken()
                if overlayShown {
                    self.overlayManager.transitionToRecording(
                        mode: self.activeRecordingTriggerMode ?? triggerMode,
                        isCommandMode: self.currentSessionIntent.isCommandMode
                    )
                } else {
                    self.overlayManager.showRecording(
                        mode: self.activeRecordingTriggerMode ?? triggerMode,
                        isCommandMode: self.currentSessionIntent.isCommandMode
                    )
                }
                overlayShown = true
                self.playAlertSound(named: "Tink")
            }
        }
        audioRecorder.onRecordingFailure = { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cancelRecordingInitializationTimer()
                self.handleRecordingFailure(error)
            }
        }

        startRealtimeStreamingIfEnabled()

        // Start engine on background thread so UI isn't blocked
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                try self.audioRecorder.startRecording(deviceUID: deviceUID)
                os_log(.info, log: recordingLog, "audioRecorder.startRecording() done: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
                DispatchQueue.main.async {
                    guard self.isRecording, self.activeRecordingTriggerMode != nil else { return }
                    if !self.activeNoteRecording {
                        self.startContextCapture()
                    }
                    self.audioLevelCancellable = self.audioRecorder.$audioLevel
                        .receive(on: DispatchQueue.main)
                        .sink { [weak self] level in
                            self?.overlayManager.updateAudioLevel(level)
                        }
                }
            } catch {
                DispatchQueue.main.async {
                    self.cancelRecordingInitializationTimer()
                    guard self.isRecording || self.activeRecordingTriggerMode != nil else { return }
                    self.handleRecordingFailure(error)
                }
            }
        }
    }

    private func handleRecordingFailure(_ error: Error) {
        cancelRecordingInitializationTimer()
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        capturedContext = nil
        tearDownRealtimeService()
        audioRecorder.cleanup()
        restoreAudioInterruptionIfNeeded()
        isRecording = false
        isTranscribing = false
        transcriptionTask?.cancel()
        transcriptionTask = nil
        if let transcribingAudioFileName {
            Self.deleteAudioFile(transcribingAudioFileName)
            self.transcribingAudioFileName = nil
        }
        activeRecordingTriggerMode = nil
        currentSessionIntent = .dictation
        noteUpdateTargetID = nil
        noteVoiceAction = nil
        liveNoteTranscript = ""
        shortcutSessionController.reset()
        endCriticalDictationActivity()
        errorMessage = formattedRecordingStartError(error)
        statusText = "Error"
        overlayManager.dismiss()
        refreshAvailableMicrophonesIfNeeded()
    }

    private func formattedRecordingStartError(_ error: Error) -> String {
        if let recorderError = error as? AudioRecorderError {
            return "Failed to start recording: \(recorderError.localizedDescription)"
        }

        let lower = error.localizedDescription.lowercased()
        if lower.contains("operation couldn't be completed") || lower.contains("operation could not be completed") {
            return "Failed to start recording: Audio input error. Verify microphone access is granted and a working mic is selected in System Settings > Sound > Input."
        }

        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain {
            return "Failed to start recording (audio subsystem error \(nsError.code)). Check microphone permissions and selected input device."
        }

        return "Failed to start recording: \(error.localizedDescription)"
    }

    private func formattedTranscriptionError(_ error: Error) -> String {
        TranscriptionErrorPresentationCore.message(
            for: error,
            isOnline: NetworkMonitor.shared.isOnline
        )
    }

    func showMicrophonePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Permission Required"
        alert.informativeText = "\(AppName.displayName) cannot record audio without Microphone access.\n\nGo to System Settings > Privacy & Security > Microphone and enable \(AppName.displayName)."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openMicrophoneSettings()
        }
    }

    func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "\(AppName.displayName) cannot type transcriptions without Accessibility access.\n\nGo to System Settings > Privacy & Security > Accessibility and enable \(AppName.displayName)."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    /// Presents the permission alert at most once per app launch. Manual menu
    /// actions still call `showAccessibilityAlert()` directly so the user can
    /// reopen the guidance after dismissing the automatic alert.
    func showAccessibilityAlertIfNeeded() {
        guard !hasPresentedAutomaticAccessibilityAlert, !AXIsProcessTrusted() else { return }
        hasPresentedAutomaticAccessibilityAlert = true
        showAccessibilityAlert()
    }

    private static func statusMessage(
        for outcome: TranscriptProcessingOutcome,
        parsedTranscript: TranscriptCommandParsingResult,
        isRetry: Bool = false
    ) -> String {
        let status = outcome.statusMessage(isRetry: isRetry)
        guard parsedTranscript.shouldPressEnterAfterPaste else { return status }
        return "\(status); detected press enter command"
    }

    func playAlertSound(named name: String) {
        guard alertSoundsEnabled else { return }

        let sound = NSSound(named: name)
        sound?.volume = soundVolume
        sound?.play()
    }

    private func processTranscript(
        _ rawTranscript: String,
        intent: SessionIntent,
        context: AppContext,
        postProcessingService: PostProcessingService,
        customVocabulary: String,
        customSystemPrompt: String,
        outputLanguage: String = "",
        preserveExactWording: Bool
    ) async -> (finalTranscript: String, outcome: TranscriptProcessingOutcome, prompt: String) {
        await TranscriptProcessor.process(
            rawTranscript,
            intent: intent,
            context: context,
            postProcessingService: postProcessingService,
            macroMatcher: macroMatcher,
            customVocabulary: customVocabulary,
            customSystemPrompt: customSystemPrompt,
            outputLanguage: outputLanguage,
            preserveExactWording: preserveExactWording
        )
    }

    /// Await the realtime WebSocket's final transcript. If it errors out (or
    /// was never started) fall back to the file-based POST so the user still
    /// gets a transcript. Runs the realtime commit and file upload in that
    /// strict order to avoid paying for both when realtime succeeds.
    private static func resolveRawTranscript(
        realtimeService: RealtimeTranscriptionService?,
        fileService: AudioTranscriber,
        fileURL: URL
    ) async throws -> String {
        if let realtimeService {
            do {
                try Task.checkCancellation()
                return try await withTaskCancellationHandler {
                    try await realtimeService.commitAndAwaitFinal()
                } onCancel: {
                    realtimeService.cancel()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                return try await fileService.transcribe(fileURL: fileURL)
            }
        }
        return try await fileService.transcribe(fileURL: fileURL)
    }

    private func transcribeFileInChunks(
        fileService: AudioTranscriber,
        fileURL: URL
    ) async throws -> String {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let chunkSet = try AudioChunker.split(fileURL: fileURL)
        defer { chunkSet.cleanup() }
        defer {
            os_log(
                .info,
                log: recordingLog,
                "file transcription finished chunks=%d elapsed=%.0fms",
                chunkSet.urls.count,
                (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            )
        }

        if chunkSet.urls.count == 1 {
            await MainActor.run {
                self.statusText = "Transcribing..."
                self.debugStatusMessage = "Transcribing audio"
            }
            let transcript = try await fileService.transcribe(fileURL: fileURL)
            await MainActor.run {
                self.liveNoteTranscript = transcript
            }
            return transcript
        }

        var transcripts: [String] = []
        transcripts.reserveCapacity(chunkSet.urls.count)
        for (index, chunkURL) in chunkSet.urls.enumerated() {
            try Task.checkCancellation()
            await MainActor.run {
                self.statusText = "Transcribing chunk \(index + 1) of \(chunkSet.urls.count)..."
                self.debugStatusMessage = "Transcribing audio chunk \(index + 1) of \(chunkSet.urls.count)"
            }
            transcripts.append(try await fileService.transcribe(fileURL: chunkURL))
            let partialTranscript = MarkdownNoteStore.mergeTranscripts(transcripts)
            await MainActor.run {
                self.liveNoteTranscript = partialTranscript
            }
        }
        let mergedTranscript = MarkdownNoteStore.mergeTranscripts(transcripts)
        await MainActor.run {
            self.liveNoteTranscript = mergedTranscript
        }
        return mergedTranscript
    }

    private func processNoteTranscript(
        _ rawTranscript: String,
        context: AppContext,
        postProcessingService: PostProcessingService,
        customVocabulary: String
    ) async -> (finalTranscript: String, outcome: TranscriptProcessingOutcome, prompt: String) {
        let trimmedCustomPrompt = noteSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let basePrompt = trimmedCustomPrompt.isEmpty ? MarkdownNoteStore.systemPrompt : trimmedCustomPrompt
        let rawChunks = MarkdownNoteStore.splitText(rawTranscript)
        guard rawChunks.count > 1 else {
            return await processTranscript(
                rawTranscript,
                intent: .dictation,
                context: context,
                postProcessingService: postProcessingService,
                customVocabulary: customVocabulary,
                customSystemPrompt: basePrompt,
                outputLanguage: outputLanguage,
                preserveExactWording: false
            )
        }

        await MainActor.run {
            self.statusText = "Formatting note sections in parallel..."
            self.debugStatusMessage = "Formatting Markdown sections"
        }
        let formattedChunks = await withTaskGroup(of: (Int, NoteFormattingResult).self) { group in
            for (index, chunk) in rawChunks.enumerated() {
                guard !Task.isCancelled else { break }
                group.addTask { [self] in
                    let result = await self.processTranscript(
                        chunk,
                        intent: .dictation,
                        context: context,
                        postProcessingService: postProcessingService,
                        customVocabulary: customVocabulary,
                        customSystemPrompt: basePrompt + "\n\n" + MarkdownNoteStore.chunkSystemPrompt,
                        outputLanguage: outputLanguage,
                        preserveExactWording: false
                    )
                    return (
                        index,
                        NoteFormattingResult(
                            finalTranscript: result.finalTranscript,
                            outcome: result.outcome,
                            prompt: result.prompt
                        )
                    )
                }
            }

            var results = Array<NoteFormattingResult?>(repeating: nil, count: rawChunks.count)
            for await (index, result) in group {
                results[index] = result
            }
            return results.compactMap { $0 }
        }

        var sections = formattedChunks.compactMap { result -> String? in
            let trimmed = result.finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : result.finalTranscript
        }
        var prompts = formattedChunks.map(\.prompt)
        var usedFallback = formattedChunks.contains {
            if case .postProcessingFailedFallback = $0.outcome { return true }
            return false
        }

        while sections.count > 1 {
            if Task.isCancelled {
                return (rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines), .postProcessingFailedFallback, "")
            }
            await MainActor.run {
                self.statusText = "Combining Markdown sections in parallel..."
                self.debugStatusMessage = "Combining Markdown sections"
            }
            let pairs = stride(from: 0, to: sections.count, by: 2).map { index in
                let end = min(index + 2, sections.count)
                return (index, Array(sections[index..<end]).joined(separator: "\n\n"))
            }
            let mergedResults = await withTaskGroup(of: (Int, NoteFormattingResult).self) { group in
                for (index, pair) in pairs {
                    group.addTask { [self] in
                        let result = await self.processTranscript(
                            pair,
                            intent: .dictation,
                            context: context,
                            postProcessingService: postProcessingService,
                            customVocabulary: customVocabulary,
                            customSystemPrompt: basePrompt + "\n\n" + MarkdownNoteStore.synthesisSystemPrompt,
                            outputLanguage: outputLanguage,
                            preserveExactWording: false
                        )
                        return (
                            index,
                            NoteFormattingResult(
                                finalTranscript: result.finalTranscript,
                                outcome: result.outcome,
                                prompt: result.prompt
                            )
                        )
                    }
                }

                var results = Array<NoteFormattingResult?>(repeating: nil, count: pairs.count)
                for await (index, result) in group {
                    results[index / 2] = result
                }
                return results.compactMap { $0 }
            }
            sections = mergedResults.map(\.finalTranscript)
            prompts.append(contentsOf: mergedResults.map(\.prompt))
            if mergedResults.contains(where: {
                if case .postProcessingFailedFallback = $0.outcome { return true }
                return false
            }) {
                usedFallback = true
            }
        }

        return (
            sections.first ?? "",
            usedFallback ? .postProcessingFailedFallback : .postProcessingSucceeded,
            prompts.joined(separator: "\n\n")
        )
    }

    private func processNoteTranscriptWithDeadline(
        _ rawTranscript: String,
        context: AppContext,
        postProcessingService: PostProcessingService,
        customVocabulary: String
    ) async -> (finalTranscript: String, outcome: TranscriptProcessingOutcome, prompt: String) {
        let timeoutSeconds = Self.noteProcessingOverallTimeoutSeconds
        let winner = await withTaskGroup(of: NoteProcessingRaceResult.self) { group in
            group.addTask { [self] in
                let result = await self.processNoteTranscript(
                    rawTranscript,
                    context: context,
                    postProcessingService: postProcessingService,
                    customVocabulary: customVocabulary
                )
                return .completed(
                    finalTranscript: result.finalTranscript,
                    outcome: result.outcome,
                    prompt: result.prompt
                )
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                } catch {
                    return .timedOut
                }
                return .timedOut
            }

            let result = await group.next() ?? .timedOut
            group.cancelAll()
            return result
        }

        switch winner {
        case .completed(let finalTranscript, let outcome, let prompt):
            return (finalTranscript, outcome, prompt)
        case .timedOut:
            os_log(
                .error,
                log: recordingLog,
                "note processing exceeded overall deadline of %.0fs; using raw transcript",
                timeoutSeconds
            )
            return (rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines), .postProcessingFailedFallback, "")
        }
    }

    private func processNoteUpdate(
        instruction: String,
        existingNote: MarkdownNote,
        action: NoteVoiceAction,
        context: AppContext,
        postProcessingService: PostProcessingService,
        customVocabulary: String
    ) async -> (finalTranscript: String, outcome: TranscriptProcessingOutcome, prompt: String) {
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else {
            return ("", .skippedEmptyRawTranscript, "")
        }

        let trimmedCustomPrompt = noteSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let basePrompt = trimmedCustomPrompt.isEmpty ? MarkdownNoteStore.systemPrompt : trimmedCustomPrompt
        let protectedExisting = MarkdownNoteStore.protectMarkdownReferences(existingNote.markdown)
        let updatePrompt: String
        let updateInput: String
        switch action {
        case .update:
            updatePrompt = basePrompt + "\n\n" + MarkdownNoteStore.updateSystemPrompt
            updateInput = """
            EXISTING_MARKDOWN_NOTE:
            <note>
            \(protectedExisting.markdown)
            </note>

            SPOKEN_UPDATE_INSTRUCTION:
            <instruction>
            \(trimmedInstruction)
            </instruction>
            """
        case .append:
            updatePrompt = basePrompt + "\n\n" + """
Append the spoken transcription to the end of the existing Markdown note.
Return only the complete updated Markdown note. Preserve all existing content exactly
unless required to add the new material. Format only the new material as Markdown and
do not summarize, omit, or invent content. Preserve every existing attachment reference
exactly, including its Markdown syntax, label, relative path, folder name, filename, and
extension. Never convert attachment references to absolute paths, plain text, or shortened
filenames. Keep each attachment on its own line with a blank line before and after it.
Separate newly appended attachments and text from the existing note with blank lines.
Existing references are represented by ATTACHMENT_N placeholders. Preserve each placeholder
exactly unless the spoken instruction explicitly asks to remove or convert that item.
"""
            updateInput = """
            EXISTING_MARKDOWN_NOTE:
            <note>
            \(protectedExisting.markdown)
            </note>

            SPOKEN_TRANSCRIPTION_TO_APPEND:
            <transcription>
            \(trimmedInstruction)
            </transcription>
            """
        }

        do {
            let result = try await postProcessingService.postProcess(
                transcript: updateInput,
                context: context,
                customVocabulary: customVocabulary,
                customSystemPrompt: updatePrompt,
                outputLanguage: outputLanguage
            )
            let restoredMarkdown = protectedExisting.restore(in: result.transcript)
            return (restoredMarkdown, .postProcessingSucceeded, result.prompt)
        } catch {
            os_log(.error, log: recordingLog, "Note update failed: %{public}@", error.localizedDescription)
            return (existingNote.markdown, .postProcessingFailedFallback, "")
        }
    }

    func stopAndTranscribe() {
        let stopStartedAt = CFAbsoluteTimeGetCurrent()
        cancelPendingShortcutStart()
        cancelRecordingInitializationTimer()
        shortcutSessionController.reset()
        let sessionIntent = currentSessionIntent
        let shouldSaveAsNote = activeNoteRecording
        activeRecordingTriggerMode = nil
        currentSessionIntent = .dictation
        activeNoteRecording = false
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        debugStatusMessage = "Preparing audio"
        let sessionContext: AppContext?
        if shouldSaveAsNote || noteUpdateTargetID != nil {
            // Notes are self-contained and do not need frontmost-window
            // metadata or screenshots sent to the context provider.
            sessionContext = AppContext(
                appName: nil,
                bundleIdentifier: nil,
                windowTitle: nil,
                selectedText: nil,
                currentActivity: "Recording a Markdown note.",
                contextSystemPrompt: nil,
                contextPrompt: nil,
                screenshotDataURL: nil,
                screenshotMimeType: nil,
                screenshotError: nil
            )
        } else {
            sessionContext = capturedContext
        }
        let inFlightContextTask = contextCaptureTask
        let noteUpdateTargetID = activeNoteUpdateTargetID ?? self.noteUpdateTargetID
        let noteVoiceAction = activeNoteUpdateAction ?? self.noteVoiceAction ?? .update
        let isNoteUpdate = noteUpdateTargetID != nil
        let newNoteTargetID = shouldSaveAsNote ? activeNewNoteID : nil
        let noteUpdateTarget = noteUpdateTargetID.flatMap { id in
            notesLibrary.notes.first(where: { $0.id == id })
        }
        capturedContext = nil
        contextCaptureTask = nil
        lastRawTranscript = ""
        lastPostProcessedTranscript = ""
        lastContextSummary = ""
        lastPostProcessingStatus = ""
        lastPostProcessingPrompt = ""
        lastContextScreenshotDataURL = nil
        lastContextScreenshotStatus = "No screenshot"
        isRecording = false
        restoreAudioInterruptionIfNeeded()
        isTranscribing = true
        statusText = "Preparing audio..."
        errorMessage = nil
        playAlertSound(named: "Pop")
        overlayManager.showTranscribing()
        audioRecorder.stopRecording { [weak self] fileURL in
            guard let self else { return }
            guard let fileURL else {
                self.isTranscribing = false
                self.tearDownRealtimeService()
                self.audioRecorder.cleanup()
                self.endCriticalDictationActivity()
                self.noteUpdateTargetID = nil
                self.noteVoiceAction = nil
                self.liveNoteTranscript = ""
                self.errorMessage = "No audio recorded"
                self.statusText = "Error"
                self.overlayManager.dismiss()
                self.refreshAvailableMicrophonesIfNeeded()
                return
            }

            guard self.isTranscribing else {
                self.tearDownRealtimeService()
                self.audioRecorder.cleanup()
                self.refreshAvailableMicrophonesIfNeeded()
                return
            }

            let savedAudioFile = Self.saveAudioFile(from: fileURL)
            let transcriptionFileURL = savedAudioFile?.fileURL ?? fileURL
            self.transcribingAudioFileName = savedAudioFile?.fileName
            self.statusText = "Transcribing..."
            self.debugStatusMessage = "Transcribing audio"

            let postProcessingService = PostProcessingService(
                apiKey: apiKey,
                baseURL: apiBaseURL,
                preferredModel: postProcessingModel,
                preferredFallbackModel: postProcessingFallbackModel,
                instructionExecutionGuardEnabled: instructionExecutionGuardEnabled,
                timeoutSecondsOverride: shouldSaveAsNote || noteUpdateTarget != nil
                    ? Self.noteProcessingTimeoutSeconds
                    : nil
            )

            let activeRealtime = self.realtimeService
            self.realtimeService = nil
            let activeLocalPreview = self.localPreviewService
            self.localPreviewService = nil
            self.audioRecorder.onPCM16Samples = nil
            self.audioRecorder.onRecordingPCM16Samples = nil
            self.transcriptionTask?.cancel()
            guard self.isTranscribing else {
                if let savedAudioFile {
                    Self.deleteAudioFile(savedAudioFile.fileName)
                }
                self.transcribingAudioFileName = nil
                activeRealtime?.cancel()
                activeLocalPreview?.stop()
                self.audioRecorder.cleanup()
                self.endCriticalDictationActivity()
                self.refreshAvailableMicrophonesIfNeeded()
                return
            }
            self.transcriptionTask = Task {
                defer {
                    activeRealtime?.cancel()
                    activeLocalPreview?.stop()
                }
                do {
                    let transcriptionStartedAt = CFAbsoluteTimeGetCurrent()
                    let transcriptionService = try self.makeTranscriptionService(
                        noteProcessing: shouldSaveAsNote || noteUpdateTarget != nil
                    )
                    let rawTranscript: String
                    if let activeRealtime {
                        do {
                            rawTranscript = try await withTaskCancellationHandler {
                                try await activeRealtime.commitAndAwaitFinal()
                            } onCancel: {
                                activeRealtime.cancel()
                            }
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            try Task.checkCancellation()
                            rawTranscript = try await self.transcribeFileInChunks(
                                fileService: transcriptionService,
                                fileURL: transcriptionFileURL
                            )
                        }
                    } else {
                        rawTranscript = try await self.transcribeFileInChunks(
                            fileService: transcriptionService,
                            fileURL: transcriptionFileURL
                        )
                    }
                    let transcriptionElapsed = CFAbsoluteTimeGetCurrent() - transcriptionStartedAt
                    let parsedTranscript = TranscriptCommandParser.parse(
                        from: rawTranscript,
                        pressEnterCommandEnabled: !shouldSaveAsNote && noteUpdateTarget == nil
                            ? self.isPressEnterVoiceCommandEnabled
                            : false
                    )
                    try Task.checkCancellation()
                    // Capture the parsed raw transcript as lastTranscript before
                    // post-processing runs. If anything after this throws or focus
                    // shifts mid-paste, the Paste Again shortcut still has the raw
                    // text instead of the previous dictation's stale value.
                    let bootstrapTranscript = parsedTranscript.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !bootstrapTranscript.isEmpty {
                        await MainActor.run { [weak self] in
                            self?.lastTranscript = bootstrapTranscript
                        }
                    }
                    let contextWaitStartedAt = CFAbsoluteTimeGetCurrent()
                    let appContext: AppContext
                    if let sessionContext {
                        appContext = sessionContext
                    } else if let inFlightContext = await inFlightContextTask?.value {
                        os_log(.info, log: recordingLog, "awaited in-flight context capture")
                        appContext = inFlightContext
                    } else {
                        appContext = self.fallbackContextAtStop()
                    }
                    let contextWaitElapsed = CFAbsoluteTimeGetCurrent() - contextWaitStartedAt
                    try Task.checkCancellation()
                    let postProcessingStartedAt = CFAbsoluteTimeGetCurrent()
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.statusText = noteUpdateTarget != nil
                            ? "Updating note..."
                            : (shouldSaveAsNote ? "Formatting note..." : "Processing dictation...")
                        self.debugStatusMessage = shouldSaveAsNote || noteUpdateTarget != nil
                            ? "Running note post-processing"
                            : "Running post-processing"
                    }
                    let result: (finalTranscript: String, outcome: TranscriptProcessingOutcome, prompt: String)
                    if let noteUpdateTarget {
                        result = await self.processNoteUpdate(
                            instruction: parsedTranscript.transcript,
                            existingNote: noteUpdateTarget,
                            action: noteVoiceAction,
                            context: appContext,
                            postProcessingService: postProcessingService,
                            customVocabulary: self.customVocabulary
                        )
                    } else if shouldSaveAsNote {
                        result = await self.processNoteTranscriptWithDeadline(
                            parsedTranscript.transcript,
                            context: appContext,
                            postProcessingService: postProcessingService,
                            customVocabulary: self.customVocabulary
                        )
                    } else {
                        result = await self.processTranscript(
                            parsedTranscript.transcript,
                            intent: sessionIntent,
                            context: appContext,
                            postProcessingService: postProcessingService,
                            customVocabulary: self.customVocabulary,
                            customSystemPrompt: Self.resolvedSystemPrompt(self.customSystemPrompt),
                            outputLanguage: self.outputLanguage,
                            preserveExactWording: self.preserveExactWording
                        )
                    }
                    let postProcessingElapsed = CFAbsoluteTimeGetCurrent() - postProcessingStartedAt
                    os_log(
                        .info,
                        log: recordingLog,
                        "post-processing finished in %.0fms",
                        (CFAbsoluteTimeGetCurrent() - postProcessingStartedAt) * 1000
                    )
                    try Task.checkCancellation()

                    await MainActor.run {
                        guard self.isTranscribing else { return }
                        self.lastContextSummary = appContext.contextSummary
                        self.lastContextScreenshotDataURL = appContext.screenshotDataURL
                        self.lastContextScreenshotStatus = appContext.screenshotError
                            ?? "available (\(appContext.screenshotMimeType ?? "image"))"
                        self.lastContextAppName = appContext.appName ?? ""
                        self.lastContextBundleIdentifier = appContext.bundleIdentifier ?? ""
                        self.lastContextWindowTitle = appContext.windowTitle ?? ""
                        self.lastContextSelectedText = appContext.selectedText ?? ""
                        self.lastContextLLMPrompt = appContext.contextPrompt ?? ""
                        let trimmedRawTranscript = parsedTranscript.transcript
                        let trimmedFinalTranscript = result.finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.debugStatusMessage = String(
                            format: "Done (Whisper %.1fs, context %.1fs, post-processing %.1fs, total %.1fs)",
                            transcriptionElapsed,
                            contextWaitElapsed,
                            postProcessingElapsed,
                            CFAbsoluteTimeGetCurrent() - stopStartedAt
                        )
                        let processingStatus = Self.statusMessage(
                            for: result.outcome,
                            parsedTranscript: parsedTranscript
                        )
                        self.lastPostProcessingPrompt = result.prompt
                        self.lastRawTranscript = trimmedRawTranscript
                        self.lastPostProcessedTranscript = trimmedFinalTranscript
                        self.lastPostProcessingStatus = processingStatus
                        self.recordPipelineHistoryEntry(
                            rawTranscript: trimmedRawTranscript,
                            postProcessedTranscript: trimmedFinalTranscript,
                            postProcessingPrompt: result.prompt,
                            systemPrompt: shouldSaveAsNote
                                ? (self.noteSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? MarkdownNoteStore.systemPrompt
                                    : self.noteSystemPrompt)
                                : Self.resolvedSystemPrompt(self.customSystemPrompt),
                            context: appContext,
                            processingStatus: processingStatus,
                            intent: sessionIntent,
                            audioFileName: savedAudioFile?.fileName
                        )
                        self.transcriptionTask = nil
                        self.transcribingAudioFileName = nil
                        self.lastTranscript = trimmedFinalTranscript
                        self.isTranscribing = false
                        self.endCriticalDictationActivity()
                        let completionStatusText = shouldSaveAsNote
                            ? "Note saved"
                            : (self.preserveClipboard ? "Pasted at cursor!" : "Copied to clipboard!")
                        let saveFailureStatusText = "Note could not be saved"
                        self.clearPendingOverlayDismissToken()
                        if shouldSaveAsNote || noteUpdateTarget != nil {
                            self.overlayManager.dismiss()
                        }
                        if trimmedFinalTranscript.isEmpty {
                            self.statusText = "Nothing to transcribe"
                            self.noteUpdateTargetID = nil
                            self.noteVoiceAction = nil
                            if !shouldSaveAsNote && noteUpdateTarget == nil,
                               !self.showPostTranscriptionUpdateReminderIfNeeded() {
                                self.overlayManager.dismiss()
                            }
                        } else if isNoteUpdate {
                            if let noteUpdateTarget {
                                self.pendingNoteUpdate = PendingNoteUpdate(
                                    noteID: noteUpdateTarget.id,
                                    action: noteVoiceAction,
                                    markdown: trimmedFinalTranscript
                                )
                                self.statusText = "Preview ready"
                            } else {
                                self.statusText = "Note update could not find the original note"
                                self.errorMessage = "The note changed or was removed before the update completed. No new note was created."
                            }
                            self.noteUpdateTargetID = nil
                            self.noteVoiceAction = nil
                        } else if let newNoteTargetID {
                            let saved = self.notesLibrary.update(id: newNoteTargetID, markdown: trimmedFinalTranscript)
                            self.statusText = saved ? "Note saved" : "Note could not be saved"
                            self.activeNewNoteID = nil
                            NotificationCenter.default.post(name: .showNotes, object: nil)
                        } else if shouldSaveAsNote {
                            let saved = self.notesLibrary.create(trimmedFinalTranscript)
                            self.statusText = saved ? completionStatusText : saveFailureStatusText
                            NotificationCenter.default.post(name: .showNotes, object: nil)
                        } else {
                            self.statusText = completionStatusText
                            if !self.showPostTranscriptionUpdateReminderIfNeeded() {
                                self.overlayManager.dismiss()
                            }
                            let pendingClipboardRestore = self.writeTranscriptToPasteboard(trimmedFinalTranscript)
                            self.pasteAtCursorWhenShortcutReleased {
                                if parsedTranscript.shouldPressEnterAfterPaste {
                                    self.pressEnterAfterPaste {
                                        self.restoreClipboardIfNeeded(pendingClipboardRestore)
                                    }
                                } else {
                                    self.restoreClipboardIfNeeded(pendingClipboardRestore)
                                }
                            }
                        }

                        self.audioRecorder.cleanup()
                        self.refreshAvailableMicrophonesIfNeeded()

                        self.scheduleReadyStatusReset(after: 3, matching: [completionStatusText, "Nothing to transcribe", saveFailureStatusText, "Note updated", "Note could not be updated", "Preview ready"])
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        self.transcriptionTask = nil
                        self.noteUpdateTargetID = nil
                        self.noteVoiceAction = nil
                        self.liveNoteTranscript = ""
                        self.endCriticalDictationActivity()
                    }
                } catch {
                    let resolvedContext: AppContext
                    if let sessionContext {
                        resolvedContext = sessionContext
                    } else if let inFlightContext = await inFlightContextTask?.value {
                        resolvedContext = inFlightContext
                    } else {
                        resolvedContext = self.fallbackContextAtStop()
                    }
                    await MainActor.run {
                        guard self.isTranscribing else { return }
                        self.transcriptionTask = nil
                        self.transcribingAudioFileName = nil
                        self.noteUpdateTargetID = nil
                        self.noteVoiceAction = nil
                        self.liveNoteTranscript = ""
                        let userFacingErrorMessage = self.formattedTranscriptionError(error)
                        self.errorMessage = userFacingErrorMessage
                        self.isTranscribing = false
                        self.endCriticalDictationActivity()
                        self.statusText = "Error"
                        self.overlayManager.showError(userFacingErrorMessage)
                        self.lastPostProcessedTranscript = ""
                        self.lastRawTranscript = ""
                        self.lastContextSummary = ""
                        self.lastPostProcessingStatus = "Error: \(error.localizedDescription)"
                        self.lastPostProcessingPrompt = ""
                        self.lastContextScreenshotDataURL = resolvedContext.screenshotDataURL
                        self.lastContextScreenshotStatus = resolvedContext.screenshotError
                            ?? "available (\(resolvedContext.screenshotMimeType ?? "image"))"
                        self.recordPipelineHistoryEntry(
                            rawTranscript: "",
                            postProcessedTranscript: "",
                            postProcessingPrompt: "",
                            systemPrompt: self.noteSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? MarkdownNoteStore.systemPrompt
                                : self.noteSystemPrompt,
                            context: resolvedContext,
                            processingStatus: "Error: \(error.localizedDescription)",
                            intent: .dictation,
                            audioFileName: savedAudioFile?.fileName
                        )
                        self.audioRecorder.cleanup()
                        self.refreshAvailableMicrophonesIfNeeded()
                    }
                }
            }
        }
    }

    static func resolvedSystemPrompt(_ customSystemPrompt: String) -> String {
        customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? PostProcessingService.defaultSystemPrompt
            : customSystemPrompt
    }

    private func recordPipelineHistoryEntry(
        rawTranscript: String,
        postProcessedTranscript: String,
        postProcessingPrompt: String,
        systemPrompt: String,
        context: AppContext,
        processingStatus: String,
        intent: SessionIntent,
        audioFileName: String? = nil
    ) {
        let newEntry = PipelineHistoryItem(
            intent: intent.persistedIntent,
            selectedText: intent.persistedSelectedText,
            capturedSelection: context.selectedText,
            timestamp: Date(),
            rawTranscript: rawTranscript,
            postProcessedTranscript: postProcessedTranscript,
            postProcessingPrompt: postProcessingPrompt,
            systemPrompt: systemPrompt,
            contextSummary: context.contextSummary,
            contextSystemPrompt: context.contextSystemPrompt,
            contextPrompt: context.contextPrompt,
            contextScreenshotDataURL: context.screenshotDataURL,
            contextScreenshotStatus: context.screenshotError
                ?? "available (\(context.screenshotMimeType ?? "image"))",
            postProcessingStatus: processingStatus,
            debugStatus: debugStatusMessage,
            customVocabulary: customVocabulary,
            audioFileName: audioFileName,
            contextAppName: context.appName,
            contextBundleIdentifier: context.bundleIdentifier,
            contextWindowTitle: context.windowTitle
        )
        do {
            let removedAudioFileNames = try pipelineHistoryStore.append(newEntry, maxCount: maxPipelineHistoryCount)
            for audioFileName in removedAudioFileNames {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory = pipelineHistoryStore.loadAllHistory()
        } catch {
            errorMessage = "Unable to save run history entry: \(error.localizedDescription)"
        }
    }

    func toggleDebugOverlay() {
        if isDebugOverlayActive {
            stopDebugOverlay()
        } else {
            startDebugOverlay()
        }
    }

    private func startDebugOverlay() {
        isDebugOverlayActive = true
        clearPendingOverlayDismissToken()
        overlayManager.showRecording()

        // Simulate audio levels with a timer
        var phase: Double = 0.0
        debugOverlayTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            phase += 0.15
            // Generate a fake audio level that oscillates like speech
            let base = 0.3 + 0.2 * sin(phase)
            let noise = Float.random(in: -0.15...0.15)
            let level = min(max(Float(base) + noise, 0.0), 1.0)
            self.overlayManager.updateAudioLevel(level)
        }
    }

    private func stopDebugOverlay() {
        debugOverlayTimer?.invalidate()
        debugOverlayTimer = nil
        isDebugOverlayActive = false
        clearPendingOverlayDismissToken()
        overlayManager.dismiss()
    }

    private func clearPendingOverlayDismissToken() {
        pendingOverlayDismissToken = nil
    }

    @MainActor
    private func showPostTranscriptionUpdateReminderIfNeeded() -> Bool {
        if debugShowsUpdateReminderAfterDictation {
            showDebugUpdateAvailableOverlay()
            return true
        }

        let updateManager = UpdateManager.shared
        guard updateManager.shouldShowPostTranscriptionReminder() else { return false }

        let dismissToken = UUID()
        pendingOverlayDismissToken = dismissToken
        updateManager.markPostTranscriptionReminderShown()
        overlayManager.showUpdateAvailable(version: updateManager.latestReleaseVersion)

        DispatchQueue.main.asyncAfter(deadline: .now() + postTranscriptionUpdateReminderDuration) { [weak self] in
            guard let self, self.pendingOverlayDismissToken == dismissToken else { return }
            self.pendingOverlayDismissToken = nil
            self.overlayManager.dismiss()
        }

        return true
    }

    @MainActor
    func showDebugUpdateAvailableOverlay() {
        let updateManager = UpdateManager.shared
        let version = updateManager.latestReleaseVersion.isEmpty ? "9.9.9" : updateManager.latestReleaseVersion
        let dismissToken = UUID()
        if isDebugOverlayActive || debugOverlayTimer != nil {
            stopDebugOverlay()
        }
        pendingOverlayDismissToken = dismissToken
        overlayManager.showUpdateAvailable(version: version)

        DispatchQueue.main.asyncAfter(deadline: .now() + postTranscriptionUpdateReminderDuration) { [weak self] in
            guard let self, self.pendingOverlayDismissToken == dismissToken else { return }
            self.pendingOverlayDismissToken = nil
            self.overlayManager.dismiss()
        }
    }

    @MainActor
    private func handleUpdateOverlayPressed() {
        clearPendingOverlayDismissToken()
        overlayManager.dismiss()
        selectedSettingsTab = .general
        NotificationCenter.default.post(name: .showSettings, object: nil)

        DispatchQueue.main.async {
            if UpdateManager.shared.updateAvailable {
                UpdateManager.shared.showUpdateAlert()
            }
        }
    }

    private func scheduleOverlayDismissAfterFailureIndicator(after delay: TimeInterval) {
        let dismissToken = UUID()
        pendingOverlayDismissToken = dismissToken
        overlayManager.showFailureIndicator()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.pendingOverlayDismissToken == dismissToken else { return }
            self.pendingOverlayDismissToken = nil
            self.overlayManager.dismiss()
        }
    }

    func toggleDebugPanel() {
        selectedSettingsTab = .runLog
        NotificationCenter.default.post(name: .showSettings, object: nil)
    }

    func writeTranscriptToPasteboard(_ transcript: String) -> PendingClipboardRestore? {
        clipboardController.writeTranscript(
            transcript,
            preserveClipboard: preserveClipboard,
            keepInClipboardHistory: keepDictationInClipboardHistory
        )
    }

    func restoreClipboardIfNeeded(_ pendingRestore: PendingClipboardRestore?) {
        clipboardController.restoreIfNeeded(pendingRestore)
    }

    func pasteAtCursorWhenShortcutReleased(completion: (() -> Void)? = nil) {
        clipboardController.pasteWhenShortcutReleased(
            isShortcutPressed: { [weak self] in
                self?.hotkeyManager.hasPressedShortcutInputs ?? false
            },
            completion: completion
        )
    }

    private func pressEnterAfterPaste(completion: (() -> Void)? = nil) {
        clipboardController.pressEnterAfterPaste(completion: completion)
    }

    private func cancelRecordingInitializationTimer() {
        recordingInitializationTimer?.cancel()
        recordingInitializationTimer = nil
    }

    private func scheduleReadyStatusReset(after delay: TimeInterval, matching statuses: Set<String>? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if let statuses, !statuses.contains(self.statusText) {
                return
            }
            self.statusText = "Ready"
        }
    }
}
