import AppKit
import SwiftUI

final class NotesLibrary: ObservableObject {
    @Published var notes: [MarkdownNote] = []
    @Published var selectedID: UUID?
    @Published var error: String?
    @Published private(set) var savedFolders: [String] = []
    private let store = MarkdownNoteStore.standard
    private let saveQueue = DispatchQueue(label: "freeflow.notes.save", qos: .utility)
    private var pendingSaveWorkItems: [UUID: DispatchWorkItem] = [:]

    init() { reload() }

    deinit {
        pendingSaveWorkItems.values.forEach { $0.cancel() }
    }

    func reload() {
        do {
            notes = try store.load()
            savedFolders = store.loadFolders()
            error = nil
        }
        catch { self.error = "Could not load notes: \(error.localizedDescription)" }
    }

    func createFolder(_ folder: String) {
        do {
            try store.createFolder(folder)
            savedFolders = store.loadFolders()
            error = nil
        } catch {
            self.error = "Could not create folder: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func create(_ markdown: String) -> Bool {
        let note = MarkdownNote(id: UUID(), markdown: markdown, modified: Date())
        do {
            try store.save(note)
            notes.insert(note, at: 0)
            selectedID = note.id
            error = nil
            return true
        } catch {
            self.error = "Could not save note: \(error.localizedDescription). The transcript is available in the run log."
            return false
        }
    }

    func edit(id: UUID, markdown: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].markdown = markdown
        notes[index].modified = Date()
        let note = notes[index]
        pendingSaveWorkItems[id]?.cancel()
        let store = self.store
        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem { [weak self] in
            do {
                try store.save(note)
                DispatchQueue.main.async {
                    guard let self, self.pendingSaveWorkItems[id] === workItem else { return }
                    self.pendingSaveWorkItems[id] = nil
                    self.error = nil
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.pendingSaveWorkItems[id] === workItem else { return }
                    self.pendingSaveWorkItems[id] = nil
                    self.error = "Changes are not saved: \(error.localizedDescription)"
                }
            }
        }
        pendingSaveWorkItems[id] = workItem
        saveQueue.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    @discardableResult
    func update(id: UUID, markdown: String) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return false }
        let updated = MarkdownNote(
            id: id,
            markdown: markdown,
            modified: Date(),
            folder: notes[index].folder
        )
        pendingSaveWorkItems[id]?.cancel()
        do {
            try store.save(updated)
            notes[index] = updated
            error = nil
            return true
        } catch {
            self.error = "Could not update note: \(error.localizedDescription)"
            return false
        }
    }

    var folders: [String] {
        Array(Set(notes.map(\.folder)).union(savedFolders)).sorted { lhs, rhs in
            if lhs.isEmpty { return true }
            if rhs.isEmpty { return false }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    func moveSelected(to folder: String) {
        guard let selectedID,
              let index = notes.firstIndex(where: { $0.id == selectedID }) else { return }
        do {
            notes[index] = try store.move(notes[index], toFolder: folder)
            notes.sort { $0.modified > $1.modified }
            error = nil
        } catch {
            self.error = "Could not move note: \(error.localizedDescription)"
        }
    }

    func deleteSelected() {
        guard let selectedID,
              let index = notes.firstIndex(where: { $0.id == selectedID }) else { return }
        let note = notes[index]
        pendingSaveWorkItems[selectedID]?.cancel()
        pendingSaveWorkItems[selectedID] = nil
        do {
            try store.delete(note)
            notes.remove(at: index)
            self.selectedID = nil
            error = nil
        } catch {
            self.error = "Could not delete note: \(error.localizedDescription)"
        }
    }

    func renameFolder(from oldFolder: String, to newFolder: String) {
        let oldValue = oldFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue = newFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldValue.isEmpty, !newValue.isEmpty, oldValue != newValue else { return }
        do {
            try store.renameFolder(from: oldValue, to: newValue)
            let affected = notes.filter { $0.folder == oldValue || $0.folder.hasPrefix(oldValue + "/") }
            reload()
            selectedID = affected.first?.id
        } catch {
            self.error = "Could not rename folder: \(error.localizedDescription)"
            reload()
        }
    }

    func revealFiles() { NSWorkspace.shared.open(store.directory) }
}

struct NotesView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var library: NotesLibrary
    @State private var search = ""
    @State private var preview = false
    @State private var showMoveSheet = false
    @State private var destinationFolder = ""
    @State private var showCreateFolderSheet = false
    @State private var newFolderName = ""
    @State private var showRenameSheet = false
    @State private var renameFolderName = ""
    @State private var selectedFolderForRename: String?
    @State private var showDeleteConfirmation = false

    private var selectedFolder: String? {
        guard let selectedID = library.selectedID else { return nil }
        let folder = library.notes.first(where: { $0.id == selectedID })?.folder ?? ""
        return folder.isEmpty ? nil : folder
    }

    private var liveTranscript: String {
        let live = appState.liveNoteTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty { return live }
        return appState.lastRawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $library.selectedID) {
                ForEach(library.folders, id: \.self) { folder in
                    Section(folder.isEmpty ? "Inbox" : folder) {
                        ForEach(library.notes.filter {
                            $0.folder == folder && (search.isEmpty || $0.markdown.localizedCaseInsensitiveContains(search))
                        }) { note in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(note.title).font(.headline).lineLimit(2)
                                Text(note.modified, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                            .tag(note.id)
                            .contextMenu {
                                Button {
                                    library.selectedID = note.id
                                    destinationFolder = note.folder
                                    showMoveSheet = true
                                } label: {
                                    Label("Move note…", systemImage: "folder.badge.arrow.forward")
                                }
                                Button(role: .destructive) {
                                    library.selectedID = note.id
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("Delete note", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .contextMenu {
                        if !folder.isEmpty {
                            Button {
                                selectedFolderForRename = folder
                                renameFolderName = folder
                                showRenameSheet = true
                            } label: {
                                Label("Rename folder…", systemImage: "folder.badge.gearshape")
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search notes")
            .navigationTitle("Notes")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                if let error = library.error ?? appState.errorMessage {
                    Text(error).foregroundStyle(.red).padding()
                }
                if appState.isRecording || appState.isTranscribing {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            appState.noteUpdateTargetID == nil
                                ? "Taking note"
                                : (appState.noteVoiceAction == .append ? "Appending to note" : "Updating note"),
                            systemImage: appState.isRecording ? "waveform" : "ellipsis.circle"
                        )
                        .font(.headline)
                        .foregroundStyle(.tint)
                        ScrollView {
                            Text(liveTranscript.isEmpty ? "Listening…" : liveTranscript)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 150)
                    }
                    .padding(14)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                }
                if let note = library.notes.first(where: { $0.id == library.selectedID }) {
                    if preview {
                        ScrollView {
                            Text((try? AttributedString(markdown: note.markdown, options: .init(interpretedSyntax: .full))) ?? AttributedString(note.markdown))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(28)
                        }
                    } else {
                        TextEditor(text: Binding(get: {
                            library.notes.first(where: { $0.id == note.id })?.markdown ?? ""
                        }, set: { library.edit(id: note.id, markdown: $0) }))
                        .font(.system(.body, design: .monospaced)).padding(18)
                    }
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "waveform").font(.system(size: 42)).foregroundStyle(.tint)
                        Text("Speak your next note").font(.title)
                        Text("Stop recording to turn your words into a saved Markdown note.")
                            .foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                HStack {
                    Circle().fill(appState.isRecording ? Color.red : Color.secondary).frame(width: 7, height: 7)
                    Text(appState.statusText)
                    Spacer()
                    Text("Markdown · saved locally")
                }.font(.caption).foregroundStyle(.secondary).padding(12)
            }
        }
        .toolbar {
            Button { library.create("# Untitled note\n\n") } label: { Label("New note", systemImage: "square.and.pencil") }
            Button {
                newFolderName = ""
                showCreateFolderSheet = true
            } label: { Label("New folder", systemImage: "folder.badge.plus") }
            Button { appState.toggleRecording() } label: {
                Label(appState.isRecording ? "Stop & save" : "Record note", systemImage: appState.isRecording ? "stop.circle.fill" : "mic.fill")
            }.disabled(appState.isTranscribing)
            Toggle(isOn: $preview) { Label("Preview", systemImage: "eye") }
            Button { library.revealFiles() } label: { Label("Show files", systemImage: "folder") }
            Button { library.reload() } label: { Label("Refresh notes", systemImage: "arrow.clockwise") }
            Button {
                destinationFolder = library.notes.first(where: { $0.id == library.selectedID })?.folder ?? ""
                showMoveSheet = true
            } label: { Label("Move note", systemImage: "folder.badge.arrow.forward") }
            .disabled(library.selectedID == nil)
            Button {
                if let selectedID = library.selectedID {
                    appState.startNoteUpdate(noteID: selectedID)
                }
            } label: { Label("Update note from voice", systemImage: "wand.and.stars") }
            .disabled(library.selectedID == nil || appState.isRecording || appState.isTranscribing)
            Button {
                if let selectedID = library.selectedID {
                    appState.startNoteAppend(noteID: selectedID)
                }
            } label: { Label("Append voice to note", systemImage: "text.append") }
            .disabled(library.selectedID == nil || appState.isRecording || appState.isTranscribing)
            Button {
                selectedFolderForRename = selectedFolder
                renameFolderName = selectedFolder ?? ""
                showRenameSheet = true
            } label: { Label("Rename folder", systemImage: "folder.badge.gearshape") }
            .disabled(selectedFolder == nil)
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: { Label("Delete note", systemImage: "trash") }
            .disabled(library.selectedID == nil)
            Button { NotificationCenter.default.post(name: .showSettings, object: nil) } label: { Label("Settings", systemImage: "gear") }
        }
        .confirmationDialog(
            "Delete this note?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                library.deleteSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the Markdown file from your notes folder.")
        }
        .sheet(isPresented: $showMoveSheet) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Move note").font(.title2.weight(.semibold))
                Text("Enter a folder name. Use a slash for nested folders, or leave it empty for Inbox.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Folder, e.g. Projects/Ideas", text: $destinationFolder)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { showMoveSheet = false }
                    Button("Move") {
                        library.moveSelected(to: destinationFolder)
                        showMoveSheet = false
                    }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 420)
        }
        .sheet(isPresented: $showCreateFolderSheet) {
            VStack(alignment: .leading, spacing: 16) {
                Text("New folder").font(.title2.weight(.semibold))
                Text("Use a slash for nested folders, such as Projects/Ideas.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Folder name", text: $newFolderName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { showCreateFolderSheet = false }
                    Button("Create") {
                        library.createFolder(newFolderName)
                        showCreateFolderSheet = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 420)
        }
        .sheet(isPresented: $showRenameSheet) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Rename folder").font(.title2.weight(.semibold))
                Text("This renames the selected folder and keeps nested folders underneath it.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("New folder name", text: $renameFolderName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { showRenameSheet = false }
                    Button("Rename") {
                        if let folder = selectedFolderForRename ?? selectedFolder {
                            library.renameFolder(from: folder, to: renameFolderName)
                        }
                        selectedFolderForRename = nil
                        showRenameSheet = false
                    }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 420)
        }
        .frame(minWidth: 800, minHeight: 520)
    }
}

extension Notification.Name {
    static let showNotes = Notification.Name("showNotes")
}
