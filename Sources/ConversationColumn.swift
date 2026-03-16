import SwiftUI

struct ConversationColumn: View {
    let messages: [MessageInfo]
    let selectedMatchID: Int64?
    let query: String
    let isRegex: Bool
    let loadAttachments: (Int64) -> [AttachmentInfo]

    var body: some View {
        if messages.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "message")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("Select a match to view conversation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(messages) { msg in
                            let isMatchedMsg = msg.id == selectedMatchID
                            MessageBubbleView(
                                message: msg,
                                query: isMatchedMsg ? query : "",
                                isRegex: isRegex,
                                isContext: false,
                                attachments: msg.hasAttachments ? loadAttachments(msg.id) : []
                            )
                            .id(msg.id)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                            .background(
                                isMatchedMsg
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: selectedMatchID) { _, newID in
                    if let newID {
                        withAnimation {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }
                .onAppear {
                    if let id = selectedMatchID {
                        // Small delay to let the ScrollView lay out
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
    }
}
