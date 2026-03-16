import SwiftUI

struct ContextView: View {
    let messages: [MessageInfo]
    let query: String
    let isRegex: Bool
    let loadAttachments: (Int64) -> [AttachmentInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Conversation context")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            ForEach(messages) { msg in
                MessageBubbleView(
                    message: msg,
                    query: msg.isMatch ? query : "",
                    isRegex: isRegex,
                    isContext: !msg.isMatch,
                    attachments: msg.hasAttachments ? loadAttachments(msg.id) : []
                )
            }
        }
        .padding(12)
    }
}
