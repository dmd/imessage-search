import SwiftUI

struct ResultsView: View {
    @Bindable var state: AppState

    var body: some View {
        if state.isSearching && state.allResults.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Searching...")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = state.searchError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(.red)
                Text(error)
                    .foregroundStyle(.red)
            }
            .padding()
            .background(Color.red.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if state.allResults.isEmpty && state.results != nil {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("No messages found")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !state.allResults.isEmpty {
            let groups = groupByChat(state.allResults)

            ScrollView {
                LazyVStack(spacing: 12) {
                    // Results header
                    if let results = state.results {
                        HStack {
                            Text("\(results.total.formatted()) results")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.2fs", state.searchTime))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    ForEach(groups, id: \.chatName) { group in
                        ConversationGroupView(
                            chatName: group.chatName,
                            messages: group.messages,
                            query: state.searchQuery,
                            isRegex: state.useRegex,
                            loadContext: { state.loadContext(messageID: $0) },
                            loadAttachments: { state.loadAttachments(messageID: $0) }
                        )
                    }

                    // Load more
                    if state.hasMore {
                        Button("Load more results") {
                            state.loadMore()
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
    }

    struct ChatGroup {
        let chatName: String
        let messages: [MessageInfo]
    }

    func groupByChat(_ messages: [MessageInfo]) -> [ChatGroup] {
        var groups: [ChatGroup] = []
        var currentName: String? = nil
        var currentMsgs: [MessageInfo] = []
        for msg in messages {
            if currentName == nil || currentName != msg.chatName {
                if let name = currentName {
                    groups.append(ChatGroup(chatName: name, messages: currentMsgs))
                }
                currentName = msg.chatName
                currentMsgs = [msg]
            } else {
                currentMsgs.append(msg)
            }
        }
        if let name = currentName {
            groups.append(ChatGroup(chatName: name, messages: currentMsgs))
        }
        return groups
    }
}
