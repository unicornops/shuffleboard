import SwiftUI

/// The sidebar's search field, which searches every board's cards (#158). Edit > Search All Boards (⇧⌘F) puts the
/// cursor in it; the up and down arrows move through the results, Return opens one and Escape clears the search.
struct CardSearchField: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var window: BoardWindow
    @Binding var highlighted: CardSearchResult.ID?
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search All Boards", text: $window.cardSearchText)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .accessibilityIdentifier("Search all boards")
                .onSubmit(openHighlighted)
                .onExitCommand { window.cardSearchText = "" }
                .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                .onKeyPress(.upArrow) { moveHighlight(by: -1) }
            if !window.cardSearchText.isEmpty {
                Button {
                    window.cardSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .onChange(of: window.cardSearchFocusRequest) {
            isFocused = true
        }
        .onChange(of: window.cardSearchText) { old, new in
            highlighted = nil
            // Fetch the boards' cards when a search starts; later keystrokes search what was fetched.
            if old.trimmingCharacters(in: .whitespaces).isEmpty, !new.trimmingCharacters(in: .whitespaces).isEmpty {
                Task { await appState.loadCardsForSearch() }
            }
        }
    }

    private var results: [CardSearchResult] {
        window.cardSearchResults.flatMap(\.results)
    }

    private func moveHighlight(by step: Int) -> KeyPress.Result {
        let results = results
        guard !results.isEmpty else { return .ignored }
        let current = results.firstIndex { $0.id == highlighted } ?? (step > 0 ? -1 : results.count)
        highlighted = results[min(max(current + step, 0), results.count - 1)].id
        return .handled
    }

    /// Opens the highlighted result, or the first one.
    private func openHighlighted() {
        let results = results
        guard let result = results.first(where: { $0.id == highlighted }) ?? results.first else { return }
        highlighted = result.id
        window.open(result)
    }
}

/// The cards matching the sidebar's search, grouped by board, shown in the sidebar's list in place of the boards
/// (the same list, so typing in the search field keeps its focus). Clicking one opens it.
struct CardSearchResults: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var window: BoardWindow
    let highlighted: CardSearchResult.ID?

    var body: some View {
        let groups = window.cardSearchResults
        if groups.isEmpty {
            if appState.isLoadingAllCards {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching\u{2026}")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No cards found")
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(groups) { group in
            Section(group.board.title) {
                ForEach(group.results) { result in
                    Button {
                        window.open(result)
                    } label: {
                        CardSearchRow(result: result)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        result.id == highlighted ? Color.accentColor.opacity(0.2) : Color.clear
                    )
                    .accessibilityIdentifier("search result: \(result.card.title)")
                }
            }
        }
    }
}

private struct CardSearchRow: View {
    let result: CardSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if result.card.isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Text(result.card.title)
                    .lineLimit(2)
            }
            HStack(spacing: 4) {
                Text(result.listTitle)
                if result.card.archived {
                    Text("Archived")
                        .padding(.horizontal, 4)
                        .background(.quaternary, in: Capsule())
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
