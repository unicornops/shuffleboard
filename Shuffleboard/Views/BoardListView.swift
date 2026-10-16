import SwiftUI

struct BoardListView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var window: BoardWindow
    @Environment(\.openWindow) private var openWindow
    @State private var pendingBoardDelete: Int?
    @State private var editingBoard: Board?
    @State private var duplicatingBoard: Board?
    /// "Recently Deleted" starts collapsed.
    @State private var showingDeleted = false

    /// The search result the arrow keys highlight in the search field.
    @State private var highlightedResult: CardSearchResult.ID?

    private var isSearching: Bool {
        !window.cardSearchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        boardList
            .listStyle(.sidebar)
            .navigationTitle("Boards")
            .frame(minWidth: 200)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await appState.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh boards")
                    .accessibilityLabel("Refresh boards")
                    .disabled(appState.isLoading)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                CardSearchField(highlighted: $highlightedResult)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    Button {
                        window.showingNewBoard = true
                    } label: {
                        Label("New Board", systemImage: "plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .help("New board")
                    .accessibilityLabel("New board")
                    .disabled(appState.isReadOnly)
                }
                .background(.background)
            }
            .sheet(isPresented: $window.showingNewBoard) {
                BoardSheet {
                    window.showingNewBoard = false
                }
            }
            .sheet(item: $editingBoard) { board in
                BoardSheet(board: board) {
                    editingBoard = nil
                }
            }
            .sheet(item: $duplicatingBoard) { board in
                DuplicateBoardSheet(board: board) {
                    duplicatingBoard = nil
                }
            }
            .confirmationDialog("Delete board?", isPresented: Binding(
                get: { pendingBoardDelete != nil },
                set: {
                    if !$0 {
                        pendingBoardDelete = nil
                    }
                }
            )) {
                Button("Delete", role: .destructive) {
                    guard let boardId = pendingBoardDelete else { return }
                    pendingBoardDelete = nil
                    Task { await appState.deleteBoard(id: boardId) }
                }
                Button("Cancel", role: .cancel) {
                    pendingBoardDelete = nil
                }
            } message: {
                if let boardId = pendingBoardDelete,
                   let board = appState.boards.first(where: { $0.id == boardId }) {
                    Text(
                        DeleteConfirmation.message(
                            "\u{201c}\(board.title)\u{201d} and all its lists and cards",
                            restoreNote: DeleteConfirmation.boardRestoreNote
                        )
                    )
                }
            }
    }

    private var boardList: some View {
        List(selection: Binding(
            get: { window.selectedBoardId },
            set: { new in
                // A ⌘-click (or a click on nothing) can deselect the row; the window keeps its board.
                guard let bid = new, let board = appState.boards.first(where: { $0.id == bid }) else { return }
                window.selectBoard(board)
            }
        )) {
            if isSearching {
                CardSearchResults(highlighted: highlightedResult)
            } else {
                boards
            }
        }
    }

    @ViewBuilder
    private var boards: some View {
        Section("Boards") {
            if appState.isLoading && appState.boards.isEmpty {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if appState.activeBoards.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if let err = appState.errorMessage {
                        Text("Could not load boards")
                            .font(.subheadline.weight(.medium))
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    } else {
                        Text("No boards")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } else {
                ForEach(appState.activeBoards) { board in
                    Button {
                        open(board)
                    } label: {
                        BoardRowView(board: board)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("board: \(board.title)")
                    .tag(board.id)
                    .contextMenu {
                        Button("Open in New Window") {
                            openInNewWindow(board)
                        }
                        Divider()
                        Group {
                            boardActions(board)
                            Button("Archive") {
                                Task { await appState.archiveBoard(id: board.id) }
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                pendingBoardDelete = board.id
                            }
                        }
                        .disabled(appState.isReadOnly)
                    }
                }
            }
        }
        if !appState.archivedBoards.isEmpty {
            Section("Archived") {
                ForEach(appState.archivedBoards) { board in
                    Button {
                        open(board)
                    } label: {
                        BoardRowView(board: board)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("board: \(board.title)")
                    .tag(board.id)
                    .contextMenu {
                        Button("Open in New Window") {
                            openInNewWindow(board)
                        }
                        Divider()
                        Group {
                            boardActions(board)
                            Button("Unarchive") {
                                Task { await appState.unarchiveBoard(id: board.id) }
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                pendingBoardDelete = board.id
                            }
                        }
                        .disabled(appState.isReadOnly)
                    }
                }
            }
        }
        if !appState.deletedBoards.isEmpty {
            recentlyDeleted
        }
    }

    /// Opens `board` in this window, or in a new one with ⌘ held, as Safari opens links (#160).
    private func open(_ board: Board) {
        if NSEvent.modifierFlags.contains(.command) {
            openInNewWindow(board)
        } else {
            window.selectBoard(board)
        }
    }

    private func openInNewWindow(_ board: Board) {
        openWindow(value: BoardWindowValue(boardId: board.id))
    }

    /// "Edit Board…", for boards the signed-in user may manage, and "Duplicate…".
    @ViewBuilder
    private func boardActions(_ board: Board) -> some View {
        if board.canManage {
            Button("Edit Board\u{2026}") {
                editingBoard = board
            }
        }
        Button("Duplicate\u{2026}") {
            duplicatingBoard = board
        }
    }

    /// Deleted boards Deck can still restore, until the server clears deleted items. Not selectable: a deleted
    /// board's lists can't be opened.
    private var recentlyDeleted: some View {
        Section {
            if showingDeleted {
                ForEach(appState.deletedBoards) { board in
                    HStack {
                        BoardRowView(board: board)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if board.canManage, !appState.isReadOnly {
                            Button {
                                Task { await window.restoreBoard(id: board.id) }
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                            }
                            .buttonStyle(.borderless)
                            .help("Restore this board")
                            .accessibilityLabel("Restore \(board.title)")
                        }
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("deleted board: \(board.title)")
                    .contextMenu {
                        if board.canManage, !appState.isReadOnly {
                            Button("Restore") {
                                Task { await window.restoreBoard(id: board.id) }
                            }
                        }
                    }
                }
            }
        } header: {
            Button {
                showingDeleted.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text("Recently Deleted")
                    Image(systemName: showingDeleted ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
            }
            .buttonStyle(.plain)
            .help(showingDeleted ? "Hide recently deleted boards" : "Show recently deleted boards")
            .accessibilityLabel("Recently Deleted")
            .accessibilityValue(showingDeleted ? "Shown" : "Hidden")
        }
    }
}

private struct BoardRowView: View {
    let board: Board

    var body: some View {
        SwiftUI.Label {
            Text(board.title)
                .lineLimit(1)
        } icon: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(boardColor)
                .frame(width: 12, height: 12)
        }
    }

    private var boardColor: Color {
        guard let hex = board.color, !hex.isEmpty else { return .accentColor }
        return Color(hex: hex) ?? .accentColor
    }
}

#Preview {
    BoardListView()
        .previewEnvironment()
}
