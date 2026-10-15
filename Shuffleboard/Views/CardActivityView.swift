import SwiftUI

// MARK: - CardActivityView

/// The Activity section of the card sheet (#164): the card's history, newest first, as the web UI shows it (created,
/// renamed, moved, due date changed… and by whom). Older events load on demand. The card sheet leaves the section
/// out when the server has no Activity app.
struct CardActivityView: View {
    let card: Card
    @EnvironmentObject private var appState: AppState

    /// Loaded events, newest first.
    @State private var events: [CardActivity] = []
    @State private var hasOlder = false
    @State private var isLoading = false

    private static let pageSize = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isLoading && events.isEmpty {
                ProgressView()
                    .controlSize(.small)
            } else if events.isEmpty, appState.isReadOnly {
                // The history isn't kept on the Mac (#156).
                Text("The card's activity can't be shown until the server can be reached.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if events.isEmpty {
                Text("No activity yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(events) { event in
                eventRow(event)
            }
            if hasOlder {
                Button("Show older activity") {
                    Task { await loadPage(since: events.last?.id) }
                }
                .buttonStyle(.link)
                .disabled(isLoading)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card activity")
        // Loaded again when the server can be reached again.
        .task(id: "\(card.id) \(appState.isReadOnly)") {
            guard !appState.isReadOnly else { return }
            events = []
            await loadPage(since: nil)
        }
    }

    private func eventRow(_ event: CardActivity) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let author = event.author {
                AvatarBadge(user: author, size: 20)
            } else {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.subject(event))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let date = event.createdAt {
                    Text(date, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(date.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The event's text with names (people, lists, labels, dates…) in bold.
    private static func subject(_ event: CardActivity) -> AttributedString {
        event.segments.reduce(into: AttributedString()) { result, segment in
            switch segment {
            case let .text(text):
                result += AttributedString(text)

            case let .name(name):
                var bold = AttributedString(name)
                bold.inlinePresentationIntent = .stronglyEmphasized
                result += bold
            }
        }
    }

    private func loadPage(since: Int?) async {
        isLoading = true
        defer { isLoading = false }
        guard case let .events(page) = await appState.activity(for: card, since: since, limit: Self.pageSize) else {
            return
        }
        events += page.filter { event in !events.contains { $0.id == event.id } }
        hasOlder = page.count == Self.pageSize
    }
}
