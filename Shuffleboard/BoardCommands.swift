import AppKit
import Combine
import SwiftUI

/// What the menu bar commands show and enable, worked out from `AppState` and the window in front. Kept apart from
/// them so the menu bar only rebuilds when one of these changes: rebuilt on every change to `AppState` (while
/// dragging cards, say), it made the window's toolbar flicker.
struct CommandAvailability: Equatable {
    struct BoardShortcut: Equatable {
        let id: Int
        let title: String
    }

    var isSignedIn = false
    /// A board is open and no card's sheet is in front of it.
    var boardIsOpen = false
    var boardHasLists = false
    var cardIsSelected = false
    var selectedCardIsDone = false
    var canMoveCard = false
    /// The selected card can be marked done, archived or deleted.
    var canChangeCard = false
    /// The server can't be reached, so nothing can be changed (#156).
    var isReadOnly = false
    var hasBoards = false
    /// The first nine active boards, for ⌘1 to ⌘9.
    var boardShortcuts: [BoardShortcut] = []

    @MainActor
    init(_ appState: AppState? = nil, window: BoardWindow? = nil) {
        guard let appState else { return }
        self.isSignedIn = appState.isLoggedIn && !appState.showingLogin
        if let window {
            self.boardIsOpen = isSignedIn && window.selectedBoard != nil && window.openedCard == nil
            self.boardHasLists = !window.stacks.isEmpty
            let selectedCard = boardIsOpen ? window.selectedCard : nil
            self.cardIsSelected = selectedCard != nil
            self.selectedCardIsDone = selectedCard?.isDone == true
            self.canMoveCard = boardIsOpen && window.canMoveSelectedCard
            self.canChangeCard = boardIsOpen && window.canChangeSelectedCard
        }
        self.isReadOnly = appState.isReadOnly
        self.hasBoards = !appState.boardsInSidebarOrder.isEmpty
        self.boardShortcuts = appState.activeBoards.prefix(9).map { BoardShortcut(id: $0.id, title: $0.title) }
    }
}

/// Publishes the `CommandAvailability` of `AppState` and the window in front, only when it changes, and says which
/// window the commands act on.
@MainActor
final class BoardCommandState: ObservableObject {
    @Published private(set) var availability = CommandAvailability()
    /// The window in front, which the commands act on (#160).
    private(set) weak var window: BoardWindow?
    private let appState: AppState
    private var subscription: AnyCancellable?

    init(appState: AppState) {
        self.appState = appState
        self.availability = CommandAvailability(appState)
        subscribe()
    }

    /// Points the commands at `window`, which has come to the front.
    func activate(_ window: BoardWindow) {
        guard window !== self.window else { return }
        self.window = window
        subscribe()
        update()
    }

    /// Follows changes to `AppState` and to the window in front.
    private func subscribe() {
        var changes = [appState.objectWillChange.eraseToAnyPublisher()]
        if let window {
            changes.append(window.objectWillChange.eraseToAnyPublisher())
        }
        // objectWillChange fires before the change, so look once it has been made.
        subscription = Publishers.MergeMany(changes)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.update()
                }
            }
    }

    private func update() {
        let availability = CommandAvailability(appState, window: window)
        if availability != self.availability {
            self.availability = availability
        }
    }
}

/// The menu bar commands for boards, lists and cards (#159). Each has a shortcut, so the common actions don't need
/// the mouse, and VoiceOver and Full Keyboard Access reach them through the menus. Card commands act on the selected
/// card, which the arrow keys move around the board.
struct BoardCommands: Commands {
    /// Not observed: the commands only change with `state`.
    let appState: AppState
    @ObservedObject var state: BoardCommandState

    /// The window in front, which the commands act on.
    private var window: BoardWindow? {
        state.window
    }

    private var isSignedIn: Bool {
        state.availability.isSignedIn
    }

    private var boardIsOpen: Bool {
        state.availability.boardIsOpen
    }

    private var cardIsSelected: Bool {
        state.availability.cardIsSelected
    }

    private var isReadOnly: Bool {
        state.availability.isReadOnly
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Card") {
                window?.startNewCard()
            }
            .keyboardShortcut("n")
            .disabled(!boardIsOpen || !state.availability.boardHasLists || isReadOnly)
            Button("New List\u{2026}") {
                window?.showingNewStack = true
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!boardIsOpen || isReadOnly)
            Button("New Board\u{2026}") {
                window?.showingNewBoard = true
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(!isSignedIn || isReadOnly)
            NewWindowButton(state: state)
            Divider()
            Button("Refresh") {
                Task { await appState.refresh() }
            }
            .keyboardShortcut("r")
            .disabled(!isSignedIn)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Filter Cards") {
                window?.filterFocusRequest += 1
            }
            .keyboardShortcut("f")
            .disabled(!boardIsOpen)
            Button("Search All Boards") {
                window?.cardSearchFocusRequest += 1
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(!isSignedIn)
        }
        CommandMenu("Card") {
            Button("Open Card") {
                window?.openSelectedCard()
            }
            .keyboardShortcut("o")
            .disabled(!cardIsSelected)
            Button(state.availability.selectedCardIsDone ? "Mark as Not Done" : "Mark as Done") {
                Task { await window?.toggleSelectedCardDone() }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!state.availability.canChangeCard)
            Button("Archive Card") {
                Task { await window?.archiveSelectedCard() }
            }
            .keyboardShortcut("a", modifiers: [.command, .control])
            .disabled(!state.availability.canChangeCard)
            Button("Delete Card\u{2026}") {
                deleteCardOrText()
            }
            .keyboardShortcut(.delete)
            .disabled(!state.availability.canChangeCard)
            Divider()
            moveButton("Move Up", .up, key: .upArrow)
            moveButton("Move Down", .down, key: .downArrow)
            moveButton("Move to Previous List", .left, key: .leftArrow)
            moveButton("Move to Next List", .right, key: .rightArrow)
        }
        CommandGroup(before: .sidebar) {
            Button("Previous Board") {
                window?.selectBoard(offset: -1)
            }
            .keyboardShortcut("[")
            .disabled(!isSignedIn || !state.availability.hasBoards)
            Button("Next Board") {
                window?.selectBoard(offset: 1)
            }
            .keyboardShortcut("]")
            .disabled(!isSignedIn || !state.availability.hasBoards)
            ForEach(Array(state.availability.boardShortcuts.enumerated()), id: \.element.id) { index, board in
                Button(board.title) {
                    window?.selectedBoardId = board.id
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                .disabled(!isSignedIn)
            }
            Divider()
        }
    }

    private func moveButton(_ title: String, _ direction: CardDirection, key: KeyEquivalent) -> some View {
        Button(title) {
            Task { await window?.moveSelectedCard(direction) }
        }
        .keyboardShortcut(key, modifiers: [.command, .option])
        .disabled(!state.availability.canMoveCard)
    }

    /// ⌘⌫ deletes the selected card, except while typing, where it keeps deleting to the start of the line.
    private func deleteCardOrText() {
        if NSApp.keyWindow?.firstResponder is NSText {
            NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
        } else {
            window?.requestDeletingSelectedCard()
        }
    }
}

/// File > New Window (#160): another window, on the board of the window in front. ⌘N is New Card, so it's ⌃⌘N.
private struct NewWindowButton: View {
    /// Not observed: only read when the button is clicked.
    let state: BoardCommandState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Window") {
            openWindow(value: BoardWindowValue(boardId: state.window?.selectedBoardId))
        }
        .keyboardShortcut("n", modifiers: [.command, .control])
    }
}
