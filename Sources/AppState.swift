import Foundation
import SwiftUI

enum DateFilter: String, CaseIterable {
    case all = "All"
    case today = "Today"
    case last7 = "Last 7 Days"
    case last30 = "Last 30 Days"
    case lastYear = "Last Year"

    /// Returns the YYYY-MM-DD string for the start of this filter range, or "" for all
    func dateFromString() -> String {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        switch self {
        case .all:
            return ""
        case .today:
            return fmt.string(from: Date())
        case .last7:
            return fmt.string(from: cal.date(byAdding: .day, value: -7, to: Date())!)
        case .last30:
            return fmt.string(from: cal.date(byAdding: .day, value: -30, to: Date())!)
        case .lastYear:
            return fmt.string(from: cal.date(byAdding: .year, value: -1, to: Date())!)
        }
    }
}

@Observable
final class AppState {
    // Load state
    var loadState: AppLoadState = .loading(status: "Starting up...")

    // Search parameters
    var searchQuery = ""
    var useRegex = false
    var dateFilter: DateFilter = .all

    // Three-column state
    var chatMatches: [ChatMatch] = []
    var selectedChat: ChatMatch?
    var matchesInChat: [MessageMatch] = []
    var selectedMatch: MessageMatch?
    var conversationMessages: [MessageInfo] = []

    // Search metadata
    var totalMatchCount: Int = 0
    var searchTime: Double = 0
    var isSearching = false
    var searchError: String?

    // Data
    var store: MessageStore?
    var engine: SearchEngine?

    // Stats
    var statsLine = ""

    func load() {
        Task.detached { [self] in
            await MainActor.run { self.loadState = .loading(status: "Loading contacts...") }

            let contacts = ContactResolver()

            await MainActor.run { self.loadState = .loading(status: "Indexing messages...") }

            let dbPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Messages/chat.db").path

            let canRead = FileManager.default.isReadableFile(atPath: dbPath)
            if !canRead {
                await MainActor.run { self.loadState = .permissionDenied }
                return
            }

            do {
                let store = try MessageStore(chatDBPath: dbPath, contacts: contacts)

                await MainActor.run {
                    self.store = store
                    self.engine = SearchEngine(store: store)
                    self.statsLine = "\(store.messageCount.formatted()) messages | \(store.totalContacts.formatted()) contacts | \(store.dateFrom ?? "?") to \(store.dateTo ?? "?")"
                    self.loadState = .ready
                }
            } catch {
                await MainActor.run {
                    let msg = error.localizedDescription
                    if msg.contains("unable to open") || msg.contains("not authorized") {
                        self.loadState = .permissionDenied
                    } else {
                        self.loadState = .error(msg)
                    }
                }
            }
        }
    }

    /// Run search: populates chatMatches (left column), clears middle/right
    func performSearch() {
        guard let engine = engine else { return }
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            chatMatches = []
            selectedChat = nil
            matchesInChat = []
            selectedMatch = nil
            conversationMessages = []
            totalMatchCount = 0
            return
        }

        isSearching = true
        searchError = nil
        selectedChat = nil
        matchesInChat = []
        selectedMatch = nil
        conversationMessages = []
        let start = Date()

        let dateFrom = dateFilter.dateFromString()
        let regex = useRegex

        Task.detached {
            // Fetch ALL results (no pagination) to group by chat
            let allMessages = engine.searchAll(
                query: query,
                dateFrom: dateFrom,
                useRegex: regex
            )
            let elapsed = Date().timeIntervalSince(start)

            // Group by chat name
            var chatGroups: [String: (messages: [MessageInfo], chatIDs: Set<Int64>, isGroup: Bool)] = [:]
            for msg in allMessages {
                let key = msg.chatName
                if chatGroups[key] == nil {
                    chatGroups[key] = (messages: [msg], chatIDs: [msg.chatID], isGroup: msg.isGroup)
                } else {
                    chatGroups[key]!.messages.append(msg)
                    chatGroups[key]!.chatIDs.insert(msg.chatID)
                }
            }

            let matches = chatGroups.map { (name, info) in
                ChatMatch(
                    id: name,
                    chatName: name,
                    chatIDs: Array(info.chatIDs),
                    isGroup: info.isGroup,
                    matchCount: info.messages.count
                )
            }.sorted { $0.matchCount > $1.matchCount }

            await MainActor.run { [self] in
                self.chatMatches = matches
                self.totalMatchCount = allMessages.count
                self.searchTime = elapsed
                self.isSearching = false
            }
        }
    }

    /// When a chat is selected: populate matchesInChat (middle column)
    func selectChat(_ chat: ChatMatch) {
        guard let engine = engine else { return }
        selectedChat = chat
        selectedMatch = nil
        conversationMessages = []

        let query = searchQuery
        let dateFrom = dateFilter.dateFromString()
        let regex = useRegex
        let chatIDs = chat.chatIDs

        Task.detached {
            let messages = engine.searchAll(
                query: query,
                dateFrom: dateFrom,
                useRegex: regex,
                chatIDs: chatIDs
            )

            let matches = messages.map { msg in
                let snippet = String(msg.text.prefix(80))
                return MessageMatch(
                    id: msg.id,
                    date: msg.date,
                    snippet: snippet,
                    isFromMe: msg.isFromMe,
                    sender: msg.sender
                )
            }

            await MainActor.run { [self] in
                self.matchesInChat = matches
            }
        }
    }

    /// When a match is selected: load conversation context (right column)
    func selectMatch(_ match: MessageMatch) {
        selectedMatch = match
        let messages = engine?.context(messageID: match.id, count: 100) ?? []
        conversationMessages = messages
    }

    func loadAttachments(messageID: Int64) -> [AttachmentInfo] {
        engine?.attachments(messageID: messageID) ?? []
    }
}
