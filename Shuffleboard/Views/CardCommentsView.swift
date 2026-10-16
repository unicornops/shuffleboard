import SwiftUI

// MARK: - CardCommentsView

/// The Comments section of the card sheet: the card's comments, oldest first, and a box to add one.
/// Deck returns comments newest first in pages of `pageSize`; older pages load on demand.
struct CardCommentsView: View {
    let card: Card
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var window: BoardWindow

    /// Loaded comments, oldest first.
    @State private var comments: [CardComment] = []
    @State private var hasOlder = false
    @State private var isLoading = false
    @State private var draft = ""
    @State private var isPosting = false
    @State private var editingId: Int?
    @State private var editDraft = ""
    @State private var pendingDelete: CardComment?

    private static let pageSize = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hasOlder {
                Button("Show older comments") {
                    Task { await loadPage(offset: comments.count) }
                }
                .buttonStyle(.link)
                .disabled(isLoading)
            }
            if isLoading && comments.isEmpty {
                ProgressView()
                    .controlSize(.small)
            } else if comments.isEmpty, appState.isReadOnly {
                // Comments aren't kept on the Mac (#156).
                Text("Comments can't be shown until the server can be reached.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if comments.isEmpty {
                Text("No comments yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(comments) { comment in
                commentRow(comment)
            }
            if !appState.isReadOnly {
                composer
            }
        }
        // Loaded again when the server can be reached again.
        .task(id: "\(card.id) \(appState.isReadOnly)") {
            guard !appState.isReadOnly else { return }
            comments = []
            await loadPage(offset: 0)
        }
        .confirmationDialog(
            "Delete comment?",
            isPresented: Binding(get: { pendingDelete != nil }, set: {
                if !$0 {
                    pendingDelete = nil
                }
            })
        ) {
            Button("Delete", role: .destructive) {
                guard let comment = pendingDelete else { return }
                pendingDelete = nil
                Task { await delete(comment) }
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("The comment will be permanently deleted.")
        }
    }

    // MARK: - Rows

    private func commentRow(_ comment: CardComment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            AvatarBadge(user: comment.author)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.author.displayName)
                        .font(.subheadline.weight(.semibold))
                    if let date = comment.createdAt {
                        Text(date, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(date.formatted(date: .abbreviated, time: .shortened))
                    }
                    Spacer()
                    if isOwn(comment), editingId != comment.id, !appState.isReadOnly {
                        ownCommentMenu(comment)
                    }
                }
                if editingId == comment.id {
                    editor(for: comment)
                } else {
                    Text(Self.message(comment))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func ownCommentMenu(_ comment: CardComment) -> some View {
        Menu {
            Button("Edit") {
                editDraft = comment.message
                editingId = comment.id
            }
            Button("Delete", role: .destructive) {
                pendingDelete = comment
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Comment actions")
    }

    private func editor(for comment: CardComment) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            MentionField(placeholder: "Comment", text: $editDraft, people: mentionable)
            HStack {
                characterCount(editDraft)
                Spacer()
                Button("Cancel") {
                    editingId = nil
                }
                Button("Save") {
                    Task { await saveEdit(of: comment) }
                }
                .disabled(!CardComment.isPostable(editDraft))
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .trailing, spacing: 6) {
            MentionField(placeholder: "Add a comment…", text: $draft, people: mentionable, identifier: "new comment")
            HStack {
                characterCount(draft)
                Spacer()
                Button {
                    Task { await post() }
                } label: {
                    if isPosting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Comment")
                    }
                }
                .disabled(isPosting || !CardComment.isPostable(draft))
            }
        }
    }

    @ViewBuilder
    private func characterCount(_ text: String) -> some View {
        if text.count > CardComment.maximumLength - 100 {
            Text("\(text.count)/\(CardComment.maximumLength)")
                .font(.caption)
                .foregroundStyle(text.count > CardComment.maximumLength ? .red : .secondary)
        }
    }

    // MARK: - Mentions

    /// The people a comment can mention (#163): the board's members, other than the user.
    private var mentionable: [DeckUser] {
        (window.selectedBoard?.assignableUsers ?? []).filter { $0.uid != appState.currentUserId }
    }

    /// The comment's message with mentions shown by name, in bold and the accent colour.
    private static func message(_ comment: CardComment) -> AttributedString {
        comment.segments.reduce(into: AttributedString()) { result, segment in
            switch segment {
            case let .text(text):
                result += AttributedString(text)

            case let .mention(mention):
                var name = AttributedString("@\(mention.mentionDisplayName)")
                name.inlinePresentationIntent = .stronglyEmphasized
                name.foregroundColor = .accentColor
                result += name
            }
        }
    }

    // MARK: - Actions

    private func isOwn(_ comment: CardComment) -> Bool {
        comment.actorId == appState.currentUserId
    }

    private func loadPage(offset: Int) async {
        isLoading = true
        defer { isLoading = false }
        guard let page = await appState.comments(for: card, offset: offset) else { return }
        // Pages arrive newest first; older comments go above the ones already shown.
        comments = page.reversed() + comments
        hasOlder = page.count == Self.pageSize
    }

    private func post() async {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        isPosting = true
        defer { isPosting = false }
        if let comment = await appState.addComment(message, to: card) {
            comments.append(comment)
            draft = ""
        }
    }

    private func saveEdit(of comment: CardComment) async {
        let message = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let updated = await appState.updateComment(comment, message: message, on: card) else { return }
        if let index = comments.firstIndex(where: { $0.id == comment.id }) {
            comments[index] = updated
        }
        editingId = nil
    }

    private func delete(_ comment: CardComment) async {
        if await appState.deleteComment(comment, from: card) {
            comments.removeAll { $0.id == comment.id }
        }
    }
}

// MARK: - MentionField

/// A comment field that, after an "@", suggests people to mention (#163): click one, or pick it with the arrow keys
/// and Return or Tab, to write their mention.
private struct MentionField: View {
    let placeholder: String
    @Binding var text: String
    let people: [DeckUser]
    /// The text field's accessibility identifier; the placeholder if nil.
    var identifier: String?
    @State private var highlighted = 0

    private var suggestions: [DeckUser] {
        guard let query = Mentions.query(in: text) else { return [] }
        return Mentions.suggestions(for: query, from: people)
    }

    var body: some View {
        let suggestions = suggestions
        VStack(alignment: .leading, spacing: 4) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1 ... 6)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(identifier ?? placeholder)
                .onKeyPress(.downArrow) { move(1, in: suggestions) }
                .onKeyPress(.upArrow) { move(-1, in: suggestions) }
                .onKeyPress(.return) { pick(from: suggestions) }
                .onKeyPress(.tab) { pick(from: suggestions) }
                .onChange(of: text) { highlighted = 0 }
            if !suggestions.isEmpty {
                suggestionList(suggestions)
            }
        }
    }

    private func suggestionList(_ suggestions: [DeckUser]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.uid) { index, user in
                Button {
                    text = Mentions.completing(text, with: user)
                } label: {
                    HStack(spacing: 6) {
                        AvatarBadge(user: user, size: 18)
                        Text(user.displayName)
                        if user.displayName != user.uid {
                            Text(user.uid)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        index == highlighted ? Color.accentColor.opacity(0.2) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mention \(user.uid)")
            }
        }
        .padding(4)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("People to mention")
    }

    private func move(_ step: Int, in suggestions: [DeckUser]) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        highlighted = min(max(highlighted + step, 0), suggestions.count - 1)
        return .handled
    }

    private func pick(from suggestions: [DeckUser]) -> KeyPress.Result {
        guard suggestions.indices.contains(highlighted) else { return .ignored }
        text = Mentions.completing(text, with: suggestions[highlighted])
        return .handled
    }
}
