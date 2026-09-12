import AppKit
import Combine

final class NotesSearchState: ObservableObject {
    @Published var text = ""
}

final class NotesTitlebarAccessoryViewController: NSTitlebarAccessoryViewController {
    static let accessorySize = NSSize(width: 360, height: 32)

    private let searchState: NotesSearchState
    private let library: NotesLibrary
    private let searchField = NSSearchField()

    init(library: NotesLibrary, searchState: NotesSearchState) {
        self.library = library
        self.searchState = searchState
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        searchField.placeholderString = "Search notes"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.stringValue = searchState.text
        searchField.controlSize = .large
        searchField.font = .systemFont(ofSize: 14)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let moreButton = NSButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")!,
                                  target: self, action: #selector(showMore(_:)))
        moreButton.bezelStyle = .texturedRounded
        moreButton.isBordered = false
        moreButton.controlSize = .large
        moreButton.image = moreButton.image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        )
        moreButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [searchField, moreButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 320),
            moreButton.widthAnchor.constraint(equalToConstant: 32)
        ])
        view = container
        preferredContentSize = Self.accessorySize
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        searchState.text = sender.stringValue
    }

    @objc private func showMore(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show files", action: #selector(revealFiles), keyEquivalent: "")
        menu.addItem(withTitle: "Refresh notes", action: #selector(reloadNotes), keyEquivalent: "")
        menu.addItem(withTitle: "Settings", action: #selector(showSettings), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func revealFiles() { library.revealFiles() }
    @objc private func reloadNotes() { library.reload() }
    @objc private func showSettings() {
        NotificationCenter.default.post(name: .showSettings, object: nil)
    }
}
