import os
import SwiftUI
import UniformTypeIdentifiers

private struct DraggedCard: Codable {
    let id: Int
    let stackId: Int

    var providerString: String {
        "\(id):\(stackId)"
    }

    static func fromProviderString(_ value: String) -> Self? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let id = Int(parts[0]),
              let stackId = Int(parts[1]) else {
            return nil
        }
        return Self(id: id, stackId: stackId)
    }
}

struct StackColumnView: View {
    let board: Board
    let stack: Stack
    var onSelectCard: (Card) -> Void
    @EnvironmentObject private var appState: AppState

    @State private var newCardTitle = ""
    @State private var pendingDelete = false
    @State private var dragInsertIndex: Int?
    @State private var isColumnDropTargeted = false
    /// The list's title is being edited in place; `renameTitle` holds the edit.
    @State private var isRenaming = false
    @State private var renameTitle = ""
    @FocusState private var isRenameFocused: Bool
    @FocusState private var isNewCardFocused: Bool

    private var isDropTargeted: Bool {
        guard !appState.isDraggingStack else { return false }
        return dragInsertIndex != nil || isColumnDropTargeted
    }

    private let dropTypes = [
        UTType.plainText.identifier,
        UTType.utf8PlainText.identifier,
        UTType.text.identifier,
    ]

    /// The stack's cards that match the board's filter, in order.
    private var cards: [Card] {
        appState.shownCards(in: stack)
    }

    /// Whether this list shows its "new card" field; File > New Card opens it too.
    private var isAddingCard: Bool {
        get { appState.newCardListId == stack.id }
        nonmutating set {
            if newValue {
                appState.newCardListId = stack.id
            } else if appState.newCardListId == stack.id {
                appState.newCardListId = nil
            }
        }
    }

    /// Drag and drop places cards by position among all of a stack's cards, so it is off while some are hidden.
    private var isFiltering: Bool {
        appState.cardFilter.isActive
    }

    /// Nothing can be changed while the server can't be reached (#156).
    private var isReadOnly: Bool {
        appState.isReadOnly
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            cardList
            if !isReadOnly {
                addCardField
            }
        }
        .frame(width: 280)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isDropTargeted ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
        .onDrop(of: dropTypes, isTargeted: $isColumnDropTargeted, perform: handleColumnDrop(providers:))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("list: \(stack.title)")
        .confirmationDialog("Delete list?", isPresented: $pendingDelete) {
            Button("Delete", role: .destructive) {
                Task {
                    await appState.deleteStack(boardId: board.id, stackId: stack.id)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = false
            }
        } message: {
            Text(DeleteConfirmation.message("\u{201c}\(stack.title)\u{201d} and all its cards"))
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            if isRenaming {
                renameField
            } else {
                Text(stack.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        if board.canEdit, !isReadOnly {
                            startRenaming()
                        }
                    }
            }
            Menu {
                if board.canEdit {
                    Button {
                        startRenaming()
                    } label: {
                        Label("Rename list", systemImage: "pencil")
                    }
                }
                Button(role: .destructive) {
                    pendingDelete = true
                } label: {
                    Label("Delete list", systemImage: "trash")
                }
                .help("Delete this list and its cards")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .disabled(isReadOnly)
            .fixedSize()
            .accessibilityLabel("List actions")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// The title, editable in place: Return or clicking elsewhere saves, Escape cancels.
    private var renameField: some View {
        TextField("List name", text: $renameTitle)
            .textFieldStyle(.roundedBorder)
            .font(.headline)
            .focused($isRenameFocused)
            .frame(maxWidth: .infinity)
            .onAppear {
                // Focusing in the same update as the field appears is sometimes ignored.
                Task { @MainActor in isRenameFocused = true }
            }
            .onSubmit { finishRenaming() }
            .onExitCommand { isRenaming = false }
            .onChange(of: isRenameFocused) { _, focused in
                if !focused {
                    finishRenaming()
                }
            }
    }

    private func startRenaming() {
        renameTitle = stack.title
        isRenaming = true
    }

    private func finishRenaming() {
        guard isRenaming else { return }
        isRenaming = false
        let title = renameTitle
        Task { await appState.renameStack(boardId: board.id, stackId: stack.id, title: title) }
    }

    private var cardList: some View {
        let currentCards = cards
        return ScrollViewReader { proxy in
            cardScrollView(currentCards)
                .onChange(of: appState.selectedCardId) { _, id in
                    // Keep the card the arrow keys select in view.
                    if let id, currentCards.contains(where: { $0.id == id }) {
                        withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id) }
                    }
                }
        }
    }

    private func cardScrollView(_ currentCards: [Card]) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 0) {
                insertionGap(at: 0)
                if currentCards.isEmpty, isFiltering {
                    Text("No matching cards")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
                ForEach(0 ..< currentCards.count, id: \.self) { index in
                    CardRowView(
                        card: currentCards[index],
                        isSelected: appState.selectedCardId == currentCards[index].id,
                        onDelete: isReadOnly ? nil : { appState.cardPendingDelete = currentCards[index] },
                        onToggleDone: isReadOnly ? nil : {
                            let card = currentCards[index]
                            Task { await appState.setCardDone(boardId: board.id, card: card, done: !card.isDone) }
                        },
                        onArchive: isReadOnly ? nil : {
                            let card = currentCards[index]
                            Task { await appState.archiveCard(card, boardId: board.id) }
                        },
                        isDraggable: !isFiltering && !isReadOnly,
                        // A list drag that was cancelled may have left this set; this drag is a card.
                        onDragStart: { appState.isDraggingStack = false },
                        action: { onSelectCard(currentCards[index]) }
                    )
                    .padding(.horizontal, 10)
                    .id(currentCards[index].id)
                    insertionGap(at: index + 1)
                }
            }
            .padding(.bottom, 4)
        }
        .frame(maxHeight: .infinity)
        .background(dropTargetBackground)
    }

    @ViewBuilder
    private func insertionGap(at index: Int) -> some View {
        let targeted = dragInsertIndex == index && !appState.isDraggingStack
        ZStack(alignment: .center) {
            Color.clear
                .frame(height: targeted ? 20 : 8)
            if targeted {
                HStack(spacing: 0) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                }
                .padding(.horizontal, 10)
            }
        }
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.1), value: targeted)
        .onDrop(
            of: dropTypes,
            isTargeted: Binding(
                get: { dragInsertIndex == index },
                set: { isTargeted in
                    if isTargeted {
                        dragInsertIndex = index
                    } else if dragInsertIndex == index {
                        dragInsertIndex = nil
                    }
                }
            ),
            perform: { providers in
                handleDropAtIndex(providers: providers, insertIndex: index)
            }
        )
    }

    private var addCardField: some View {
        Group {
            if isAddingCard {
                HStack(spacing: 8) {
                    TextField("Card title", text: $newCardTitle)
                        .textFieldStyle(.plain)
                        .focused($isNewCardFocused)
                        .onAppear {
                            // Focusing in the same update as the field appears is sometimes ignored.
                            Task { @MainActor in isNewCardFocused = true }
                        }
                        .onSubmit { submitNewCard() }
                        .onExitCommand { cancelNewCard() }
                    Button("Add") { submitNewCard() }
                        .buttonStyle(.borderedProminent)
                    Button("Cancel") { cancelNewCard() }
                }
                .padding(10)
            } else {
                Button {
                    isAddingCard = true
                } label: {
                    SwiftUI.Label("Add card", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(10)
                .accessibilityLabel("Add card")
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(10)
    }

    private func cancelNewCard() {
        isAddingCard = false
        newCardTitle = ""
    }

    private func submitNewCard() {
        let title = newCardTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        newCardTitle = ""
        isAddingCard = false
        Task {
            await appState.createCard(boardId: board.id, stackId: stack.id, title: title)
        }
    }

    private var borderColor: Color {
        if isDropTargeted {
            return .accentColor
        }
        return Color(nsColor: .separatorColor).opacity(0.5)
    }

    private var dropTargetBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.accentColor.opacity(isDropTargeted ? 0.12 : 0.001))
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
    }

    /// Loads the dragged card from a drop, ignoring drops that aren't a card (such as a dragged list).
    private func loadDraggedCard(
        from providers: [NSItemProvider],
        completion: @escaping @Sendable (DraggedCard) -> Void
    )
        -> Bool {
        providers.loadDroppedText { text in
            guard let draggedCard = DraggedCard.fromProviderString(text) else {
                dragLogger.notice("Drop ignored: not a card: \(text, privacy: .public)")
                return
            }
            completion(draggedCard)
        }
    }

    private func handleDropAtIndex(providers: [NSItemProvider], insertIndex: Int) -> Bool {
        dragLogger.notice("Drop on list \(stack.id) at position \(insertIndex)")
        // A list dropped here (rather than between lists) ends its drag too.
        appState.isDraggingStack = false
        return loadDraggedCard(from: providers) { draggedCard in
            Task { @MainActor in
                if draggedCard.stackId == stack.id {
                    // Reorder within the same stack
                    let currentCards = cards
                    guard let fromIndex = currentCards.firstIndex(where: { $0.id == draggedCard.id }) else { return }
                    // Adjust target: after removing the card the indices above it shift down by one
                    let targetOrder = insertIndex > fromIndex ? insertIndex - 1 : insertIndex
                    guard targetOrder != fromIndex else { return }
                    await appState.reorderCard(
                        boardId: board.id,
                        fromStackId: stack.id,
                        cardId: draggedCard.id,
                        toStackId: stack.id,
                        order: targetOrder
                    )
                } else {
                    // Move card from another stack, inserting at the specific position
                    await appState.moveCard(
                        boardId: board.id,
                        cardId: draggedCard.id,
                        fromStackId: draggedCard.stackId,
                        toStackId: stack.id,
                        order: insertIndex
                    )
                    logMoveResult(cardId: draggedCard.id)
                }
            }
        }
    }

    /// Logs where the server put a card this list asked to move.
    private func logMoveResult(cardId: Int) {
        let list = appState.stacks.first { $0.cards?.contains { $0.id == cardId } == true }?.id
        let outcome = list.map { "is in list \($0)" } ?? "is in no list"
        dragLogger.notice("Moved card \(cardId) to list \(stack.id): it \(outcome, privacy: .public)")
        if let error = appState.actionError {
            dragLogger.error("Moving card \(cardId) failed: \(error, privacy: .public)")
        }
    }

    /// Fallback drop handler on the whole column — only handles cross-stack moves,
    /// appending the card to the end of this list. Gap drops take priority for
    /// precise placement (both cross-stack and within-stack reordering).
    private func handleColumnDrop(providers: [NSItemProvider]) -> Bool {
        dragLogger.notice("Drop on list \(stack.id), not between cards")
        appState.isDraggingStack = false
        return loadDraggedCard(from: providers) { draggedCard in
            guard draggedCard.stackId != stack.id else {
                dragLogger.notice("Drop ignored: card \(draggedCard.id) is already in list \(stack.id)")
                return
            }

            Task { @MainActor in
                await appState.moveCard(
                    boardId: board.id,
                    cardId: draggedCard.id,
                    fromStackId: draggedCard.stackId,
                    toStackId: stack.id,
                    order: cards.count
                )
                logMoveResult(cardId: draggedCard.id)
            }
        }
    }
}

struct CardRowView: View {
    let card: Card
    /// Outlined as the card the Card menu acts on.
    var isSelected = false
    var onDelete: (() -> Void)?
    var onToggleDone: (() -> Void)?
    var onArchive: (() -> Void)?
    var isDraggable = true
    var onDragStart: (() -> Void)?
    var action: () -> Void
    @State private var isHovering = false

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if card.isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Text(card.title)
                    .font(.system(.body, design: .default))
                    .foregroundStyle(card.isDone ? .secondary : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            if let dates = Self.datesText(card) {
                let overdue = card.isOverdue()
                HStack(spacing: 4) {
                    Image(systemName: overdue ? "exclamationmark.circle" : "calendar")
                        .font(.caption2)
                    Text(dates)
                        .font(.caption2)
                }
                .foregroundStyle(overdue ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
            if let progress = card.checklistProgress {
                HStack(spacing: 4) {
                    Image(systemName: progress.isComplete ? "checklist.checked" : "checklist")
                        .font(.caption2)
                    Text("\(progress.done)/\(progress.total)")
                        .font(.caption2)
                }
                .foregroundStyle(progress.isComplete ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .accessibilityLabel("Checklist \(progress.done) of \(progress.total) done")
            }
            if let count = card.commentsCount, count > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "text.bubble")
                        .font(.caption2)
                    Text("\(count)")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .accessibilityLabel(count == 1 ? "1 comment" : "\(count) comments")
            }
            if let count = card.attachmentCount, count > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "paperclip")
                        .font(.caption2)
                    Text("\(count)")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            if !card.assignments.isEmpty {
                HStack(spacing: -4) {
                    ForEach(card.assignments.prefix(3)) { assignment in
                        AvatarBadge(user: assignment.participant, size: 20)
                    }
                    if card.assignments.count > 3 {
                        Text("+\(card.assignments.count - 3)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 8)
                    }
                }
            }
            if let labels = card.labels, !labels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(labels.prefix(3)) { label in
                        Text(label.title)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(hex: label.color ?? "cccccc") ?? .gray.opacity(0.3))
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            (isHovering ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .windowBackgroundColor))
                .opacity(isHovering ? 1.0 : 0.98)
        )
        .clipShape(cardShape)
        .overlay(
            cardShape
                .strokeBorder(
                    isSelected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(isHovering ? 0.6 : 0.4),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .shadow(color: .black.opacity(isHovering ? 0.08 : 0.05), radius: isHovering ? 4 : 2, y: 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .draggableCard(card, enabled: isDraggable, onStart: onDragStart)
        .onHover { hovering in
            isHovering = hovering
            DispatchQueue.main.async {
                (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityIdentifier("card: \(card.title)")
        .accessibilityHint("Opens card details")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            if let onToggleDone {
                Button(card.isDone ? "Mark as Not Done" : "Mark as Done") {
                    onToggleDone()
                }
            }
            if let onArchive {
                Button("Archive Card") {
                    onArchive()
                }
            }
            if let onDelete {
                Button("Delete card", role: .destructive) {
                    onDelete()
                }
            }
        }
    }

    /// "Oct 10, 12:00"-style due date for the card row.
    private static func dueText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// "Oct 3 – Oct 10, 12:00" with a start date, "Starts Oct 3" with only that, else the due date.
    private static func datesText(_ card: Card) -> String? {
        let start = card.startDate?.formatted(.dateTime.month(.abbreviated).day())
        switch (start, card.dueDate) {
        case let (start?, due?): return "\(start) \u{2013} \(dueText(due))"
        case let (start?, nil): return "Starts \(start)"
        case let (nil, due?): return dueText(due)
        case (nil, nil): return nil
        }
    }

    /// What VoiceOver reads for the row: the title plus done/overdue/due state.
    private var accessibilityDescription: String {
        var parts = [card.title]
        if card.isDone {
            parts.append("Done")
        }
        if let startDate = card.startDate {
            parts.append("Starts " + startDate.formatted(.dateTime.month(.wide).day()))
        }
        if let dueDate = card.dueDate {
            parts.append((card.isOverdue() ? "Overdue, was due " : "Due ") + Self.dueText(dueDate))
        }
        if !card.assignments.isEmpty {
            parts.append("Assigned to " + card.assignments.map(\.participant.displayName).joined(separator: ", "))
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Card dragging

private extension View {
    /// Lets the card be dragged to another position or list, unless `enabled` is false (while filtering).
    @ViewBuilder
    func draggableCard(_ card: Card, enabled: Bool, onStart: (() -> Void)?) -> some View {
        if enabled {
            onDrag {
                onStart?()
                dragLogger.notice("Card drag started: card \(card.id) in list \(card.stackId)")
                let dragged = DraggedCard(id: card.id, stackId: card.stackId)
                return NSItemProvider(object: NSString(string: dragged.providerString))
            }
        } else {
            self
        }
    }
}

// MARK: - Avatar badge

/// A user's initials in a circle, coloured consistently per user.
struct AvatarBadge: View {
    let user: DeckUser
    var size: CGFloat = 22

    private static let palette: [Color] = [.teal, .orange, .pink, .indigo, .green, .brown, .purple, .red]

    private var color: Color {
        // A stable hash (String.hashValue changes between launches).
        let sum = user.uid.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
        return Self.palette[sum % Self.palette.count]
    }

    var body: some View {
        Text(user.initials)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: Circle())
            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            .help(user.displayName)
            .accessibilityLabel(user.displayName)
    }
}

#Preview {
    StackColumnView(
        board: Board(
            id: 1,
            title: "Test",
            color: "0082c9",
            archived: false,
            owner: nil,
            labels: [],
            acl: [],
            permissions: nil,
            users: [],
            shared: nil,
            deletedAt: nil,
            lastModified: nil,
            settings: nil
        ),
        stack: Stack(id: 1, title: "To Do", boardId: 1, deletedAt: nil, lastModified: nil, cards: [], order: 0),
        onSelectCard: { _ in }
    )
    .environmentObject(AppState())
}
