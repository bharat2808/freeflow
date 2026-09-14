import Foundation
import AppKit
import os.log

private let transcriptionPipelineLog = OSLog(
    subsystem: "com.zachlatta.freeflow",
    category: "TranscriptionPipeline"
)

extension AppState {
    static func statusMessage(
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

    func processTranscript(
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

    func processGeneratedRequest(
        _ instruction: String,
        context: AppContext,
        postProcessingService: PostProcessingService
    ) async -> (finalTranscript: String, outcome: TranscriptProcessingOutcome, prompt: String) {
        do {
            let result = try await postProcessingService.generate(
                instruction: instruction,
                context: context,
                customVocabulary: customVocabulary,
                customSystemPrompt: generateSystemPrompt,
                outputLanguage: outputLanguage
            )
            return (result.transcript, .generationSucceeded, result.prompt)
        } catch {
            os_log(.error, log: transcriptionPipelineLog, "generation failed: %{public}@", error.localizedDescription)
            await MainActor.run {
                self.errorMessage = "Generation failed: \(error.localizedDescription)"
            }
            return ("", .generationFailed, "")
        }
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
                log: transcriptionPipelineLog,
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

    func stopAndTranscribe() {
        let stopStartedAt = CFAbsoluteTimeGetCurrent()
        cancelPendingShortcutStart()
        cancelRecordingInitializationTimer()
        shortcutSessionController.reset()
        let sessionIntent = currentSessionIntent
        pendingGeneration = false
        let shouldSaveAsNote = activeNoteRecording
        let generationNoteContext = activeGenerationNoteContext
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
            sessionContext = capturedContext?.withNoteGenerationContext(generationNoteContext)
        }
        activeGenerationNoteContext = nil
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
                        os_log(.info, log: transcriptionPipelineLog, "awaited in-flight context capture")
                        appContext = inFlightContext.withNoteGenerationContext(generationNoteContext)
                    } else {
                        appContext = self.fallbackContextAtStop().withNoteGenerationContext(generationNoteContext)
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
                    if sessionIntent.isGenerateMode {
                        result = await self.processGeneratedRequest(
                            parsedTranscript.transcript,
                            context: appContext,
                            postProcessingService: postProcessingService
                        )
                    } else if let noteUpdateTarget {
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
                        log: transcriptionPipelineLog,
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
                                : (sessionIntent.isGenerateMode
                                    ? (self.generateSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? PostProcessingService.defaultGenerateSystemPrompt
                                        : self.generateSystemPrompt)
                                    : Self.resolvedSystemPrompt(self.customSystemPrompt)),
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
                        if sessionIntent.isGenerateMode,
                           case .generationFailed = result.outcome {
                            self.statusText = "Generation failed"
                            self.overlayManager.dismiss()
                        } else if trimmedFinalTranscript.isEmpty {
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

                        self.scheduleReadyStatusReset(after: 3, matching: [completionStatusText, "Nothing to transcribe", "Generation failed", saveFailureStatusText, "Note updated", "Note could not be updated", "Preview ready"])
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
}
