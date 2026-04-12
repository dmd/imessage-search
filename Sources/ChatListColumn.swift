import SwiftUI

struct ChatListColumn: View {
    let chatMatches: [ChatMatch]
    let selectedChat: ChatMatch?
    let searchQuery: String
    let onSelect: (ChatMatch) -> Void

    var body: some View {
        if chatMatches.isEmpty {
            let hasQuery = !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text(hasQuery
                     ? "No results"
                     : "No query yet. Enter text to search for to get started.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(chatMatches, selection: Binding<ChatMatch.ID?>(
                get: { selectedChat?.id },
                set: { newID in
                    if let newID, let match = chatMatches.first(where: { $0.id == newID }) {
                        onSelect(match)
                    }
                }
            )) { chat in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chat.chatName)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        if chat.isGroup {
                            Text("Group")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    Text("\(chat.matchCount)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.8))
                        .clipShape(Capsule())
                }
                .padding(.vertical, 2)
                .tag(chat.id)
            }
            .listStyle(.sidebar)
        }
    }
}
