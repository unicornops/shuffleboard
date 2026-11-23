import SwiftUI

// MARK: - BoardSharingSheet

/// Who a board is shared with and their rights, with search to add people, groups, federated users and Teams.
/// What can be changed follows Deck's rules: adding and changing shares needs share rights, removing them needs
/// manage rights, and without manage rights you can only pass on rights you hold yourself.
struct BoardSharingSheet: View {
    let boardId: Int
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [Sharee] = []
    @State private var isSearching = false
    @State private var pendingRemoval: ACLEntry?

    /// The live board, so the list reflects changes as soon as they're saved.
    private var board: Board? {
        appState.boards.first { $0.id == boardId }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sharing")
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
            if let board {
                content(board)
            }
        }
        .frame(width: 520, height: 560)
        .actionErrorBanner(appState)
        .confirmationDialog(
            "Stop sharing?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: {
                if !$0 {
                    pendingRemoval = nil
                }
            })
        ) {
            Button("Stop Sharing", role: .destructive) {
                if let entry = pendingRemoval, let board {
                    Task { await appState.removeShare(entry, from: board) }
                }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRemoval = nil
            }
        } message: {
            if let name = pendingRemoval?.participant?.displayName {
                Text("\(name) will lose access to this board.")
            } else {
                Text("They will lose access to this board.")
            }
        }
    }

    private func content(_ board: Board) -> some View {
        List {
            if board.canShare {
                Section("Share with") {
                    TextField("Search people, groups and teams", text: $query)
                        .textFieldStyle(.roundedBorder)
                    searchResults(board)
                }
            } else {
                Section {
                    Label(
                        "You can see who has access. Only people with share rights can change it.",
                        systemImage: "lock"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            Section("People with access") {
                if let owner = board.owner {
                    HStack {
                        AvatarBadge(user: owner)
                        Text(owner.displayName)
                        Spacer()
                        Text("Owner")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(board.acl, id: \.self) { entry in
                    shareRow(entry, on: board)
                }
            }
        }
        .task(id: query) {
            await search(board)
        }
    }

    // MARK: - Search

    @ViewBuilder
    private func searchResults(_ board: Board) -> some View {
        let available = results.filter { $0.shareType != nil && !board.isShared(with: $0) }
        if isSearching {
            ProgressView()
                .controlSize(.small)
        } else if !query.trimmingCharacters(in: .whitespaces).isEmpty, available.isEmpty {
            Text("No matches")
                .foregroundStyle(.secondary)
        }
        ForEach(available) { sharee in
            Button {
                Task {
                    if await appState.share(board, with: sharee) {
                        query = ""
                    }
                }
            } label: {
                HStack {
                    Image(systemName: sharee.shareType?.symbol ?? "person")
                        .frame(width: 22)
                    VStack(alignment: .leading) {
                        Text(sharee.label)
                        if let detail = sharee.detail, detail != sharee.label {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(sharee.shareType?.title ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "plus.circle")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share with \(sharee.label)")
        }
    }

    private func search(_ board: Board) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard board.canShare, !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }
        // Wait for typing to pause; a newer keystroke cancels this task.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        isSearching = true
        let found = await appState.searchSharees(trimmed)
        guard !Task.isCancelled else { return }
        results = found
        isSearching = false
    }

    // MARK: - Shares

    private func shareRow(_ entry: ACLEntry, on board: Board) -> some View {
        let type = ShareType(rawValue: entry.type)
        let isMe = type == .user && entry.participant?.uid == appState.currentUserId
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                if type == .user, let participant = entry.participant {
                    AvatarBadge(user: participant)
                } else {
                    Image(systemName: type?.symbol ?? "person")
                        .frame(width: 22)
                }
                Text(entry.participant?.displayName ?? String(localized: "Unknown", comment: "A share with no name"))
                if let type, type != .user {
                    Text(type.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isMe {
                    Text("You")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    pendingRemoval = entry
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .disabled(!board.canManage || isMe)
                .help(removeHelp(board: board, isMe: isMe))
                .accessibilityLabel(stopSharingLabel(entry))
            }
            HStack(spacing: 16) {
                ForEach(SharePermissions.Right.allCases, id: \.self) { right in
                    Toggle(right.title, isOn: permissionBinding(right, for: entry, on: board))
                        .toggleStyle(.checkbox)
                        .disabled(!board.canGrant(right))
                }
            }
            .padding(.leading, 30)
            .font(.callout)
        }
        .padding(.vertical, 2)
    }

    private func permissionBinding(
        _ right: SharePermissions.Right,
        for entry: ACLEntry,
        on board: Board
    )
        -> Binding<Bool> {
        Binding(
            get: { SharePermissions(entry)[right] },
            set: { isOn in
                var permissions = SharePermissions(entry)
                permissions[right] = isOn
                Task { await appState.updateShare(entry, on: board, permissions: permissions) }
            }
        )
    }

    private func removeHelp(board: Board, isMe: Bool) -> String {
        if isMe {
            return String(localized: "You can't remove your own access here")
        }
        return board.canManage
            ? String(localized: "Stop sharing")
            : String(localized: "Only people with manage rights can remove shares")
    }

    private func stopSharingLabel(_ entry: ACLEntry) -> String {
        guard let name = entry.participant?.displayName else { return String(localized: "Stop sharing") }
        return String(localized: "Stop sharing with \(name)")
    }
}
