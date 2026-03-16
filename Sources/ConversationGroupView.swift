import SwiftUI

struct ConversationGroupView: View {
    let chatName: String
    let messages: [MessageInfo]
    let query: String
    let isRegex: Bool
    let loadContext: (Int64) -> [MessageInfo]
    let loadAttachments: (Int64) -> [AttachmentInfo]

    @State private var expandedContexts: [Int64: [MessageInfo]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Chat header
            HStack {
                Text(chatName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.05))

            Divider()

            // Messages
            VStack(spacing: 0) {
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, msg in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: 1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    VStack(spacing: 2) {
                        HStack(alignment: .center, spacing: 0) {
                            // Disclosure triangle in the margin
                            let isExpanded = expandedContexts[msg.id] != nil
                            Button(action: {
                                if isExpanded {
                                    expandedContexts.removeValue(forKey: msg.id)
                                } else {
                                    expandedContexts[msg.id] = loadContext(msg.id)
                                }
                            }) {
                                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(isExpanded ? "Hide context" : "Show context")

                            MessageBubbleView(
                                message: msg,
                                query: query,
                                isRegex: isRegex,
                                isContext: false,
                                attachments: msg.hasAttachments ? loadAttachments(msg.id) : []
                            )
                        }

                        // Context expansion
                        if let ctxMessages = expandedContexts[msg.id], ctxMessages.count > 1 {
                            Divider().padding(.horizontal, 16)
                            ContextView(
                                messages: ctxMessages,
                                query: query,
                                isRegex: isRegex,
                                loadAttachments: loadAttachments
                            )
                        }
                    }
                }
            }
            .padding(12)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }
}
