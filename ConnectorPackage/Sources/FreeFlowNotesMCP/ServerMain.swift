import Foundation
import Logging
import MCP
import FreeFlowNotesCore

struct FreeFlowNotesServer {
    let store: NotesStore

    func run() async throws {
        let server = Server(name: "freeflow-notes", version: "0.1.0", capabilities: .init(tools: .init()))
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [
                Tool(name: "usage_guidelines", description: "Returns concise cross-tool rules for FreeFlow Markdown notes, IDs, attachments, revisions, and safety.", inputSchema: .object(["type": "object", "properties": .object([:])]), annotations: .init(readOnlyHint: true, destructiveHint: false)),
                Tool(name: "notes", description: "Read or mutate FreeFlow notes. The required action is one of list, read, create, update, delete, move, create_folder, rename_folder, or attach.", inputSchema: .object(["type": "object", "properties": .object(["action": .object(["type": "string", "enum": .array(["list", "read", "create", "update", "delete", "move", "create_folder", "rename_folder", "attach"])]), "note_id": schemaString("Stable note UUID"), "content": schemaString("Markdown content"), "title": schemaString("Optional title"), "folder": schemaString("Relative folder"), "revision": schemaString("Revision returned by read"), "from": schemaString("Source folder"), "to": schemaString("Destination folder"), "name": schemaString("Folder or attachment name"), "path": schemaString("Relative attachment source path")]), "required": .array(["action"])]), annotations: .init(readOnlyHint: false, destructiveHint: true)),
                Tool(name: "search_notes", description: "Searches FreeFlow notes with BM25 relevance ranking and cursor pagination.", inputSchema: .object(["type": "object", "properties": .object(["query": schemaString("Search text"), "folder": schemaString("Optional relative folder"), "limit": .object(["type": "integer", "description": "Maximum results per page", "minimum": 1, "maximum": 100]), "cursor": schemaString("Opaque pagination cursor")]), "required": .array(["query"])]), annotations: .init(readOnlyHint: true, destructiveHint: false))
            ])
        }
        await server.withMethodHandler(CallTool.self) { [store] params in
            do {
                let args = params.arguments ?? [:]
                switch params.name {
                case "usage_guidelines":
                    return .init(content: [.text(text: "FreeFlow Notes\n\nTools: usage_guidelines documents cross-tool rules; notes reads and mutates notes with an explicit action; search_notes ranks notes with BM25 and cursor pagination.\n\nRules: note_id is the stable UUID from the Markdown filename. Paths are relative to the notes root. Preserve Markdown links/images and note-scoped attachment paths exactly. Include the latest revision when updating. Treat delete and folder operations as destructive. Use returned search cursors unchanged." )])
                case "notes":
                    return try handleNotes(args)
                case "search_notes":
                    guard let query = args["query"]?.stringValue else { throw StoreError.invalidArgument("query is required") }
                    let result = BM25Search().search(try store.list(), query: query, folder: args["folder"]?.stringValue, limit: args["limit"]?.intValue ?? 20, cursor: args["cursor"]?.stringValue)
                    let items: [Value] = zip(result.results, result.scores).map { note, score in .object(["note_id": .string(note.id), "title": .string(note.title), "folder": .string(note.folder), "score": .double(score), "snippet": .string(snippet(note.content, query: query))]) }
                    return .init(content: [.text(text: "Found \(items.count) matching notes.")], structuredContent: .object(["results": .array(items), "next_cursor": result.next.map(Value.string) ?? .null, "has_more": .bool(result.next != nil)]))
                default:
                    throw StoreError.invalidArgument("Unknown tool: \(params.name)")
                }
            } catch {
                return .init(content: [.text(text: error.localizedDescription)], isError: true)
            }
        }
        let transport = ChatGPTCompatibleStdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    private func schemaString(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private func handleNotes(_ args: [String: Value]) throws -> CallTool.Result {
        guard let action = args["action"]?.stringValue else { throw StoreError.invalidArgument("action is required") }
        switch action {
        case "list": return try result(try store.list())
        case "read":
            guard let id = args["note_id"]?.stringValue else { throw StoreError.invalidArgument("note_id is required") }
            let note = try store.read(id: id)
            return try result([note], revisions: [store.revision(for: note)])
        case "create":
            let note = try store.save(title: args["title"]?.stringValue, folder: args["folder"]?.stringValue ?? "", content: args["content"]?.stringValue ?? "")
            return try result([note], revisions: [store.revision(for: note)])
        case "update":
            guard let id = args["note_id"]?.stringValue, let content = args["content"]?.stringValue else { throw StoreError.invalidArgument("note_id and content are required") }
            let old = try store.read(id: id)
            let note = try store.save(id: id, title: args["title"]?.stringValue ?? old.title, folder: old.folder, content: content, expectedRevision: args["revision"]?.stringValue)
            return try result([note], revisions: [store.revision(for: note)])
        case "delete":
            guard let id = args["note_id"]?.stringValue else { throw StoreError.invalidArgument("note_id is required") }
            try store.delete(id: id, expectedRevision: args["revision"]?.stringValue)
            return .init(content: [.text(text: "Deleted note \(id).")])
        case "create_folder":
            guard let folder = args["folder"]?.stringValue, !folder.isEmpty else { throw StoreError.invalidArgument("folder is required") }
            try store.createFolder(folder)
            return .init(content: [.text(text: "Created folder \(folder).")])
        case "rename_folder":
            guard let from = args["from"]?.stringValue, let to = args["to"]?.stringValue else { throw StoreError.invalidArgument("from and to are required") }
            try store.renameFolder(from: from, to: to)
            return .init(content: [.text(text: "Renamed folder \(from) to \(to).")])
        case "move":
            guard let id = args["note_id"]?.stringValue, let folder = args["folder"]?.stringValue else { throw StoreError.invalidArgument("note_id and folder are required") }
            let note = try store.move(id: id, to: folder)
            return try result([note], revisions: [store.revision(for: note)])
        case "attach":
            guard let id = args["note_id"]?.stringValue, let path = args["path"]?.stringValue else { throw StoreError.invalidArgument("note_id and path are required") }
            let relativePath = try store.attach(id: id, sourcePath: path, fileName: args["name"]?.stringValue)
            return .init(content: [.text(text: "Attached \(relativePath).")], structuredContent: .object(["note_id": .string(id), "path": .string(relativePath)]))
        default:
            throw StoreError.invalidArgument("Action '\(action)' is not implemented yet")
        }
    }

    private func result(_ notes: [ConnectorNote], revisions: [String]? = nil) throws -> CallTool.Result {
        let items: [Value] = notes.enumerated().map { index, note in .object(["note_id": .string(note.id), "title": .string(note.title), "folder": .string(note.folder), "content": .string(note.content), "modified": .string(ISO8601DateFormatter().string(from: note.modified)), "revision": .string(revisions?[safe: index] ?? store.revision(for: note))]) }
        return .init(content: [.text(text: "Returned \(items.count) note(s).")], structuredContent: .object(["notes": .array(items)]))
    }

    private func snippet(_ content: String, query: String) -> String { String(content.replacingOccurrences(of: "\n", with: " ").prefix(240)) }
}

/// Bridges ChatGPT's newer initialize capability fields to SDK 0.12.x.
/// The SDK currently models `experimental` as string values and does not model
/// `extensions`, so decoding ChatGPT's nested capability objects fails before
/// the server's initialize handler runs.
private actor ChatGPTCompatibleStdioTransport: Transport {
    private let base = StdioTransport()
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let stream: AsyncThrowingStream<Data, Error>
    private var connected = false

    nonisolated let logger = Logger(label: "freeflow-notes.mcp.stdio")

    init() {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async throws {
        guard !connected else { return }
        try await base.connect()
        connected = true
        let incoming = await base.receive()
        Task { [weak self] in
            guard let self else { return }
            do {
                for try await message in incoming {
                    await self.continuation.yield(self.sanitize(message))
                }
                await self.continuation.finish()
            } catch {
                await self.continuation.finish(throwing: error)
            }
        }
    }

    func disconnect() async {
        connected = false
        await base.disconnect()
        continuation.finish()
    }

    func send(_ data: Data) async throws { try await base.send(data) }

    func receive() -> AsyncThrowingStream<Data, Error> { stream }

    private func sanitize(_ data: Data) -> Data {
        guard var message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              message["method"] as? String == "initialize",
              var params = message["params"] as? [String: Any],
              var capabilities = params["capabilities"] as? [String: Any]
        else { return data }
        capabilities.removeValue(forKey: "experimental")
        capabilities.removeValue(forKey: "extensions")
        params["capabilities"] = capabilities
        message["params"] = params
        return (try? JSONSerialization.data(withJSONObject: message)) ?? data
    }
}

private extension Array { subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil } }

@main struct Main {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "doctor" {
            let root = NotesStore().root
            print("FreeFlow notes root: \(root.path)")
            print(FileManager.default.isReadableFile(atPath: root.deletingLastPathComponent().path) ? "Notes directory is accessible." : "Notes directory will be created on first write.")
            return
        }
        if arguments.first == "config" || arguments.first == "install" {
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
            print("{\n  \"mcpServers\": {\n    \"freeflow-notes\": {\n      \"command\": \"\(executable)\",\n      \"args\": [\"serve\", \"--stdio\"]\n    }\n  }\n}")
            return
        }
        do { try await FreeFlowNotesServer(store: NotesStore()).run() }
        catch { FileHandle.standardError.write(Data("freeflow-notes-mcp: \(error)\n".utf8)); exit(1) }
    }
}
