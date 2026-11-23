import SwiftUI

// MARK: - BoardLabelsSheet

/// A board's labels, to add, rename, recolour and delete. Offered only when the board can be managed, as Deck
/// requires for changing labels.
struct BoardLabelsSheet: View {
    let boardId: Int
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// The label being edited, or `.new`; presents the editor.
    @State private var editing: EditedLabel?
    @State private var draftTitle = ""
    @State private var draftColor = LabelEditorSheet.defaultColor
    @State private var isSaving = false
    @State private var pendingDelete: DeckLabel?

    /// The live board, so the list reflects changes as soon as they're saved.
    private var board: Board? {
        appState.boards.first { $0.id == boardId }
    }

    private var labels: [DeckLabel] {
        (board?.labels ?? []).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Labels")
                    .font(.headline)
                if let board {
                    Text(board.title)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            if labels.isEmpty {
                ContentUnavailableView(
                    "No Labels",
                    systemImage: "tag",
                    description: Text("Add labels to sort and filter this board's cards.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(labels) { label in
                    row(label)
                }
            }
            Divider()
            HStack {
                Button {
                    edit(nil)
                } label: {
                    Label("New Label", systemImage: "plus")
                }
                Spacer()
            }
            .padding()
        }
        .frame(width: 420, height: 440)
        .actionErrorBanner(appState)
        .sheet(item: $editing) { edited in
            LabelEditorSheet(
                heading: edited.label == nil ? "New label" : "Edit label",
                placeholder: "Label name",
                actionTitle: edited.label == nil ? "Create" : "Save",
                title: $draftTitle,
                color: $draftColor,
                isCreating: $isSaving,
                onCreate: { save(edited) },
                onCancel: { editing = nil }
            )
        }
        .confirmationDialog(
            "Delete label?",
            isPresented: Binding(get: { pendingDelete != nil }, set: {
                if !$0 {
                    pendingDelete = nil
                }
            })
        ) {
            Button("Delete", role: .destructive) {
                if let label = pendingDelete {
                    Task { _ = await appState.deleteLabel(label, boardId: boardId) }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            if let label = pendingDelete {
                Text("""
                “\(label.title)” will be removed from this board and from every card that has it. This can't be \
                undone.
                """)
            }
        }
    }

    private func row(_ label: DeckLabel) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(hex: label.color ?? "") ?? .gray)
                .frame(width: 12, height: 12)
            Text(label.title)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                edit(label)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Rename or recolor")
            .accessibilityLabel("Edit \(label.title)")
            Button {
                pendingDelete = label
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete label")
            .accessibilityLabel("Delete \(label.title)")
        }
        .padding(.vertical, 2)
    }

    private func edit(_ label: DeckLabel?) {
        draftTitle = label?.title ?? ""
        draftColor = label?.color.flatMap { $0.isEmpty ? nil : $0 } ?? LabelEditorSheet.defaultColor
        editing = EditedLabel(label: label)
    }

    private func save(_ edited: EditedLabel) {
        isSaving = true
        Task {
            let saved = if let label = edited.label {
                await appState.updateLabel(label, boardId: boardId, title: draftTitle, color: draftColor)
            } else {
                await appState.createLabel(boardId: boardId, title: draftTitle, color: draftColor) != nil
            }
            await MainActor.run {
                isSaving = false
                if saved {
                    editing = nil
                }
            }
        }
    }
}

/// What the label editor is open for: an existing label, or a new one.
private struct EditedLabel: Identifiable {
    let label: DeckLabel?

    var id: Int {
        label?.id ?? -1
    }
}

// MARK: - LabelEditorSheet

/// A label's title and colour, for creating or editing one.
struct LabelEditorSheet: View {
    static let defaultColor = "31CC7C"

    var heading: LocalizedStringKey = "New tag"
    var placeholder: LocalizedStringKey = "Tag name"
    var actionTitle: LocalizedStringKey = "Create"
    @Binding var title: String
    @Binding var color: String
    @Binding var isCreating: Bool
    var onCreate: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(heading)
                .font(.headline)
            TextField(placeholder, text: $title)
                .textFieldStyle(.roundedBorder)
            BoardColorPickerView(selectedHex: $color)
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(actionTitle) {
                    onCreate()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
            }
        }
        .padding(24)
        .frame(width: 280)
    }
}
