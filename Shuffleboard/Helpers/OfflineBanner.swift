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
            message
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
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

    private var message: Text {
        let readOnly = Text(" Editing is off until the connection is back.")
        guard let dataDate else {
            return Text(problem.title) + readOnly
        }
        return Text(problem.title) + Text(" Showing your boards as of ")
            + Text(dataDate, format: .relative(presentation: .named)) + Text(".") + readOnly
    }
}

#Preview {
    OfflineBanner(problem: .serverUnreachable, dataDate: Date().addingTimeInterval(-600)) {}
        .frame(width: 640)
}
