import AppKit
import Combine
import SwiftUI

/// What the menu bar commands show and enable, worked out from `AppState`. Kept apart from it so the menu bar only
/// rebuilds when one of these changes: rebuilt on every change to `AppState` (while dragging cards, say), it made
/// the window's toolbar flicker.
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
    var hasBoards = false
    /// The first nine active boards, for ⌘1 to ⌘9.
    var boardShortcuts: [BoardShortcut] = []

    @MainActor
    init(_ appState: AppState? = nil) {
        guard let appState else { return }
        self.isSignedIn = appState.isLoggedIn && !appState.showingLogin
        self.boardIsOpen = isSignedIn && appState.selectedBoard != nil && appState.openedCard == nil
        self.boardHasLists = !appState.stacks.isEmpty
        let selectedCard = boardIsOpen ? appState.selectedCard : nil
        self.cardIsSelected = selectedCard != nil
        self.selectedCardIsDone = selectedCard?.isDone == true
        self.canMoveCard = boardIsOpen && appState.canMoveSelectedCard
        self.hasBoards = !appState.boardsInSidebarOrder.isEmpty
        self.boardShortcuts = appState.activeBoards.prefix(9).map { BoardShortcut(id: $0.id, title: $0.title) }
    }
}

/// Publishes `AppState`'s `CommandAvailability`, only when it changes.
@MainActor
final class BoardCommandState: ObservableObject {
    @Published private(set) var availability = CommandAvailability()
    private var subscription: AnyCancellable?

    init(appState: AppState) {
        self.availability = CommandAvailability(appState)
        // objectWillChange fires before the change, so look once it has been made.
        self.subscription = appState.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak appState] _ in
                MainActor.assumeIsolated {
                    guard let self, let appState else { return }
                    let availability = CommandAvailability(appState)
                    if availability != self.availability {
                        self.availability = availability
                    }
                }
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

    private var isSignedIn: Bool {
        state.availability.isSignedIn
    }

    private var boardIsOpen: Bool {
        state.availability.boardIsOpen
    }

    private var cardIsSelected: Bool {
        state.availability.cardIsSelected
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Card") {
                appState.startNewCard()
            }
            .keyboardShortcut("n")
            .disabled(!boardIsOpen || !state.availability.boardHasLists)
            Button("New List\u{2026}") {
                appState.showingNewStack = true
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!boardIsOpen)
            Button("New Board\u{2026}") {
                appState.showingNewBoard = true
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(!isSignedIn)
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
                appState.filterFocusRequest += 1
            }
            .keyboardShortcut("f")
            .disabled(!boardIsOpen)
            Button("Search All Boards") {
                appState.cardSearchFocusRequest += 1
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(!isSignedIn)
        }
        CommandMenu("Card") {
            Button("Open Card") {
                appState.openSelectedCard()
            }
            .keyboardShortcut("o")
            .disabled(!cardIsSelected)
            Button(state.availability.selectedCardIsDone ? "Mark as Not Done" : "Mark as Done") {
                Task { await appState.toggleSelectedCardDone() }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!cardIsSelected)
            Button("Archive Card") {
                Task { await appState.archiveSelectedCard() }
            }
            .keyboardShortcut("a", modifiers: [.command, .control])
            .disabled(!cardIsSelected)
            Button("Delete Card\u{2026}") {
                deleteCardOrText()
            }
            .keyboardShortcut(.delete)
            .disabled(!cardIsSelected)
            Divider()
            moveButton("Move Up", .up, key: .upArrow)
            moveButton("Move Down", .down, key: .downArrow)
            moveButton("Move to Previous List", .left, key: .leftArrow)
            moveButton("Move to Next List", .right, key: .rightArrow)
        }
        CommandGroup(before: .sidebar) {
            Button("Previous Board") {
                appState.selectBoard(offset: -1)
            }
            .keyboardShortcut("[")
            .disabled(!isSignedIn || !state.availability.hasBoards)
            Button("Next Board") {
                appState.selectBoard(offset: 1)
            }
            .keyboardShortcut("]")
            .disabled(!isSignedIn || !state.availability.hasBoards)
            ForEach(Array(state.availability.boardShortcuts.enumerated()), id: \.element.id) { index, board in
                Button(board.title) {
                    appState.selectedBoardId = board.id
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                .disabled(!isSignedIn)
            }
            Divider()
        }
    }

    private func moveButton(_ title: String, _ direction: CardDirection, key: KeyEquivalent) -> some View {
        Button(title) {
            Task { await appState.moveSelectedCard(direction) }
        }
        .keyboardShortcut(key, modifiers: [.command, .option])
        .disabled(!state.availability.canMoveCard)
    }

    /// ⌘⌫ deletes the selected card, except while typing, where it keeps deleting to the start of the line.
    private func deleteCardOrText() {
        if NSApp.keyWindow?.firstResponder is NSText {
            NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
        } else {
            appState.requestDeletingSelectedCard()
        }
    }
}
