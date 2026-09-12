import AVFoundation
import Foundation

struct AudioChunkSet {
    let urls: [URL]
    let temporaryDirectory: URL?

    func cleanup() {
        guard let temporaryDirectory else { return }
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}

enum AudioChunker {
    /// Three-minute chunks reduce boundary seams while staying comfortably
    /// below the local transcription timeout and memory budget.
    static let defaultChunkDuration: TimeInterval = 180
    static let defaultOverlapDuration: TimeInterval = 0.5

    static func split(
        fileURL: URL,
        maxDuration: TimeInterval = defaultChunkDuration,
        overlapDuration: TimeInterval = defaultOverlapDuration
    ) throws -> AudioChunkSet {
        let input = try AVAudioFile(forReading: fileURL)
        let format = input.processingFormat
        guard maxDuration > 0, overlapDuration >= 0, overlapDuration < maxDuration else {
            throw AudioRecorderError.invalidInputFormat("Invalid audio chunk duration.")
        }
        let framesPerChunk = AVAudioFrameCount(max(1, Int(format.sampleRate * maxDuration)))
        let overlapFrames = AVAudioFrameCount(max(0, Int(format.sampleRate * overlapDuration)))
        let totalFrames = input.length

        guard totalFrames > Int64(framesPerChunk) else {
            return AudioChunkSet(urls: [fileURL], temporaryDirectory: nil)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("freeflow-note-chunks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            var urls: [URL] = []
            var startFrame: Int64 = 0
            var index = 0
            while startFrame < totalFrames {
                input.framePosition = startFrame
                let remaining = totalFrames - startFrame
                let frameCount = AVAudioFrameCount(min(Int64(framesPerChunk), remaining))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                    throw AudioRecorderError.invalidInputFormat("Could not allocate an audio chunk buffer.")
                }
                try input.read(into: buffer, frameCount: frameCount)
                let url = directory.appendingPathComponent("chunk-\(index).wav")
                let output = try AVAudioFile(
                    forWriting: url,
                    settings: input.fileFormat.settings,
                    commonFormat: format.commonFormat,
                    interleaved: format.isInterleaved
                )
                try output.write(from: buffer)
                urls.append(url)
                let reachedEnd = startFrame + Int64(frameCount) >= totalFrames
                let advance = Int64(frameCount) - (reachedEnd ? 0 : Int64(min(overlapFrames, frameCount - 1)))
                startFrame += max(1, advance)
                index += 1
            }
            return AudioChunkSet(urls: urls, temporaryDirectory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
