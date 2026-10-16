import SwiftUI

// MARK: - CreateSheetFooter

/// Reusable footer for "create something" sheets, combining:
///   - an optional inline error message (from `AppState.errorMessage`)
///   - a Cancel button (keyboard shortcut: Escape)
///   - a Create (or `actionTitle`) button with an in-flight spinner (keyboard shortcut: Return)
///
/// Both `BoardSheet` and `NewStackSheet` share this component so that the
/// save/cancel affordance is consistent and maintained in one place.
///
/// **Usage**
/// ```swift
/// CreateSheetFooter(
///     isDisabled: title.trimmingCharacters(in: .whitespaces).isEmpty,
///     isSaving: $isSaving
/// ) {
///     // called when Create is tapped or Return is pressed
///     save()
/// } onCancel: {
///     dismiss()
///     onDismiss()
/// }
/// ```
struct CreateSheetFooter: View {

    // MARK: - Dependencies

    @EnvironmentObject private var appState: AppState

    // MARK: - Configuration

    /// When `true` the Create button is disabled (e.g. title field is empty).
    var isDisabled: Bool

    /// Reflects whether an async save is in progress; the Create button shows a
    /// spinner and is disabled while `true`.
    @Binding var isSaving: Bool

    /// The confirming button's title: "Create", or e.g. "Save" when editing.
    var actionTitle = "Create"

    /// Called when the user taps Create or presses ⌘Return.
    var onSave: () -> Void

    /// Called when the user taps Cancel or presses Escape.
    var onCancel: () -> Void

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            errorRow
            buttonRow
        }
    }

    // MARK: - Private subviews

    @ViewBuilder
    private var errorRow: some View {
        if let err = appState.errorMessage {
            Text(err)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(4)
        }
    }

    private var buttonRow: some View {
        HStack {
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)

            Spacer()

            Button(action: onSave) {
                if isSaving {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(minWidth: 60)
                } else {
                    Text(actionTitle)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isDisabled || isSaving)
        }
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var isSaving = false

    VStack(alignment: .leading, spacing: 20) {
        Text("Preview sheet")
            .font(.headline)

        CreateSheetFooter(
            isDisabled: false,
            isSaving: $isSaving
        ) {
            isSaving = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { isSaving = false }
        } onCancel: {
            // dismiss
        }
    }
    .padding(24)
    .frame(width: 320)
    .previewEnvironment()
}
