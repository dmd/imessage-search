import SwiftUI

struct ChatListColumn: View {
    let chatMatches: [ChatMatch]
    let selectedChat: ChatMatch?
    let onSelect: (ChatMatch) -> Void

    var body: some View {
        if chatMatches.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("No results")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
