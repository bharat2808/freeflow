import Foundation

extension AppState {
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
}
