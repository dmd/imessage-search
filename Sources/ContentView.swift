import SwiftUI

struct ContentView: View {
    @State var state = AppState()
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        Group {
            switch state.loadState {
            case .loading(let status):
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text(status)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .permissionDenied:
                PermissionsView()

            case .error(let msg):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.red)
                    Text("Failed to load")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(msg)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .ready:
                VStack(spacing: 0) {
                    // Top bar: search field + date filters + regex toggle
                    searchBar

                    Divider()

                    // Three-column layout
                    HSplitView {
                        // Left: chats with match counts
                        ChatListColumn(
                            chatMatches: state.chatMatches,
                            selectedChat: state.selectedChat,
                            onSelect: { chat in
                                state.selectChat(chat)
                            }
                        )
                        .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)

                        // Middle: individual matches in selected chat
                        MatchListColumn(
                            matches: state.matchesInChat,
                            selectedMatch: state.selectedMatch,
                            chatName: state.selectedChat?.chatName ?? "",
                            onSelect: { match in
                                state.selectMatch(match)
                            }
                        )
                        .frame(minWidth: 200, idealWidth: 280, maxWidth: 400)

                        // Right: full conversation scrolled to match
                        ConversationColumn(
                            messages: state.conversationMessages,
                            selectedMatchID: state.selectedMatch?.id,
                            query: state.searchQuery,
                            isRegex: state.useRegex,
                            loadAttachments: { state.loadAttachments(messageID: $0) }
                        )
                        .frame(minWidth: 300, idealWidth: 450)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .onAppear { state.load() }
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.modifierFlags.contains(.command) && event.characters == "f" {
                    isSearchFocused = true
                    return nil
                }
                return event
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 12))
                TextField("Search messages...", text: $state.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isSearchFocused)
                    .onSubmit { state.performSearch() }
                if !state.searchQuery.isEmpty {
                    Button(action: {
                        state.searchQuery = ""
                        state.chatMatches = []
                        state.selectedChat = nil
                        state.matchesInChat = []
                        state.selectedMatch = nil
                        state.conversationMessages = []
                        state.totalMatchCount = 0
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(minWidth: 200, maxWidth: 350)

            // Date filter buttons
            ForEach(DateFilter.allCases, id: \.self) { filter in
                Button(action: {
                    state.dateFilter = filter
                    if !state.searchQuery.isEmpty {
                        state.performSearch()
                    }
                }) {
                    Text(filter.rawValue)
                        .font(.system(size: 11, weight: state.dateFilter == filter ? .semibold : .regular))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(state.dateFilter == filter ? Color.accentColor.opacity(0.15) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .foregroundStyle(state.dateFilter == filter ? Color.accentColor : .secondary)
            }

            Divider().frame(height: 14)

            // Regex toggle
            Toggle("Regex", isOn: $state.useRegex)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .controlSize(.small)

            Spacer(minLength: 0)

            // Status
            if state.isSearching {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
                Text("Searching...")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if state.totalMatchCount > 0 {
                Text("\(state.totalMatchCount) matches in \(state.chatMatches.count) chats")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(String(format: "(%.2fs)", state.searchTime))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                Text(state.statsLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
