import SwiftUI

// MARK: - OfflineBanner

/// Shown above the board while the server can't be reached (#156): what's wrong, how old the boards on screen are,
/// that editing is off, and a button to try again (the app also keeps trying by itself).
struct OfflineBanner: View {
    let problem: ConnectionProblem
    /// When what's shown last came from the server; nil if it never has.
    let dataDate: Date?
    var tryAgain: () async -> Void
    @State private var isTrying = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: problem == .offline ? "wifi.slash" : "exclamationmark.icloud")
                .foregroundStyle(.orange)
            // At most two lines, and never fixed to its full height: the window works out its smallest height by
            // laying the board out at its narrowest, where the whole message wraps a word a line, so a fixed height
            // made the window very tall when the banner appeared.
            message
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(message)
            Button {
                Task {
                    isTrying = true
                    await tryAgain()
                    isTrying = false
                }
            } label: {
                if isTrying {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Try Again")
                }
            }
            .disabled(isTrying)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("offline banner")
    }

    /// Whole sentences, so each language can order them its own way.
    private var message: Text {
        guard let dataDate else {
            switch problem {
            case .offline:
                return Text("You're offline. Editing is off until the connection is back.")

            case .serverUnreachable:
                return Text("Can't reach the server. Editing is off until the connection is back.")
            }
        }
        let age = Text(dataDate, format: .relative(presentation: .named))
        switch problem {
        case .offline:
            return Text(
                "You're offline. Showing your boards as of \(age). Editing is off until the connection is back.",
                comment: "The age is relative, e.g. \"5 minutes ago\"."
            )

        case .serverUnreachable:
            return Text(
                "Can't reach the server. Showing your boards as of \(age). Editing is off until the connection is back.",
                comment: "The age is relative, e.g. \"5 minutes ago\"."
            )
        }
    }
}

#Preview {
    OfflineBanner(problem: .serverUnreachable, dataDate: Date().addingTimeInterval(-600)) {}
        .frame(width: 640)
}
