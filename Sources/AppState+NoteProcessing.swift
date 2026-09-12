import Foundation
import os.log

private let noteProcessingLog = OSLog(
    subsystem: "com.zachlatta.freeflow",
    category: "NoteProcessing"
)

private struct NoteFormattingResult: Sendable {
    let finalTranscript: String
    let outcome: TranscriptProcessingOutcome
    let prompt: String
}

private enum NoteProcessingRaceResult: Sendable {
    case completed(finalTranscript: String, outcome: TranscriptProcessingOutcome, prompt: String)
    case timedOut
}

extension AppState {
    func processTextPreset(_ preset: TextActionPreset, text: String) async throws -> String {
        let selectedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedText.isEmpty else {
            throw PostProcessingError.invalidInput("Select some note text first.")
        }

        let context = AppContext(
            appName: nil,
            bundleIdentifier: nil,
            windowTitle: nil,
            selectedText: selectedText,
            currentActivity: "Editing a Markdown note.",
            contextSystemPrompt: nil,
            contextPrompt: nil,
            screenshotDataURL: nil,
            screenshotMimeType: nil,
            screenshotError: nil
        )
        let service = PostProcessingService(
            apiKey: apiKey,
            baseURL: apiBaseURL,
            preferredModel: postProcessingModel,
            preferredFallbackModel: postProcessingFallbackModel,
            instructionExecutionGuardEnabled: instructionExecutionGuardEnabled
        )
        let result = try await service.postProcess(
            transcript: selectedText,
            context: context,
            customVocabulary: customVocabulary,
            customSystemPrompt: preset.instruction,
            outputLanguage: outputLanguage
        )
        let processed = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !processed.isEmpty else {
            throw PostProcessingError.emptyOutput
        }
        return processed
    }

    func processNoteTranscript(
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

    func processNoteTranscriptWithDeadline(
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
                log: noteProcessingLog,
                "note processing exceeded overall deadline of %.0fs; using raw transcript",
                timeoutSeconds
            )
            return (rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines), .postProcessingFailedFallback, "")
        }
    }

    func processNoteUpdate(
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
            os_log(.error, log: noteProcessingLog, "Note update failed: %{public}@", error.localizedDescription)
            return (existingNote.markdown, .postProcessingFailedFallback, "")
        }
    }
}
