import SwiftUI

// MARK: - BoardColorPickerView

/// A row of preset colour swatches used when creating or editing a board or label.
///
/// Extracted from `BoardSheet` and `CardDetailSheet`, which previously each
/// contained an identical inline implementation. Use this view wherever a board
/// or label colour needs to be chosen from the standard Nextcloud Deck palette.
///
/// **Usage**
/// ```swift
/// @State private var color = BoardColorPickerView.defaultColor
///
/// BoardColorPickerView(selectedHex: $color)
/// ```
struct BoardColorPickerView: View {

    // MARK: - Public API

    /// The hex string of the currently selected colour (e.g. `"0082c9"`).
    @Binding var selectedHex: String

    /// The default board colour used by Nextcloud Deck.
    static let defaultColor = "0082c9"

    /// The palette offered to the user. Matches the colours shown in the
    /// Nextcloud Deck web UI.
    static let presetColors: [(name: LocalizedStringResource, hex: String)] = [
        ("Blue", "0082c9"),
        ("Green", "31CC7C"),
        ("Red", "FF7A66"),
        ("Yellow", "F1DB50"),
        ("Purple", "9C59B6"),
        ("Orange", "F39C12"),
    ]

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Color")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(Self.presetColors, id: \.hex) { preset in
                    swatchButton(for: preset)
                }
            }
        }
    }

    // MARK: - Private helpers

    private func swatchButton(for preset: (name: LocalizedStringResource, hex: String)) -> some View {
        Button {
            selectedHex = preset.hex
        } label: {
            Circle()
                .fill(Color(hex: preset.hex) ?? .gray)
                .frame(width: 24, height: 24)
                .overlay(
                    Circle()
                        .strokeBorder(
                            Color.primary.opacity(0.3),
                            lineWidth: isSelected(preset) ? 3 : 0
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(preset.name))
        .accessibilityAddTraits(isSelected(preset) ? .isSelected : [])
    }

    /// Deck keeps colours as they were sent, so a board's colour may be in either case.
    private func isSelected(_ preset: (name: LocalizedStringResource, hex: String)) -> Bool {
        selectedHex.caseInsensitiveCompare(preset.hex) == .orderedSame
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var selected = BoardColorPickerView.defaultColor
    return BoardColorPickerView(selectedHex: $selected)
        .padding()
}
