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
    @State private var showingSharing = false
    @State private var showingEditBoard = false
    @State private var showingLabels = false
    @State private var stackDragInsertIndex: Int?
    /// The board has keyboard focus, so the arrow keys move the selected card.
    @FocusState private var isBoardFocused: Bool
    @FocusState private var isFilterFocused: Bool

    var body: some View {
        Group {
            if let board = appState.selectedBoard {
                VStack(spacing: 0) {
                    boardHeader(board)
                    if appState.cardFilter.isActive {
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
                OfflineBanner(problem: problem, dataDate: appState.offlineDataDate) {
                    await appState.reconnect()
                }
            }
        }
        .navigationTitle(appState.selectedBoard?.title ?? "Deck")
        .searchable(text: $appState.cardFilter.text, placement: .toolbar, prompt: "Filter cards")
        .searchFocusedIfAvailable($isFilterFocused)
        .onChange(of: appState.filterFocusRequest) {
            isFilterFocused = true
        }
        .sheet(isPresented: $showingSharing) {
            if let board = appState.selectedBoard {
                BoardSharingSheet(boardId: board.id)
                    .environmentObject(appState)
            }
        }
        .sheet(isPresented: $showingEditBoard) {
            if let board = appState.selectedBoard {
                BoardSheet(board: board) {
                    showingEditBoard = false
                }
                .environmentObject(appState)
            }
        }
        .sheet(isPresented: $showingLabels) {
            if let board = appState.selectedBoard {
                BoardLabelsSheet(boardId: board.id)
                    .environmentObject(appState)
            }
        }
        .sheet(isPresented: $appState.showingArchivedCards) {
            if let board = appState.selectedBoard {
                ArchivedCardsSheet(board: board)
                    .environmentObject(appState)
            }
        }
        .sheet(item: $appState.openedCard) { card in
            if let board = appState.selectedBoard {
                // Card actions reload the lists themselves; closing the sheet doesn't need to.
                CardDetailSheet(card: card, boardId: board.id, onDismiss: {
                    appState.openedCard = nil
                })
                .environmentObject(appState)
            }
        }
        .sheet(isPresented: $appState.showingNewStack) {
            if let board = appState.selectedBoard {
                NewStackSheet(boardId: board.id, onDismiss: {
                    appState.showingNewStack = false
                })
                .environmentObject(appState)
            }
        }
        .confirmationDialog("Delete card?", isPresented: Binding(
            get: { appState.cardPendingDelete != nil },
            set: {
                if !$0 {
                    appState.cardPendingDelete = nil
                }
            }
        )) {
            Button("Delete", role: .destructive) {
                Task { await appState.deletePendingCard() }
            }
            Button("Cancel", role: .cancel) {
                appState.cardPendingDelete = nil
            }
        } message: {
            if let card = appState.cardPendingDelete {
                Text(DeleteConfirmation.message("\u{201c}\(card.title)\u{201d}"))
            }
        }
        // The single place lists are loaded on board selection; changing board cancels the previous load.
        .task(id: appState.selectedBoardId) {
            // Labels and people differ per board, so a new board starts unfiltered.
            appState.cardFilter = CardFilter()
            guard let bid = appState.selectedBoardId else {
                appState.clearStacks()
                return
            }
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
                .opacity(appState.isLoadingStacks && !appState.stacks.isEmpty ? 1 : 0)
                .help("Refreshing lists")
                .accessibilityHidden(!appState.isLoadingStacks)
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
                appState.showingArchivedCards = true
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
            .disabled(appState.isLoadingStacks)
            Button {
                appState.showingNewStack = true
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
            Picker("Due", selection: $appState.cardFilter.due) {
                ForEach(CardFilter.Due.allCases) { due in
                    Text(due.title).tag(due)
                }
            }
            .pickerStyle(.inline)
            Toggle("Hide done cards", isOn: $appState.cardFilter.hideDone)
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
                appState.cardFilter = CardFilter(text: appState.cardFilter.text)
            }
        } label: {
            SwiftUI.Label(
                "Filter",
                systemImage: appState.cardFilter.isActive
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
            get: { appState.cardFilter[keyPath: keyPath].contains(value) },
            set: { isOn in
                if isOn {
                    appState.cardFilter[keyPath: keyPath].insert(value)
                } else {
                    appState.cardFilter[keyPath: keyPath].remove(value)
                }
            }
        )
    }

    private var filterStatus: some View {
        let all = appState.stacks.flatMap { $0.cards ?? [] }
        let shown = all.filter { appState.cardFilter.matches($0) }.count
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(.tint)
            Text("Showing \(shown) of \(all.count) cards. Drag and drop is paused while filtering.")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Clear") {
                appState.cardFilter = CardFilter()
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
        if appState.isLoadingStacks && appState.stacks.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(1.2)
                Text("Loading lists…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = appState.stacksError, appState.stacks.isEmpty {
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
                    ForEach(Array(appState.stacks.enumerated()), id: \.element.id) { index, stack in
                        StackColumnView(
                            board: board,
                            stack: stack,
                            onSelectCard: { card in
                                appState.selectedCardId = card.id
                                appState.openedCard = card
                            }
                        )
                        .environmentObject(appState)
                        .draggableList(DraggedStack(id: stack.id, index: index), enabled: !appState.isReadOnly) {
                            appState.isDraggingStack = true
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
            .onChange(of: appState.selectedCardId) { _, id in
                // A card selected from the menus or by creating it: the arrow keys carry on from there.
                if id != nil, appState.openedCard == nil, appState.newCardListId == nil {
                    isBoardFocused = true
                }
            }
            .onChange(of: appState.openedCard?.id) { _, id in
                // Back from the card's sheet: carry on with the keyboard.
                if id == nil, appState.selectedCardId != nil {
                    isBoardFocused = true
                }
            }
            .onDrop(of: stackDropTypes, isTargeted: nil) { _ in
                // Catch-all: reset stack-dragging state for drops that miss a gap
                dragLogger.notice("Drop outside the lists ignored")
                appState.isDraggingStack = false
                return false
            }
        }
    }

    /// The gap before list `index`, where a dragged list can be dropped. It only reacts to a dragged list: a card
    /// dragged across it would otherwise widen it, pushing the next list away from the pointer so the card landed
    /// in the gap, which ignored it and left the card where it was.
    @ViewBuilder
    private func stackInsertionGap(at index: Int, boardId: Int) -> some View {
        let targeted = stackDragInsertIndex == index && appState.isDraggingStack
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
                    if isTargeted, appState.isDraggingStack {
                        stackDragInsertIndex = index
                    } else if stackDragInsertIndex == index {
                        stackDragInsertIndex = nil
                    }
                }
            ),
            perform: { providers in
                dragLogger.notice("Drop between lists at \(index), list drag: \(appState.isDraggingStack)")
                guard appState.isDraggingStack else { return false }
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
            appState.selectCard(direction)
            return .handled
        }
        guard key == .return, appState.selectedCard != nil else { return .ignored }
        appState.openSelectedCard()
        return .handled
    }

    private func handleStackDrop(providers: [NSItemProvider], insertIndex: Int, boardId: Int) -> Bool {
        providers.loadDroppedText { text in
            Task { @MainActor in
                appState.isDraggingStack = false
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
        .environmentObject(AppState())
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
