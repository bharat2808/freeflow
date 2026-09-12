import Foundation
import os.log

private let transcriptProcessingLog = OSLog(
    subsystem: "com.zachlatta.freeflow",
    category: "TranscriptProcessing"
)

enum TranscriptProcessingOutcome: Sendable {
    case skippedEmptyRawTranscript
    case voiceMacro(command: String)
    case postProcessingSucceeded
    case postProcessingFailedFallback
    case preservedExactWording
    case preservedExactWordingTranslated
    case preservedExactWordingTranslationFailedFallback
    case commandModeSucceeded(invocation: CommandInvocation)
    case commandModeFailedFallback(invocation: CommandInvocation)

    func statusMessage(isRetry: Bool = false) -> String {
        switch self {
        case .skippedEmptyRawTranscript:
            return "Skipped macros and post-processing for empty raw transcript"
        case .voiceMacro(let command):
            return "Voice macro used: \(command)"
        case .postProcessingSucceeded:
            return isRetry ? "Post-processing succeeded (retried)" : "Post-processing succeeded"
        case .postProcessingFailedFallback:
            return isRetry
                ? "Post-processing failed on retry, using raw transcript"
                : "Post-processing failed, using raw transcript"
        case .preservedExactWording:
            return "Preserved exact wording, skipped post-processing"
        case .preservedExactWordingTranslated:
            return "Preserved exact wording, translated to output language"
        case .preservedExactWordingTranslationFailedFallback:
            return "Verbatim translation failed, using untranslated raw transcript"
        case .commandModeSucceeded(let invocation):
            return "Edit mode succeeded (\(invocation.rawValue))"
        case .commandModeFailedFallback(let invocation):
            return "Edit mode failed, using selected text (\(invocation.rawValue))"
        }
    }

    var usedRawTranscriptFallback: Bool {
        if case .postProcessingFailedFallback = self { return true }
        return false
    }
}

enum TranscriptProcessor {
    static func process(
        _ rawTranscript: String,
        intent: SessionIntent,
        context: AppContext,
        postProcessingService: PostProcessingService,
        macroMatcher: VoiceMacroMatcher,
        customVocabulary: String,
        customSystemPrompt: String,
        outputLanguage: String = "",
        preserveExactWording: Bool
    ) async -> (finalTranscript: String, outcome: TranscriptProcessingOutcome, prompt: String) {
        let trimmedRawTranscript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedRawTranscript.isEmpty else {
            return ("", .skippedEmptyRawTranscript, "")
        }
        if Task.isCancelled {
            return (trimmedRawTranscript, .postProcessingFailedFallback, "")
        }

        if case .command(let invocation, let selectedText) = intent {
            do {
                let result = try await postProcessingService.commandTransform(
                    selectedText: selectedText,
                    voiceCommand: rawTranscript,
                    context: context,
                    customVocabulary: customVocabulary,
                    outputLanguage: outputLanguage
                )
                return (result.transcript, .commandModeSucceeded(invocation: invocation), result.prompt)
            } catch {
                os_log(.error, log: transcriptProcessingLog, "Edit mode failed: %{public}@", error.localizedDescription)
                return (selectedText, .commandModeFailedFallback(invocation: invocation), "")
            }
        }

        if let macro = macroMatcher.match(transcript: trimmedRawTranscript) {
            os_log(.info, log: transcriptProcessingLog, "Voice macro triggered: %{public}@", macro.command)
            return (macro.payload, .voiceMacro(command: macro.command), "")
        }

        if preserveExactWording {
            let targetLanguage = outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            if targetLanguage.isEmpty {
                return (trimmedRawTranscript, .preservedExactWording, "")
            }
            do {
                let result = try await postProcessingService.translateVerbatim(
                    transcript: trimmedRawTranscript,
                    targetLanguage: targetLanguage
                )
                return (result.transcript, .preservedExactWordingTranslated, result.prompt)
            } catch {
                os_log(
                    .error,
                    log: transcriptProcessingLog,
                    "Verbatim translation failed: %{public}@",
                    error.localizedDescription
                )
                return (trimmedRawTranscript, .preservedExactWordingTranslationFailedFallback, "")
            }
        }

        do {
            let result = try await postProcessingService.postProcess(
                transcript: trimmedRawTranscript,
                context: context,
                customVocabulary: customVocabulary,
                customSystemPrompt: customSystemPrompt,
                outputLanguage: outputLanguage
            )
            return (result.transcript, .postProcessingSucceeded, result.prompt)
        } catch {
            os_log(.error, log: transcriptProcessingLog, "Post-processing failed: %{public}@", error.localizedDescription)
            return (trimmedRawTranscript, .postProcessingFailedFallback, "")
        }
    }
}
