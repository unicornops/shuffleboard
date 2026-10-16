import os
import SwiftUI
import UniformTypeIdentifiers

private struct DraggedStack {
    let id: Int
    let index: Int

    var providerString: String {
        "stack:\(id):\(index)"
    }

    static func fromProviderString(_ value: String) -> Self? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == "stack",
              let id = Int(parts[1]),
              let index = Int(parts[2]) else {
            return nil
        }
        return Self(id: id, index: index)
    }
}

struct BoardDetailView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var window: BoardWindow
    @State private var showingSharing = false
    @State private var showingEditBoard = false
    @State private var showingLabels = false
    @State private var stackDragInsertIndex: Int?
    /// The board has keyboard focus, so the arrow keys move the selected card.
    @FocusState private var isBoardFocused: Bool
    @FocusState private var isFilterFocused: Bool

    var body: some View {
        Group {
            if let board = window.selectedBoard {
                VStack(spacing: 0) {
                    boardHeader(board)
                    if window.cardFilter.isActive {
                        filterStatus
                    }
                    Divider()
                    scrollableStacks(board)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            } else {
                ContentUnavailableView(
                    "Select a Board",
                    systemImage: "rectangle.stack",
                    description: Text("Choose a board from the sidebar to get started.")
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let problem = appState.connectionProblem {
                OfflineBanner(problem: problem, dataDate: window.offlineDataDate) {
                    await appState.reconnect()
                }
            }
        }
        .navigationTitle(window.selectedBoard?.title ?? "Deck")
        .searchable(text: $window.cardFilter.text, placement: .toolbar, prompt: "Filter cards")
        .searchFocusedIfAvailable($isFilterFocused)
        .onChange(of: window.filterFocusRequest) {
            isFilterFocused = true
        }
        .sheet(isPresented: $showingSharing) {
            if let board = window.selectedBoard {
                BoardSharingSheet(boardId: board.id)
                    .environmentObject(appState)
                    .environmentObject(window)
            }
        }
        .sheet(isPresented: $showingEditBoard) {
            if let board = window.selectedBoard {
                BoardSheet(board: board) {
                    showingEditBoard = false
                }
                .environmentObject(appState)
                .environmentObject(window)
            }
        }
        .sheet(isPresented: $showingLabels) {
            if let board = window.selectedBoard {
                BoardLabelsSheet(boardId: board.id)
                    .environmentObject(appState)
                    .environmentObject(window)
            }
        }
        .sheet(isPresented: $window.showingArchivedCards) {
            if let board = window.selectedBoard {
                ArchivedCardsSheet(board: board)
                    .environmentObject(appState)
                    .environmentObject(window)
            }
        }
        .sheet(item: $window.openedCard) { card in
            if let board = window.selectedBoard {
                // Card actions reload the lists themselves; closing the sheet doesn't need to.
                CardDetailSheet(card: card, boardId: board.id, onDismiss: {
                    window.openedCard = nil
                })
                .environmentObject(appState)
                .environmentObject(window)
            }
        }
        .sheet(isPresented: $window.showingNewStack) {
            if let board = window.selectedBoard {
                NewStackSheet(boardId: board.id, onDismiss: {
                    window.showingNewStack = false
                })
                .environmentObject(appState)
                .environmentObject(window)
            }
        }
        .confirmationDialog("Delete card?", isPresented: Binding(
            get: { window.cardPendingDelete != nil },
            set: {
                if !$0 {
                    window.cardPendingDelete = nil
                }
            }
        )) {
            Button("Delete", role: .destructive) {
                Task { await window.deletePendingCard() }
            }
            Button("Cancel", role: .cancel) {
                window.cardPendingDelete = nil
            }
        } message: {
            if let card = window.cardPendingDelete {
                Text(DeleteConfirmation.message("\u{201c}\(card.title)\u{201d}"))
            }
        }
        // The single place lists are loaded on board selection; changing board cancels the previous load.
        .task(id: window.selectedBoardId) {
            // Labels and people differ per board, so a new board starts unfiltered.
            window.cardFilter = CardFilter()
            guard let bid = window.selectedBoardId else { return }
            await appState.loadStacks(boardId: bid)
        }
    }

    private func boardHeader(_ board: Board) -> some View {
        HStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(boardColor(board))
                .frame(width: 16, height: 16)
            Text(board.title)
                .font(.title2.weight(.semibold))
            if board.canManage, !appState.isReadOnly {
                Button {
                    showingEditBoard = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Rename this board or change its color")
                .accessibilityLabel("Edit board")
            }
            Spacer()
            // Left of the buttons, and always taking its space, so they don't shift when a refresh starts or ends.
            ProgressView()
                .controlSize(.small)
                .opacity(window.isLoadingStacks && !window.stacks.isEmpty ? 1 : 0)
                .help("Refreshing lists")
                .accessibilityHidden(!window.isLoadingStacks)
            filterMenu(board)
            Button {
                showingSharing = true
            } label: {
                Image(systemName: board.acl.isEmpty ? "person.crop.circle.badge.plus" : "person.2.fill")
            }
            .help(board.acl.isEmpty ? "Share this board" : "Shared with \(board.acl.count)")
            .accessibilityLabel("Sharing")
            .disabled(appState.isReadOnly)
            if board.canManage {
                Button {
                    showingLabels = true
                } label: {
                    Image(systemName: "tag")
                }
                .help("Edit this board's labels")
                .accessibilityLabel("Labels")
                .disabled(appState.isReadOnly)
            }
            Button {
                window.showingArchivedCards = true
            } label: {
                Image(systemName: "archivebox")
            }
            .help("Archived cards")
            .accessibilityLabel("Archived cards")
            .disabled(appState.isReadOnly)
            Button {
                Task { await appState.loadStacks(boardId: board.id) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh lists")
            .accessibilityLabel("Refresh lists")
            .disabled(window.isLoadingStacks)
            Button {
                window.showingNewStack = true
            } label: {
                SwiftUI.Label("Add list", systemImage: "plus.rectangle.on.rectangle")
            }
            .help("Add a new list to this board")
            .accessibilityLabel("Add list")
            .disabled(appState.isReadOnly)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Filter

    private func filterMenu(_ board: Board) -> some View {
        Menu {
            Picker("Due", selection: $window.cardFilter.due) {
                ForEach(CardFilter.Due.allCases) { due in
                    Text(due.title).tag(due)
                }
            }
            .pickerStyle(.inline)
            Toggle("Hide done cards", isOn: $window.cardFilter.hideDone)
            if !board.labels.isEmpty {
                Section("Labels") {
                    ForEach(board.labels) { label in
                        Toggle(label.title, isOn: membership(of: label.id, in: \.labelIds))
                    }
                }
            }
            if !board.assignableUsers.isEmpty {
                Section("Assigned to") {
                    ForEach(board.assignableUsers, id: \.uid) { user in
                        Toggle(user.displayName, isOn: membership(of: user.uid, in: \.assigneeIds))
                    }
                }
            }
            Divider()
            Button("Clear Filters") {
                window.cardFilter = CardFilter(text: window.cardFilter.text)
            }
        } label: {
            SwiftUI.Label(
                "Filter",
                systemImage: window.cardFilter.isActive
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .fixedSize()
        .help("Filter cards by label, person or due date")
    }

    /// A toggle binding for whether `value` is in one of the filter's sets.
    private func membership<Value: Hashable>(
        of value: Value,
        in keyPath: WritableKeyPath<CardFilter, Set<Value>>
    )
        -> Binding<Bool> {
        Binding(
            get: { window.cardFilter[keyPath: keyPath].contains(value) },
            set: { isOn in
                if isOn {
                    window.cardFilter[keyPath: keyPath].insert(value)
                } else {
                    window.cardFilter[keyPath: keyPath].remove(value)
                }
            }
        )
    }

    private var filterStatus: some View {
        let all = window.stacks.flatMap { $0.cards ?? [] }
        let shown = all.filter { window.cardFilter.matches($0) }.count
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(.tint)
            Text("Showing \(shown) of \(all.count) cards. Drag and drop is paused while filtering.")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Clear") {
                window.cardFilter = CardFilter()
            }
            .buttonStyle(.link)
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func boardColor(_ board: Board) -> Color {
        guard let hex = board.color, !hex.isEmpty else { return .accentColor }
        return Color(hex: hex) ?? .accentColor
    }

    private let stackDropTypes = [
        UTType.plainText.identifier,
        UTType.utf8PlainText.identifier,
        UTType.text.identifier,
    ]

    @ViewBuilder
    private func scrollableStacks(_ board: Board) -> some View {
        if window.isLoadingStacks && window.stacks.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(1.2)
                Text("Loading lists…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = window.stacksError, window.stacks.isEmpty {
            ContentUnavailableView {
                Label("Could not load lists", systemImage: "exclamationmark.triangle")
            } description: {
                Text(err)
            } actions: {
                Button("Try again") {
                    Task { await appState.loadStacks(boardId: board.id) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 0) {
                    stackInsertionGap(at: 0, boardId: board.id)
                    ForEach(Array(window.stacks.enumerated()), id: \.element.id) { index, stack in
                        StackColumnView(
                            board: board,
                            stack: stack,
                            onSelectCard: { card in
                                window.selectedCardId = card.id
                                window.openedCard = card
                            }
                        )
                        .environmentObject(appState)
                        .environmentObject(window)
                        .draggableList(DraggedStack(id: stack.id, index: index), enabled: !appState.isReadOnly) {
                            window.isDraggingStack = true
                        }
                        stackInsertionGap(at: index + 1, boardId: board.id)
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusable()
            .focused($isBoardFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return]) { press in
                handleKey(press.key)
            }
            .onChange(of: window.selectedCardId) { _, id in
                // A card selected from the menus or by creating it: the arrow keys carry on from there.
                if id != nil, window.openedCard == nil, window.newCardListId == nil {
                    isBoardFocused = true
                }
            }
            .onChange(of: window.openedCard?.id) { _, id in
                // Back from the card's sheet: carry on with the keyboard.
                if id == nil, window.selectedCardId != nil {
                    isBoardFocused = true
                }
            }
            .onDrop(of: stackDropTypes, isTargeted: nil) { _ in
                // Catch-all: reset stack-dragging state for drops that miss a gap
                dragLogger.notice("Drop outside the lists ignored")
                window.isDraggingStack = false
                return false
            }
        }
    }

    /// The gap before list `index`, where a dragged list can be dropped. It only reacts to a dragged list: a card
    /// dragged across it would otherwise widen it, pushing the next list away from the pointer so the card landed
    /// in the gap, which ignored it and left the card where it was.
    @ViewBuilder
    private func stackInsertionGap(at index: Int, boardId: Int) -> some View {
        let targeted = stackDragInsertIndex == index && window.isDraggingStack
        ZStack(alignment: .center) {
            Color.clear
                .frame(width: targeted ? 80 : 16)
            if targeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2, antialiased: true)
                    )
                    .frame(width: 72)
                    .transition(.opacity)
            }
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.15), value: targeted)
        .onDrop(
            of: stackDropTypes,
            isTargeted: Binding(
                get: { stackDragInsertIndex == index },
                set: { isTargeted in
                    if isTargeted, window.isDraggingStack {
                        stackDragInsertIndex = index
                    } else if stackDragInsertIndex == index {
                        stackDragInsertIndex = nil
                    }
                }
            ),
            perform: { providers in
                dragLogger.notice("Drop between lists at \(index), list drag: \(window.isDraggingStack)")
                guard window.isDraggingStack else { return false }
                return handleStackDrop(providers: providers, insertIndex: index, boardId: boardId)
            }
        )
    }

    /// The arrow keys move the selection between cards; Return opens the selected card.
    private func handleKey(_ key: KeyEquivalent) -> KeyPress.Result {
        let directions: [KeyEquivalent: CardDirection] = [
            .upArrow: .up, .downArrow: .down, .leftArrow: .left, .rightArrow: .right,
        ]
        if let direction = directions[key] {
            window.selectCard(direction)
            return .handled
        }
        guard key == .return, window.selectedCard != nil else { return .ignored }
        window.openSelectedCard()
        return .handled
    }

    private func handleStackDrop(providers: [NSItemProvider], insertIndex: Int, boardId: Int) -> Bool {
        providers.loadDroppedText { text in
            Task { @MainActor in
                window.isDraggingStack = false
                guard let draggedStack = DraggedStack.fromProviderString(text) else { return }
                await appState.reorderStacks(
                    boardId: boardId,
                    fromIndex: draggedStack.index,
                    toIndex: insertIndex
                )
            }
        }
    }
}

#Preview {
    BoardDetailView()
        .previewEnvironment()
}

private extension View {
    /// Lets the list be dragged to another position, unless `enabled` is false (while the server can't be reached).
    @ViewBuilder
    func draggableList(_ list: DraggedStack, enabled: Bool, onStart: @escaping () -> Void) -> some View {
        if enabled {
            onDrag {
                dragLogger.notice("List drag started: list \(list.id)")
                onStart()
                return NSItemProvider(object: NSString(string: list.providerString))
            }
        } else {
            self
        }
    }

    /// Lets ⌘F (Edit > Filter Cards) put the cursor in the filter field; macOS 14 has no way to.
    @ViewBuilder
    func searchFocusedIfAvailable(_ isFocused: FocusState<Bool>.Binding) -> some View {
        if #available(macOS 15.0, *) {
            searchFocused(isFocused)
        } else {
            self
        }
    }
}
