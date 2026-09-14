import Foundation

public struct ConnectorNote: Codable, Sendable {
    public let id: String
    public let title: String
    public let folder: String
    public let content: String
    public let modified: Date
    public init(id: String, title: String, folder: String, content: String, modified: Date) { self.id = id; self.title = title; self.folder = folder; self.content = content; self.modified = modified }
}

public struct NotesStore: Sendable {
    public let root: URL

    public init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FreeFlow Notes/notes", isDirectory: true)) {
        self.root = root.standardizedFileURL
    }

    public func list() throws -> [ConnectorNote] {
        try loadFiles().sorted { $0.modified > $1.modified }
    }

    public func read(id: String) throws -> ConnectorNote {
        guard let note = try loadFiles().first(where: { $0.id == id }) else { throw StoreError.notFound(id) }
        return note
    }

    public func save(id: String = UUID().uuidString, title: String? = nil, folder: String = "", content: String, expectedRevision: String? = nil) throws -> ConnectorNote {
        let safeFolder = try normalizedFolder(folder)
        let safeID = try normalizedID(id)
        let folderURL = root.appendingPathComponent(safeFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let url = folderURL.appendingPathComponent("\(safeID).md")
        if let expectedRevision, FileManager.default.fileExists(atPath: url.path), revision(for: url) != expectedRevision {
            throw StoreError.revisionConflict
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        return ConnectorNote(id: safeID, title: titleFrom(content, fallback: title), folder: safeFolder, content: content, modified: Date())
    }

    public func delete(id: String, expectedRevision: String? = nil) throws {
        let note = try read(id: id)
        let url = noteURL(note)
        if let expectedRevision, revision(for: url) != expectedRevision { throw StoreError.revisionConflict }
        try FileManager.default.removeItem(at: url)
        let attachments = url.deletingPathExtension().appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: attachments.path) { try FileManager.default.removeItem(at: attachments) }
    }

    public func move(id: String, to folder: String) throws -> ConnectorNote {
        let note = try read(id: id)
        let destinationFolder = try normalizedFolder(folder)
        let destination = root.appendingPathComponent(destinationFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sourceURL = noteURL(note)
        let destinationURL = destination.appendingPathComponent(note.id + ".md")
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        let sourceAttachments = sourceURL.deletingPathExtension().appendingPathComponent(note.id, isDirectory: true)
        let destinationAttachments = destination.appendingPathComponent(note.id, isDirectory: true)
        if FileManager.default.fileExists(atPath: sourceAttachments.path) {
            try FileManager.default.moveItem(at: sourceAttachments, to: destinationAttachments)
        }
        return try read(id: id)
    }

    public func createFolder(_ folder: String) throws {
        let safeFolder = try normalizedFolder(folder)
        guard !safeFolder.isEmpty else { throw StoreError.invalidArgument("folder is required") }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(safeFolder, isDirectory: true), withIntermediateDirectories: true)
    }

    public func renameFolder(from: String, to: String) throws {
        let source = try normalizedFolder(from), destination = try normalizedFolder(to)
        guard !source.isEmpty, !destination.isEmpty else { throw StoreError.invalidArgument("from and to are required") }
        try FileManager.default.moveItem(at: root.appendingPathComponent(source), to: root.appendingPathComponent(destination))
    }

    public func attach(id: String, sourcePath: String, fileName: String?) throws -> String {
        let note = try read(id: id)
        let source = root.appendingPathComponent(sourcePath).standardizedFileURL
        guard source.path.hasPrefix(root.path + "/"), FileManager.default.isReadableFile(atPath: source.path) else { throw StoreError.pathNotAllowed }
        let destinationDirectory = noteURL(note).deletingPathExtension().appendingPathComponent(note.id, isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destinationName = fileName?.isEmpty == false ? fileName! : source.lastPathComponent
        let destination = destinationDirectory.appendingPathComponent(destinationName)
        try FileManager.default.copyItem(at: source, to: destination)
        return "\(note.id)/\(destination.lastPathComponent)"
    }

    func folders() throws -> [String] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let urls = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])?.compactMap { $0 as? URL } ?? []
        return Array(Set(urls.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            return relative.isEmpty ? nil : relative
        })).sorted()
    }

    public func revision(for note: ConnectorNote) -> String { revision(for: noteURL(note)) }

    private func loadFiles() throws -> [ConnectorNote] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let urls = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey])?.compactMap { $0 as? URL } ?? []
        return try urls.filter { $0.pathExtension == "md" }.map { url in
            let folder = url.deletingLastPathComponent().path.replacingOccurrences(of: root.path, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let id = url.deletingPathExtension().lastPathComponent
            let content = try String(contentsOf: url, encoding: .utf8)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return ConnectorNote(id: id, title: titleFrom(content, fallback: nil), folder: folder, content: content, modified: modified)
        }
    }

    private func noteURL(_ note: ConnectorNote) -> URL { root.appendingPathComponent(note.folder, isDirectory: true).appendingPathComponent(note.id + ".md") }
    private func normalizedID(_ id: String) throws -> String {
        guard UUID(uuidString: id) != nil else { throw StoreError.invalidArgument("note_id must be a UUID") }
        return id.uppercased()
    }
    private func normalizedFolder(_ folder: String) throws -> String {
        let value = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.hasPrefix("/"), !value.split(separator: "/").contains("..") else { throw StoreError.pathNotAllowed }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private func titleFrom(_ content: String, fallback: String?) -> String {
        if let heading = content.split(separator: "\n").first(where: { $0.hasPrefix("# ") }) { return String(heading.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        return fallback?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? fallback! : "Untitled note"
    }
    private func revision(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values?.fileSize ?? 0)"
    }
}

public enum StoreError: LocalizedError {
    case notFound(String)
    case invalidArgument(String)
    case pathNotAllowed
    case revisionConflict
    public var errorDescription: String? {
        switch self {
        case .notFound(let id): return "Note not found: \(id)"
        case .invalidArgument(let message): return message
        case .pathNotAllowed: return "Path is outside the FreeFlow notes root."
        case .revisionConflict: return "The note changed after it was read. Re-read it before updating."
        }
    }
}

public struct BM25Search: Sendable {
    public init() {}
    public func search(_ notes: [ConnectorNote], query: String, folder: String?, limit: Int, cursor: String?) -> (results: [ConnectorNote], scores: [Double], next: String?) {
        let terms = tokenize(query)
        guard !terms.isEmpty else { return ([], [], nil) }
        let candidates = notes.filter { folder == nil || $0.folder == folder }
        let averageLength = max(1, candidates.map { tokenize($0.content).count }.reduce(0, +) / max(1, candidates.count))
        let scored = candidates.compactMap { note -> (ConnectorNote, Double)? in
            let titleTerms = tokenize(note.title), bodyTerms = tokenize(note.content)
            let score = terms.reduce(0.0) { total, term in
                let frequency = Double(bodyTerms.filter { $0 == term }.count) + 2.0 * Double(titleTerms.filter { $0 == term }.count)
                guard frequency > 0 else { return total }
                let length = Double(max(1, bodyTerms.count)), k1 = 1.2, b = 0.75
                return total + frequency * 2.2 / (frequency + k1 * (1 - b + b * length / Double(averageLength)))
            }
            return score > 0 ? (note, score) : nil
        }.sorted { lhs, rhs in lhs.1 != rhs.1 ? lhs.1 > rhs.1 : (lhs.0.modified != rhs.0.modified ? lhs.0.modified > rhs.0.modified : lhs.0.id < rhs.0.id) }
        let start = Int(cursor ?? "0") ?? 0
        let page = Array(scored.dropFirst(max(0, start)).prefix(max(1, min(limit, 100))))
        let next = start + page.count < scored.count ? String(start + page.count) : nil
        return (page.map(\.0), page.map(\.1), next)
    }
    private func tokenize(_ text: String) -> [String] { text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 } }
}
