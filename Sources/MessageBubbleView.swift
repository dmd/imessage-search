import SwiftUI

struct MessageBubbleView: View {
    let message: MessageInfo
    let query: String
    let isRegex: Bool
    let isContext: Bool
    let attachments: [AttachmentInfo]

    var body: some View {
        let isSent = message.isFromMe
        VStack(alignment: isSent ? .trailing : .leading, spacing: 1) {
            // Sender name for received messages in group chats
            if !isSent && message.isGroup {
                Text(message.sender)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }

            // Bubble
            VStack(alignment: .leading, spacing: 4) {
                if isContext {
                    let plain = { () -> AttributedString in
                        var a = AttributedString(message.text)
                        TextHighlighting.linkify(&a)
                        return a
                    }()
                    Text(plain)
                        .foregroundStyle(isSent ? .white : .primary)
                } else {
                    let highlighted = { () -> AttributedString in
                        var a = TextHighlighting.highlight(
                            text: message.text,
                            query: query,
                            isRegex: isRegex,
                            isSent: isSent
                        )
                        TextHighlighting.linkify(&a)
                        return a
                    }()
                    Text(highlighted)
                        .foregroundStyle(isSent ? .white : .primary)
                }

                // Inline attachments
                ForEach(attachments) { att in
                    AttachmentView(attachment: att)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSent ? Color.blue : Color(.systemGray).opacity(0.2))
            .clipShape(BubbleShape(isSent: isSent))

            // Timestamp
            if let date = message.date {
                Text(date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: isSent ? .trailing : .leading)
        .padding(.horizontal, 4)
        .opacity(isContext && !message.isMatch ? 0.5 : 1.0)
    }
}

struct BubbleShape: Shape {
    let isSent: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 18
        let smallRadius: CGFloat = 6
        if isSent {
            return Path(roundedRect: rect, cornerRadii: .init(
                topLeading: radius,
                bottomLeading: radius,
                bottomTrailing: smallRadius,
                topTrailing: radius
            ))
        } else {
            return Path(roundedRect: rect, cornerRadii: .init(
                topLeading: radius,
                bottomLeading: smallRadius,
                bottomTrailing: radius,
                topTrailing: radius
            ))
        }
    }
}
