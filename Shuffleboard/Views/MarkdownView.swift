import SwiftUI

// MARK: - MarkdownView

/// Renders a card description's Markdown: block structure from `Markdown.blocks`, inline styles (bold, italic,
/// code, links) from `AttributedString(markdown:)`. Checklist items are checkboxes that call `onToggleTask`.
struct MarkdownView: View {
    let text: String
    var onToggleTask: ((Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Markdown.blocks(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Self.inline(text)
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)

        case let .paragraph(text):
            Self.inline(text)
                .fixedSize(horizontal: false, vertical: true)

        case let .bullet(text, indent):
            listRow(marker: Text(verbatim: "•"), text: text, indent: indent)

        case let .numbered(number, text, indent):
            listRow(marker: Text(verbatim: "\(number)."), text: text, indent: indent)

        case let .task(done, text, indent, line):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Toggle(isOn: Binding(get: { done }, set: { _ in onToggleTask?(line) })) {
                    Self.inline(text)
                        .strikethrough(done)
                        .foregroundStyle(done ? .secondary : .primary)
                }
                .toggleStyle(.checkbox)
                .disabled(onToggleTask == nil)
            }
            .padding(.leading, CGFloat(indent) * 16)

        case let .quote(text):
            HStack(spacing: 8) {
                Rectangle()
                    .fill(.tertiary)
                    .frame(width: 3)
                Self.inline(text)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

        case let .code(text):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

        case .rule:
            Divider()
        }
    }

    private func listRow(marker: Text, text: String, indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            marker
                .foregroundStyle(.secondary)
            Self.inline(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(indent) * 16)
    }

    /// Inline Markdown (bold, italic, code, links), or the plain text if it doesn't parse.
    private static func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }
}
