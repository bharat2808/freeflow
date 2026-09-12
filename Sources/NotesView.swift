import AppKit
import MarkdownUI
import SwiftUI
import UniformTypeIdentifiers

final class NotesLibrary: ObservableObject {
    @Published var notes: [MarkdownNote] = []
    @Published var selectedID: UUID?
    @Published var error: String?
    @Published private(set) var savedFolders: [String] = []
    private let store = MarkdownNoteStore.standard
    private let saveQueue = DispatchQueue(label: "freeflow.notes.save", qos: .utility)
    private var pendingSaveWorkItems: [UUID: DispatchWorkItem] = [:]
    private var editUndoBaselines: [UUID: MarkdownNote] = [:]
    private var undoStack: [UUID: [MarkdownNote]] = [:]

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

    @discardableResult
    func createEmpty() -> UUID? {
        let note = MarkdownNote(id: UUID(), markdown: "# Untitled note\n\n", modified: Date())
        do {
            try store.save(note)
            notes.insert(note, at: 0)
            selectedID = note.id
            error = nil
            return note.id
        } catch {
            self.error = "Could not create note: \(error.localizedDescription)"
            return nil
        }
    }

    func edit(id: UUID, markdown: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        if editUndoBaselines[id] == nil {
            editUndoBaselines[id] = notes[index]
        }
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
                    self.commitPendingEditHistory(for: id)
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
    func importAttachment(_ payload: NoteAttachmentPayload, for noteID: UUID) -> String? {
        guard let index = notes.firstIndex(where: { $0.id == noteID }) else { return nil }
        let note = notes[index]
        do {
            let path: String
            if let sourceURL = payload.sourceURL {
                path = try store.importAttachment(from: sourceURL, for: note)
            } else if let imageData = payload.imageData {
                path = try store.writeAttachment(imageData, fileName: payload.fileName, for: note)
            } else {
                return nil
            }
            return path
        } catch let attachmentError {
            self.error = "Could not add attachment: \(attachmentError.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func update(id: UUID, markdown: String) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return false }
        commitPendingEditHistory(for: id)
        undoStack[id, default: []].append(notes[index])
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

    var canUndoSelectedNote: Bool {
        guard let selectedID else { return false }
        return editUndoBaselines[selectedID] != nil || !(undoStack[selectedID]?.isEmpty ?? true)
    }

    @discardableResult
    func undoSelectedNote() -> Bool {
        guard let selectedID,
              let index = notes.firstIndex(where: { $0.id == selectedID }) else { return false }
        pendingSaveWorkItems[selectedID]?.cancel()
        pendingSaveWorkItems[selectedID] = nil
        commitPendingEditHistory(for: selectedID)
        guard let previous = undoStack[selectedID]?.popLast() else { return false }
        do {
            try store.save(previous)
            notes[index] = previous
            error = nil
            return true
        } catch let undoError {
            undoStack[selectedID, default: []].append(previous)
            error = "Could not undo note: \(undoError.localizedDescription)"
            return false
        }
    }

    private func commitPendingEditHistory(for id: UUID) {
        guard let baseline = editUndoBaselines.removeValue(forKey: id),
              let current = notes.first(where: { $0.id == id }),
              baseline != current else { return }
        undoStack[id, default: []].append(baseline)
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
        let note = notes[index]
        do {
            // Flush a debounced editor save before changing the note's path.
            // Otherwise the delayed write can recreate the old file after the
            // move has completed.
            try flushPendingSave(for: note)
            notes[index] = try store.move(note, toFolder: folder)
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
            let affectedNotes = notes.filter {
                $0.folder == oldValue || $0.folder.hasPrefix(oldValue + "/")
            }
            // Folder moves are path changes too. Persist the latest editor
            // contents before the atomic directory rename.
            for note in affectedNotes {
                try flushPendingSave(for: note)
            }
            try store.renameFolder(from: oldValue, to: newValue)
            reload()
            selectedID = affectedNotes.first?.id
        } catch {
            self.error = "Could not rename folder: \(error.localizedDescription)"
            reload()
        }
    }

    func deleteFolder(_ folder: String) {
        let value = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let affectedNotes = notes.filter {
            $0.folder == value || $0.folder.hasPrefix(value + "/")
        }
        do {
            for note in affectedNotes {
                try flushPendingSave(for: note)
            }
            for note in affectedNotes {
                guard let index = notes.firstIndex(where: { $0.id == note.id }) else { continue }
                notes[index] = try store.move(note, toFolder: "")
            }
            try store.deleteFolder(value)
            notes.sort { $0.modified > $1.modified }
            savedFolders = store.loadFolders()
            if let selectedID, affectedNotes.contains(where: { $0.id == selectedID }) {
                self.selectedID = selectedID
            }
            error = nil
        } catch {
            self.error = "Could not delete folder: \(error.localizedDescription)"
            reload()
        }
    }

    private func flushPendingSave(for note: MarkdownNote) throws {
        pendingSaveWorkItems[note.id]?.cancel()
        pendingSaveWorkItems[note.id] = nil
        try saveQueue.sync {
            try store.save(note)
        }
    }

    func revealFiles() { NSWorkspace.shared.open(store.directory) }
}

private struct NotesHeaderIconControl: View {
    let systemName: String
    var tint: Color?
    var iconFrameSize: CGFloat = 20
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: iconFrameSize, weight: .semibold))
            .foregroundStyle(
                isEnabled
                    ? (tint ?? Color(nsColor: .labelColor))
                    : Color(nsColor: .disabledControlTextColor)
            )
            .frame(width: 40, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .underPageBackgroundColor).opacity(0.7))
                    .opacity(isEnabled ? 0 : 1)
            )
    }
}

struct NotesView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var library: NotesLibrary
    @ObservedObject var searchState: NotesSearchState
    @State private var preview = false
    @State private var editorSelection = NSRange(location: 0, length: 0)
    @State private var showMoveSheet = false
    @State private var destinationFolder = ""
    @State private var showCreateFolderSheet = false
    @State private var newFolderName = ""
    @State private var showRenameSheet = false
    @State private var renameFolderName = ""
    @State private var selectedFolderForRename: String?
    @State private var showDeleteConfirmation = false
    @State private var showDeleteFolderConfirmation = false
    @State private var selectedFolderForDelete: String?
    @State private var expandedFolders: Set<String> = []
    @State private var collapsedFolders: Set<String> = []
    @State private var showTextPresetPopover = false
    @State private var isPresetProcessing = false
    @State private var presetError: String?
    @State private var textPresetPreview: TextPresetPreview?
    @State private var customTextPrompt = ""

    private struct TextPresetPreview {
        let noteID: UUID
        let originalText: String
        let replacementText: String
        let title: String
    }

    init(library: NotesLibrary, searchState: NotesSearchState) {
        self.library = library
        self.searchState = searchState
    }

    private var selectedNoteFolder: String? {
        guard let selectedID = library.selectedID else { return nil }
        let folder = library.notes.first(where: { $0.id == selectedID })?.folder ?? ""
        return folder.isEmpty ? nil : folder
    }

    private var sidebarFolders: [String] {
        [""] + library.folders.filter { !$0.isEmpty }
    }

    private var search: String { searchState.text }

    private func notes(in folder: String) -> [MarkdownNote] {
        library.notes
            .filter { note in
                note.folder == folder
                    && (search.isEmpty || note.markdown.localizedCaseInsensitiveContains(search))
            }
            .sorted { $0.modified > $1.modified }
    }

    private func dateGroups(for notes: [MarkdownNote]) -> [(String, [MarkdownNote])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: notes) { note in
            calendar.startOfDay(for: note.modified)
        }
        return grouped.keys.sorted(by: >).map { date in
            let title: String
            if calendar.isDateInToday(date) {
                title = "Today"
            } else if calendar.isDateInYesterday(date) {
                title = "Yesterday"
            } else {
                title = date.formatted(date: .abbreviated, time: .omitted)
            }
            return (title, grouped[date, default: []].sorted { $0.modified > $1.modified })
        }
    }

    private func moveDroppedNote(from providers: [NSItemProvider], to folder: String) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let value = object as? NSString,
                  let noteID = UUID(uuidString: value as String) else { return }
            DispatchQueue.main.async {
                library.selectedID = noteID
                library.moveSelected(to: folder)
            }
        }
        return true
    }

    private var liveTranscript: String {
        let live = appState.liveNoteTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty { return live }
        return appState.lastRawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func selectedText(in note: MarkdownNote) -> String? {
        let source = note.markdown as NSString
        let range = selectedRange(in: note)
        guard range.length > 0 else { return nil }
        return source.substring(with: range)
    }

    private func selectedRange(in note: MarkdownNote) -> NSRange {
        let length = (note.markdown as NSString).length
        guard editorSelection.length > 0 else {
            return NSRange(location: 0, length: length)
        }
        let location = min(max(editorSelection.location, 0), length)
        let selectionLength = min(max(editorSelection.length, 0), length - location)
        return NSRange(location: location, length: selectionLength)
    }

    private func runTextPreset(_ preset: TextActionPreset, for note: MarkdownNote) {
        guard !isPresetProcessing else { return }
        guard let selectedText = selectedText(in: note) else {
            presetError = "The note is empty. Add some text before choosing a preset."
            return
        }
        editorSelection = selectedRange(in: note)
        presetError = nil
        isPresetProcessing = true
        Task {
            do {
                let replacement = try await appState.processTextPreset(preset, text: selectedText)
                await MainActor.run {
                    textPresetPreview = TextPresetPreview(
                        noteID: note.id,
                        originalText: selectedText,
                        replacementText: replacement,
                        title: preset.title
                    )
                    isPresetProcessing = false
                    showTextPresetPopover = false
                }
            } catch {
                await MainActor.run {
                    presetError = error.localizedDescription
                    isPresetProcessing = false
                }
            }
        }
    }

    private func runCustomTextPrompt() {
        guard !isPresetProcessing else { return }
        guard let note = library.notes.first(where: { $0.id == library.selectedID }),
              let selectedText = selectedText(in: note) else {
            presetError = "The note is empty. Add some text before describing a change."
            return
        }
        editorSelection = selectedRange(in: note)
        let prompt = customTextPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            presetError = "Describe the change you want first."
            return
        }
        presetError = nil
        isPresetProcessing = true
        Task {
            do {
                let replacement = try await appState.processTextInstruction(prompt, text: selectedText)
                await MainActor.run {
                    textPresetPreview = TextPresetPreview(
                        noteID: note.id,
                        originalText: selectedText,
                        replacementText: replacement,
                        title: "Custom change"
                    )
                    isPresetProcessing = false
                    showTextPresetPopover = false
                }
            } catch {
                await MainActor.run {
                    presetError = error.localizedDescription
                    isPresetProcessing = false
                }
            }
        }
    }

    private func applyTextPresetPreview(_ preview: TextPresetPreview) {
        guard let note = library.notes.first(where: { $0.id == preview.noteID }) else {
            presetError = "The note is no longer available."
            return
        }
        let source = note.markdown as NSString
        let location = min(max(editorSelection.location, 0), source.length)
        let length = min(max(editorSelection.length, 0), source.length - location)
        guard source.substring(with: NSRange(location: location, length: length)) == preview.originalText else {
            presetError = "The note changed while the preset was running. Please select the text again."
            return
        }
        let updated = source.replacingCharacters(
            in: NSRange(location: location, length: length),
            with: preview.replacementText
        )
        library.edit(id: preview.noteID, markdown: updated)
        editorSelection = NSRange(
            location: location,
            length: (preview.replacementText as NSString).length
        )
        textPresetPreview = nil
        presetError = nil
    }

    private var textPresetPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "atom")
                    .foregroundStyle(.purple)
                TextField("Describe your change", text: $customTextPrompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .onSubmit { runCustomTextPrompt() }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
            Button("Apply custom change") { runCustomTextPrompt() }
                .buttonStyle(.borderedProminent)
                .disabled(isPresetProcessing || customTextPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            HStack(spacing: 10) {
                presetButton(.proofread)
                presetButton(.rewrite)
            }
            Divider()
            presetRow(.friendly)
            presetRow(.professional)
            presetRow(.concise)
            if isPresetProcessing {
                ProgressView("Processing…")
                    .controlSize(.small)
            }
            if let presetError {
                Text(presetError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Divider()
            Text("Voice actions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Button {
                showTextPresetPopover = false
                if let noteID = library.selectedID { appState.startNoteUpdate(noteID: noteID) }
            } label: {
                Label("Update by voice", systemImage: "mic")
            }
            .disabled(library.selectedID == nil)
            Button {
                showTextPresetPopover = false
                if let noteID = library.selectedID { appState.startNoteAppend(noteID: noteID) }
            } label: {
                Label("Append by voice", systemImage: "mic")
            }
            .disabled(library.selectedID == nil)
        }
        .padding(18)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func presetButton(_ preset: TextActionPreset) -> some View {
        Button {
            if let note = library.notes.first(where: { $0.id == library.selectedID }) {
                runTextPreset(preset, for: note)
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: preset.icon).font(.title2)
                Text(preset.title).font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 66)
        }
        .buttonStyle(.bordered)
        .disabled(isPresetProcessing)
    }

    private func presetRow(_ preset: TextActionPreset) -> some View {
        Button {
            if let note = library.notes.first(where: { $0.id == library.selectedID }) {
                runTextPreset(preset, for: note)
            }
        } label: {
            Label(preset.title, systemImage: preset.icon)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(isPresetProcessing)
    }

    @ViewBuilder
    private var noteRecordingStatus: some View {
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
    }

    private var notesSidebar: some View {
        List(selection: $library.selectedID) {
            Section {
                ForEach(sidebarFolders, id: \.self) { folder in
                    folderRows(folder)
                }
            } header: {
                HStack {
                    Text("Notes")
                    Spacer()
                    Button { library.createEmpty() } label: {
                        Image(systemName: "note.text.badge.plus")
                            .font(.title3)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.borderless)
                    .help("New note")
                    Button {
                        newFolderName = ""
                        showCreateFolderSheet = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.title3)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.borderless)
                    .help("New folder")
                }
            }
        }
        .contextMenu {
            Button {
                library.create("# Untitled note\n\n")
            } label: {
                Label("New note", systemImage: "square.and.pencil")
            }
            Button {
                newFolderName = ""
                showCreateFolderSheet = true
            } label: {
                Label("New folder", systemImage: "folder.badge.plus")
            }
            Divider()
            Button {
                library.reload()
            } label: {
                Label("Refresh notes", systemImage: "arrow.clockwise")
            }
        }
        .navigationTitle("Notes")
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
    }

    private var notesDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = library.error ?? appState.errorMessage {
                Text(error).foregroundStyle(.red).padding()
            }
            noteRecordingStatus
            if let note = library.notes.first(where: { $0.id == library.selectedID }) {
                if let presetPreview = textPresetPreview, presetPreview.noteID == note.id {
                    textPresetPreviewView(presetPreview, note: note)
                } else if let proposal = appState.pendingNoteUpdate, proposal.noteID == note.id {
                    noteUpdatePreview(proposal, note: note)
                } else {
                    noteHeader(note)
                    if preview {
                        ScrollView {
                            NoteMarkdownPreview(markdown: note.markdown, note: note)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(28)
                        }
                    } else {
                        noteEditor(for: note)
                    }
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
            noteStatusFooter
        }
    }

    var body: some View {
        NavigationSplitView {
            notesSidebar
        } detail: {
            notesDetail
        }
        .onChange(of: library.selectedID) { _ in
            editorSelection = NSRange(location: 0, length: 0)
        }
        .toolbar {
            ToolbarItem {
                Button { appState.toggleNoteRecording() } label: {
                    Label(
                        appState.isRecording ? "Stop & save" : "New note",
                        systemImage: appState.isRecording ? "stop.circle.fill" : "waveform.badge.plus"
                    )
                    .labelStyle(.titleAndIcon)
                }
                .help(appState.isRecording ? "Stop and save note" : "Start a new voice note")
                .disabled(appState.isTranscribing)
            }
        }
        .sheet(isPresented: $showCreateFolderSheet) {
            folderNameSheet(
                title: "New Folder",
                prompt: "Folder name",
                value: $newFolderName,
                confirmTitle: "Create"
            ) {
                library.createFolder(newFolderName)
                showCreateFolderSheet = false
            }
        }
        .sheet(isPresented: $showRenameSheet) {
            folderNameSheet(
                title: "Rename Folder",
                prompt: "Folder name",
                value: $renameFolderName,
                confirmTitle: "Rename"
            ) {
                if let selectedFolderForRename {
                    library.renameFolder(from: selectedFolderForRename, to: renameFolderName)
                }
                selectedFolderForRename = nil
                showRenameSheet = false
            }
        }
        .sheet(isPresented: $showMoveSheet) {
            moveNoteSheet
        }
        .alert("Delete Note?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                library.deleteSelected()
            }
        } message: {
            Text("This note and its attachments will be permanently deleted.")
        }
        .alert("Delete Folder?", isPresented: $showDeleteFolderConfirmation) {
            Button("Cancel", role: .cancel) {
                selectedFolderForDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let selectedFolderForDelete {
                    library.deleteFolder(selectedFolderForDelete)
                }
                self.selectedFolderForDelete = nil
            }
        } message: {
            Text("Notes in this folder will be moved to Inbox, then the folder will be deleted.")
        }
    }

    private func folderNameSheet(
        title: String,
        prompt: String,
        value: Binding<String>,
        confirmTitle: String,
        onConfirm: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
            TextField(prompt, text: value)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onConfirm)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    if title == "New Folder" {
                        showCreateFolderSheet = false
                    } else {
                        showRenameSheet = false
                        selectedFolderForRename = nil
                    }
                }
                Button(confirmTitle, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(value.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private var moveNoteSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Move Note")
                .font(.headline)
            Picker("Folder", selection: $destinationFolder) {
                ForEach(sidebarFolders, id: \.self) { folder in
                    Text(folder.isEmpty ? "Inbox" : folder).tag(folder)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { showMoveSheet = false }
                Button("Move") {
                    library.moveSelected(to: destinationFolder)
                    showMoveSheet = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func textPresetPreviewView(_ preview: TextPresetPreview, note: MarkdownNote) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Preview (preview.title.lowercased())")
                        .font(.title2.weight(.semibold))
                    Text("Review the selected-text replacement before applying it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revert") { textPresetPreview = nil }
                Button("Apply") { applyTextPresetPreview(preview) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.quaternary.opacity(0.35))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Original")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(preview.originalText)
                        .textSelection(.enabled)
                    Divider()
                    Text("\(preview.title) result")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Markdown(preview.replacementText, baseURL: MarkdownNoteStore.standard.noteFolderURL(for: note))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }
        }
    }

    private func chooseAttachment(for note: MarkdownNote) {
        let panel = NSOpenPanel()
        panel.title = "Choose an attachment"
        panel.prompt = "Insert"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            insertAttachment(Self.attachmentPayload(for: url), for: note)
        }
    }

    private func noteEditor(for note: MarkdownNote) -> some View {
        MarkdownNoteEditor(
            text: Binding(
                get: { library.notes.first(where: { $0.id == note.id })?.markdown ?? "" },
                set: { library.edit(id: note.id, markdown: $0) }
            ),
            selectedRange: $editorSelection,
            importAttachment: { payload in importAttachment(payload, for: note) }
        )
        .padding(18)
        .id(note.id)
    }

    private var noteStatusFooter: some View {
        HStack {
            Circle()
                .fill(appState.isRecording ? Color.red : Color.secondary)
                .frame(width: 7, height: 7)
            Text(appState.statusText)
            Spacer()
            Text("Markdown · saved locally")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(12)
    }

    private func insertAttachment(_ payload: NoteAttachmentPayload, for note: MarkdownNote) {
        guard let path = library.importAttachment(payload, for: note.id),
              let currentMarkdown = library.notes.first(where: { $0.id == note.id })?.markdown else { return }

        let markdown = attachmentMarkdown(for: payload, path: path)
        let currentNSString = currentMarkdown as NSString
        let location = min(max(editorSelection.location, 0), currentNSString.length)
        let length = min(max(editorSelection.length, 0), currentNSString.length - location)
        let replacementRange = NSRange(location: location, length: length)
        let updatedMarkdown = currentNSString.replacingCharacters(in: replacementRange, with: markdown)
        library.edit(id: note.id, markdown: updatedMarkdown)
        editorSelection = NSRange(location: location + (markdown as NSString).length, length: 0)
    }

    private func importAttachment(_ payload: NoteAttachmentPayload, for note: MarkdownNote) -> String? {
        library.importAttachment(payload, for: note.id).map { path in
            attachmentMarkdown(for: payload, path: path)
        }
    }

    private func attachmentMarkdown(for payload: NoteAttachmentPayload, path: String) -> String {
        switch payload.kind {
        case .image:
            return "\n\n![\(payload.fileName)](\(path))\n\n"
        case .video, .audio, .text, .pdf, .file:
            return "\n\n[\(payload.fileName)](\(path))\n\n"
        }
    }

    private static func attachmentPayload(for url: URL) -> NoteAttachmentPayload {
        let type = UTType(filenameExtension: url.pathExtension)
        let kind: NoteAttachmentKind
        if type?.conforms(to: .image) == true { kind = .image }
        else if type?.conforms(to: .movie) == true { kind = .video }
        else if type?.conforms(to: .audio) == true { kind = .audio }
        else if type?.conforms(to: .pdf) == true { kind = .pdf }
        else if type?.conforms(to: .text) == true { kind = .text }
        else { kind = .file }
        return NoteAttachmentPayload(sourceURL: url, imageData: nil, fileName: url.lastPathComponent, kind: kind)
    }

    private func noteUpdatePreview(_ proposal: PendingNoteUpdate, note: MarkdownNote) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(proposal.action == .append ? "Preview appended note" : "Preview updated note")
                        .font(.title2.weight(.semibold))
                    Text("Review the complete Markdown result before applying it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revert") { appState.cancelPendingNoteUpdate() }
                Button("Apply update") { appState.confirmPendingNoteUpdate() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.quaternary.opacity(0.35))
            ScrollView {
                Markdown(proposal.markdown, baseURL: MarkdownNoteStore.standard.noteFolderURL(for: note))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
            }
        }
    }

    private func folderHeader(_ folder: String) -> some View {
        let isCollapsed = collapsedFolders.contains(folder)
        return HStack(spacing: 8) {
            Button {
                if isCollapsed {
                    collapsedFolders.remove(folder)
                } else {
                    collapsedFolders.insert(folder)
                }
            } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.bold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .help(isCollapsed ? "Expand folder" : "Collapse folder")
            Label(folder.isEmpty ? "Inbox" : folder, systemImage: folder.isEmpty ? "tray" : "folder")
                .font(.headline)
            Spacer(minLength: 4)
            Text(String(notes(in: folder).count))
                .font(.callout)
                .foregroundStyle(.secondary)
            if !folder.isEmpty {
                Menu {
                    Button {
                        selectedFolderForRename = folder
                        renameFolderName = folder
                        showRenameSheet = true
                    } label: {
                        Label("Rename folder", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        selectedFolderForDelete = folder
                        showDeleteFolderConfirmation = true
                    } label: {
                        Label("Delete folder", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Color(nsColor: .labelColor))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(Color(nsColor: .labelColor))
                .foregroundStyle(Color(nsColor: .labelColor))
                .help("Folder actions")
            }
        }
        .contentShape(Rectangle())
    }

    private func noteHeader(_ note: MarkdownNote) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(note.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text(note.modified, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button {
                library.undoSelectedNote()
            } label: {
                NotesHeaderIconControl(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .disabled(!library.canUndoSelectedNote)
            .accessibilityLabel("Undo")
            .help("Undo the last note edit")
            Button {
                presetError = nil
                showTextPresetPopover.toggle()
            } label: {
                NotesHeaderIconControl(systemName: "sparkles")
            }
            .buttonStyle(.plain)
            .disabled(appState.isRecording || appState.isTranscribing)
            .accessibilityLabel("Note actions")
            .help("Transform selected text or update this note by voice")
            .popover(isPresented: $showTextPresetPopover, arrowEdge: .top) {
                textPresetPopover
            }
            Button {
                chooseAttachment(for: note)
            } label: {
                NotesHeaderIconControl(systemName: "paperclip")
            }
            .buttonStyle(.plain)
            .disabled(preview || appState.isRecording || appState.isTranscribing)
            .accessibilityLabel("Insert attachment")
            .help("Insert an attachment at the cursor")
            Button {
                preview.toggle()
            } label: {
                NotesHeaderIconControl(systemName: "eye", tint: preview ? .accentColor : nil)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview")
            .help("Toggle Markdown preview")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.35))
    }

    private func noteRow(_ note: MarkdownNote) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text(note.title).font(.headline).lineLimit(2)
                Text(note.modified, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .tag(note.id)
        .draggable(note.id.uuidString) {
            Label(note.title, systemImage: "note.text")
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
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

    @ViewBuilder
    private func folderRows(_ folder: String) -> some View {
        let folderNotes = notes(in: folder)
        let isExpanded = expandedFolders.contains(folder)
        let displayedFolderNotes = isExpanded ? folderNotes : Array(folderNotes.prefix(5))
        Group {
            folderHeader(folder)
            if !collapsedFolders.contains(folder) {
                dateGroupRows(folder: folder, folderNotes: displayedFolderNotes)
                if folderNotes.count > 5 {
                    Button(isExpanded ? "Show less" : "Show more") {
                        if isExpanded {
                            expandedFolders.remove(folder)
                        } else {
                            expandedFolders.insert(folder)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
                    .padding(.vertical, 4)
                }
            }
        }
        .onDrop(of: [UTType.text.identifier], isTargeted: nil) { providers in
            moveDroppedNote(from: providers, to: folder)
        }
    }

    @ViewBuilder
    private func dateGroupRows(folder: String, folderNotes: [MarkdownNote]) -> some View {
        ForEach(dateGroups(for: folderNotes), id: \.0) { dateTitle, dateNotes in
            Text(dateTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
                .padding(.top, 8)
            ForEach(dateNotes) { note in
                noteRow(note)
                    .padding(.leading, 22)
            }
        }
    }
}

extension Notification.Name {
    static let showNotes = Notification.Name("showNotes")
}
