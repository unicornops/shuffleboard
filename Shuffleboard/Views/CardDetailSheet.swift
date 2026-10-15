import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CardDetailSheet: View {
    let card: Card
    let boardId: Int
    var onDismiss: () -> Void
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var description: String
    /// Showing the plain-text editor rather than the rendered Markdown.
    @State private var isEditingDescription: Bool
    @State private var hasStartDate: Bool
    @State private var startDate: Date
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var isDone: Bool
    @State private var isSaving = false
    @State private var showDeleteConfirmation = false
    @State private var showCreateLabel = false
    @State private var newLabelTitle = ""
    @State private var newLabelColor = "31CC7C"
    @State private var isCreatingLabel = false
    /// nil until loaded; then the card's attachments, including deleted ones Deck can still restore.
    @State private var attachments: [Attachment]?
    @State private var pendingAttachmentDelete: Attachment?
    @State private var isLoadingAttachments = false
    @State private var isUploadingAttachment = false
    @State private var showFileImporter = false
    @State private var attachmentError: String?
    @State private var saveError: String?

    /// Nothing can be changed while the server can't be reached (#156).
    private var isReadOnly: Bool {
        appState.isReadOnly
    }

    private var board: Board? {
        guard let b = appState.selectedBoard, b.id == boardId else { return nil }
        return b
    }

    /// Latest card from stacks so label assign/remove updates in the sheet.
    private var currentCard: Card? {
        guard let stack = appState.stacks.first(where: { $0.id == card.stackId }) else { return nil }
        return stack.cards?.first(where: { $0.id == card.id })
    }

    private var cardLabels: [DeckLabel] {
        (currentCard ?? card).labels ?? []
    }

    /// Attachments to display: from API load, or from card (stacks may include attachments). Deleted ones are
    /// listed (to restore) only if Deck can restore them.
    private var displayedAttachments: [Attachment] {
        (attachments ?? (currentCard ?? card).attachments ?? []).filter { !$0.isDeleted || $0.canBeRestored }
    }

    private var availableBoardLabels: [DeckLabel] {
        guard let board else { return [] }
        let assignedIds = Set(cardLabels.map(\.id))
        return board.labels.filter { !assignedIds.contains($0.id) }
    }

    init(card: Card, boardId: Int, onDismiss: @escaping () -> Void) {
        self.card = card
        self.boardId = boardId
        self.onDismiss = onDismiss
        _title = State(initialValue: card.title)
        _description = State(initialValue: card.description ?? "")
        _isEditingDescription = State(initialValue: (card.description ?? "").isEmpty)
        _hasStartDate = State(initialValue: card.startDate != nil)
        _startDate = State(initialValue: card.startDate ?? Self.defaultStartDate())
        _hasDueDate = State(initialValue: card.dueDate != nil)
        _dueDate = State(initialValue: card.dueDate ?? Self.defaultDueDate())
        _isDone = State(initialValue: card.isDone)
        _attachments = State(initialValue: card.attachments)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(isReadOnly ? "Close" : "Cancel") {
                    dismiss()
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if !isReadOnly {
                    saveButton
                }
            }
            .padding()
            Divider()

            Form {
                if isReadOnly {
                    Section {
                        Label(
                            "The server can't be reached, so this card can't be changed until it can.",
                            systemImage: "wifi.slash"
                        )
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("card read-only notice")
                    }
                }
                formSections
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(width: 440, height: 660)
        .actionErrorBanner(appState)
        .navigationTitle(isReadOnly ? "Card" : "Edit Card")
        .sheet(isPresented: $showCreateLabel) {
            createLabelSheet
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item, .data, .content],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result: result)
        }
        .task {
            // Offline, the card's attachments as listed on the board are all there is.
            guard !isReadOnly else { return }
            await loadAttachments()
        }
        .confirmationDialog("Delete card?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                Task {
                    let deleted = await appState.deleteCard(boardId: boardId, stackId: card.stackId, cardId: card.id)
                    // On failure stay open so the error banner is shown alongside the card.
                    if deleted {
                        await MainActor.run {
                            dismiss()
                            onDismiss()
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                showDeleteConfirmation = false
            }
        } message: {
            Text(DeleteConfirmation.message("This card"))
        }
        .confirmationDialog("Remove attachment?", isPresented: Binding(
            get: { pendingAttachmentDelete != nil },
            set: {
                if !$0 {
                    pendingAttachmentDelete = nil
                }
            }
        )) {
            Button("Remove", role: .destructive) {
                if let attachment = pendingAttachmentDelete {
                    deleteAttachment(attachment)
                }
                pendingAttachmentDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingAttachmentDelete = nil
            }
        } message: {
            if let attachment = pendingAttachmentDelete {
                Text(Self.removalMessage(attachment))
            }
        }
    }

    private var saveButton: some View {
        Button {
            save()
        } label: {
            if isSaving {
                ProgressView()
                    .scaleEffect(0.8)
                    .frame(minWidth: 44)
            } else {
                Text("Save")
            }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(isSaving || title.isEmpty || !edits.datesAreInOrder)
    }

    @ViewBuilder
    private var formSections: some View {
        if let saveError {
            Section {
                Label("Could not save card: \(saveError)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        Section("Title") {
            TextField("Title", text: $title)
                .accessibilityIdentifier("card title")
                .disabled(isReadOnly)
        }
        Section {
            descriptionContent
        } header: {
            HStack {
                Text("Description")
                Spacer()
                if !isReadOnly {
                    Button(isEditingDescription ? "Preview" : "Edit") {
                        isEditingDescription.toggle()
                    }
                    .buttonStyle(.link)
                }
            }
        }
        Section("Dates") {
            scheduleContent
                .disabled(isReadOnly)
        }
        Section("Assigned to") {
            assigneesContent
                .disabled(isReadOnly)
        }
        Section("Labels") {
            labelsContent
                .disabled(isReadOnly)
        }
        Section("Attachments") {
            attachmentsContent
                .disabled(isReadOnly)
        }
        Section("Comments") {
            CardCommentsView(card: card)
        }
        if !appState.activityIsUnavailable {
            Section("Activity") {
                CardActivityView(card: card)
            }
        }
        if !isReadOnly {
            cardActions
        }
    }

    private var cardActions: some View {
        Section {
            Button("Archive card") {
                Task {
                    await appState.archiveCard(currentCard ?? card, boardId: boardId)
                    dismiss()
                    onDismiss()
                }
            }
            .help("Hide the card from the board; restore it from Archived Cards")
            Button("Delete card", role: .destructive) {
                showDeleteConfirmation = true
            }
        }
    }
}

// MARK: - Sections

extension CardDetailSheet {

    // MARK: - Assignees UI

    private var cardAssignments: [CardAssignment] {
        (currentCard ?? card).assignments
    }

    /// Board users not yet assigned to the card.
    private var availableAssignees: [DeckUser] {
        guard let board else { return [] }
        let assigned = Set(
            cardAssignments.filter { $0.type == CardAssignment.userType }.map(\.participant.uid)
        )
        return board.assignableUsers.filter { !assigned.contains($0.uid) }
    }

    private var assigneesContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(cardAssignments) { assignment in
                HStack(spacing: 8) {
                    AvatarBadge(user: assignment.participant)
                    Text(assignment.participant.displayName)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        let target = currentCard ?? card
                        Task { await appState.unassign(assignment, boardId: boardId, card: target) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .help("Unassign")
                    .accessibilityLabel("Unassign \(assignment.participant.displayName)")
                }
            }
            Menu {
                ForEach(availableAssignees, id: \.uid) { user in
                    Button(user.displayName) {
                        let target = currentCard ?? card
                        Task { await appState.assignUser(user, boardId: boardId, card: target) }
                    }
                }
            } label: {
                Text("Assign")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(availableAssignees.isEmpty)
            .help(availableAssignees.isEmpty ? "Everyone on this board is assigned" : "Assign someone to this card")
        }
    }

    // MARK: - Description UI

    @ViewBuilder
    private var descriptionContent: some View {
        if isEditingDescription, !isReadOnly {
            TextEditor(text: $description)
                .frame(minHeight: 120)
                .font(.body)
        } else if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("No description")
                .foregroundStyle(.secondary)
        } else {
            // Ticking a checklist item edits the draft; it's saved with the card.
            MarkdownView(text: description, onToggleTask: isReadOnly ? nil : { line in
                description = Markdown.togglingTask(atLine: line, in: description)
            })
        }
    }

    // MARK: - Dates UI

    private var scheduleContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Deck before 1.18 has no start dates.
            if appState.supportsStartDates || card.startDate != nil {
                Toggle("Has a start date", isOn: $hasStartDate)
                    .accessibilityIdentifier("has start date")
                if hasStartDate {
                    DatePicker("Start", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
                }
            }
            Toggle("Has a due date", isOn: $hasDueDate)
                .accessibilityIdentifier("has due date")
            if hasDueDate {
                DatePicker("Due", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
            }
            if !edits.datesAreInOrder {
                Label(CardEdits.datesOutOfOrderMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Toggle("Done", isOn: $isDone)
        }
    }

    /// What Save sends.
    private var edits: CardEdits {
        CardEdits(
            title: title,
            description: description,
            startDate: hasStartDate ? startDate : nil,
            dueDate: hasDueDate ? dueDate : nil,
            isDone: isDone
        )
    }

    /// Today at 9:00, the starting point when adding a start date.
    private static func defaultStartDate(now: Date = Date()) -> Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: now) ?? now
    }

    /// Tomorrow at 9:00, the starting point when adding a due date.
    private static func defaultDueDate(now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    // MARK: - Attachments UI

    private var attachmentsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoadingAttachments {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading attachments…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if displayedAttachments.isEmpty {
                if let err = attachmentError {
                    Text(err)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                } else {
                    Text("No attachments")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(displayedAttachments) { attachment in
                    AttachmentRowView(
                        attachment: attachment,
                        onDownload: { downloadAttachment(attachment) },
                        onDelete: { pendingAttachmentDelete = attachment },
                        onRestore: { restoreAttachment(attachment) }
                    )
                }
            }
            HStack {
                Button {
                    showFileImporter = true
                } label: {
                    Label("Add file…", systemImage: "paperclip")
                }
                .disabled(isUploadingAttachment)
                if isUploadingAttachment {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
        }
    }

    /// What removing `attachment` does, which depends on how Deck stores it.
    private static func removalMessage(_ attachment: Attachment) -> String {
        let name = "\u{201c}\(attachment.displayName)\u{201d}"
        if attachment.canBeRestored {
            return "\(name) will be removed from this card. You can restore it here until the server clears "
                + "deleted items."
        }
        return "\(name) will be removed from this card. This can't be undone, but the file stays in its owner's "
            + "Files."
    }

    private func deleteAttachment(_ attachment: Attachment) {
        Task {
            let deleted = await appState.deleteAttachment(
                boardId: boardId,
                stackId: card.stackId,
                cardId: card.id,
                attachmentId: attachment.id,
                type: attachment.type
            )
            guard deleted else { return }
            await MainActor.run {
                // Shown straight away: a restorable attachment stays, greyed out; another one goes.
                var list = displayedAttachments
                if attachment.canBeRestored, let idx = list.firstIndex(where: { $0.id == attachment.id }) {
                    list[idx].deletedAt = Int(Date().timeIntervalSince1970)
                } else {
                    list.removeAll { $0.id == attachment.id && $0.type == attachment.type }
                }
                attachments = list
            }
            await loadAttachments()
        }
    }

    private func restoreAttachment(_ attachment: Attachment) {
        Task {
            let restored = await appState.restoreAttachment(
                attachment,
                boardId: boardId,
                stackId: card.stackId,
                cardId: card.id
            )
            guard restored else { return }
            await MainActor.run {
                var list = displayedAttachments
                if let idx = list.firstIndex(where: { $0.id == attachment.id && $0.type == attachment.type }) {
                    list[idx].deletedAt = 0
                }
                attachments = list
            }
            await loadAttachments()
        }
    }

    private func loadAttachments() async {
        await MainActor.run {
            isLoadingAttachments = true
            attachmentError = nil
        }

        var loaded: [Attachment] = []

        // 1. Try full card fetch (may include attachments inline)
        let fullCard = await appState.getFullCard(boardId: boardId, stackId: card.stackId, cardId: card.id)
        if let atts = fullCard?.attachments, !atts.isEmpty {
            loaded = atts
        }

        // 2. Dedicated attachments endpoint
        if loaded.isEmpty {
            loaded = await appState.getAttachments(boardId: boardId, stackId: card.stackId, cardId: card.id)
        }

        // 3. Fall back to card data already in stacks
        if loaded.isEmpty {
            loaded = (currentCard ?? card).attachments ?? []
        }

        await MainActor.run {
            if !loaded.isEmpty {
                attachments = loaded
            } else if let count = (currentCard ?? card).attachmentCount, count > 0 {
                attachmentError = "Could not load \(count) attachment(s)."
            }
            isLoadingAttachments = false
        }
    }

    private func handleFileImport(result: Result<[URL], Error>) {
        guard case let .success(urls) = result else { return }
        let fileURLs = urls.filter { !$0.hasDirectoryPath }
        guard !fileURLs.isEmpty else { return }
        Task {
            await MainActor.run { isUploadingAttachment = true }
            for url in fileURLs {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                if await appState.uploadAttachment(
                    boardId: boardId,
                    stackId: card.stackId,
                    cardId: card.id,
                    fileURL: url
                ) {
                    await loadAttachments()
                }
            }
            await MainActor.run { isUploadingAttachment = false }
        }
    }

    private func downloadAttachment(_ attachment: Attachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.displayName
        panel.allowedContentTypes = [.data]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                let success = await appState.downloadAttachment(
                    boardId: boardId,
                    stackId: card.stackId,
                    cardId: card.id,
                    attachment: attachment,
                    saveURL: url
                )
                if !success {
                    await MainActor.run {
                        appState.actionError = appState.actionError ?? "Could not download attachment"
                    }
                }
            }
        }
    }
}

// MARK: - Labels

extension CardDetailSheet {

    // MARK: - Labels UI

    private var labelsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !cardLabels.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(cardLabels) { label in
                        LabelChip(label: label) {
                            Task {
                                await appState.removeLabel(
                                    boardId: boardId,
                                    stackId: card.stackId,
                                    cardId: card.id,
                                    labelId: label.id
                                )
                            }
                        }
                    }
                }
            }
            Menu {
                ForEach(availableBoardLabels) { label in
                    Button {
                        Task {
                            await appState.assignLabel(
                                boardId: boardId,
                                stackId: card.stackId,
                                cardId: card.id,
                                labelId: label.id
                            )
                        }
                    } label: {
                        Label(label.title, systemImage: "tag.fill")
                    }
                }
                if !availableBoardLabels.isEmpty {
                    Divider()
                }
                Button {
                    newLabelTitle = ""
                    newLabelColor = "31CC7C"
                    showCreateLabel = true
                } label: {
                    Label("Create new tag…", systemImage: "plus.circle")
                }
            } label: {
                Text("Add label")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(board == nil)
        }
    }

    private var createLabelSheet: some View {
        LabelEditorSheet(
            title: $newLabelTitle,
            color: $newLabelColor,
            isCreating: $isCreatingLabel,
            onCreate: {
                isCreatingLabel = true
                Task {
                    if let labelId = await appState.createLabel(
                        boardId: boardId,
                        title: newLabelTitle,
                        color: newLabelColor
                    ) {
                        await appState.assignLabel(
                            boardId: boardId,
                            stackId: card.stackId,
                            cardId: card.id,
                            labelId: labelId
                        )
                        await MainActor.run {
                            showCreateLabel = false
                            newLabelTitle = ""
                            newLabelColor = "31CC7C"
                        }
                    }
                    await MainActor.run { isCreatingLabel = false }
                }
            },
            onCancel: { showCreateLabel = false }
        )
    }

    private func save() {
        isSaving = true
        saveError = nil
        Task {
            // Start from the latest copy of the card so changes made since the sheet opened are kept.
            let saved = await appState.updateCard(
                boardId: boardId,
                stackId: card.stackId,
                card: currentCard ?? card,
                edits: edits
            )
            await MainActor.run {
                isSaving = false
                if saved {
                    dismiss()
                    onDismiss()
                } else {
                    saveError = appState.errorMessage ?? "Unknown error"
                }
            }
        }
    }
}

// MARK: - Attachment row

private struct AttachmentRowView: View {
    let attachment: Attachment
    var onDownload: () -> Void
    var onDelete: () -> Void
    var onRestore: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: attachment.isDeleted ? "doc" : "doc.fill")
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.displayName)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(attachment.isDeleted ? .secondary : .primary)
                if attachment.isDeleted {
                    Text("Removed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let size = attachment.formattedSize {
                    Text(size)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if attachment.isDeleted {
                Button("Restore", action: onRestore)
                    .buttonStyle(.link)
                    .help("Put the attachment back on the card")
                    .accessibilityLabel("Restore \(attachment.displayName)")
            } else {
                Button {
                    onDownload()
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.plain)
                .help("Download")
                .accessibilityLabel("Download \(attachment.displayName)")
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Remove attachment")
                .accessibilityLabel("Remove \(attachment.displayName)")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(attachment.isDeleted ? 0.25 : 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Label chip

private struct LabelChip: View {
    let label: DeckLabel
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(label.title)
                .font(.caption)
                .lineLimit(1)
            if onRemove != nil {
                Button {
                    onRemove?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(hex: label.color ?? "cccccc") ?? .gray.opacity(0.3))
        .foregroundStyle(.white)
        .clipShape(Capsule())
    }
}
