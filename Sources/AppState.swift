import Foundation
import SwiftUI

@Observable
final class AppState {
    // Load state
    var loadState: AppLoadState = .loading(status: "Starting up...")

    // Search parameters
    var searchQuery = ""
    var selectedContact = ""
    var dateFrom = ""
    var dateTo = ""
    var direction = "all"
    var selectedChatIDString = ""
    var useRegex = false
    var showUnknownContacts = false
    var showUnknownChats = false

    // Results
    var results: SearchResults?
    var allResults: [MessageInfo] = []
    var searchTime: Double = 0
    var isSearching = false
    var searchError: String?

    // Data
    var store: MessageStore?
    var engine: SearchEngine?

    // Derived lists for dropdowns
    var contactEntries: [ContactEntry] = []
    var chatEntries: [ChatEntry] = []

    // Stats
    var statsLine = ""

    func load() {
        Task.detached { [self] in
            await MainActor.run { self.loadState = .loading(status: "Loading contacts...") }

            let contacts = ContactResolver()

            await MainActor.run { self.loadState = .loading(status: "Indexing messages...") }

            let dbPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Messages/chat.db").path

            // Check if we can actually read chat.db (tests Full Disk Access)
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
                    self.buildDropdowns()
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

    func performSearch(page: Int = 1) {
        guard let engine = engine else { return }
        isSearching = true
        searchError = nil
        let start = Date()

        // Capture all parameters before spawning background task
        let query = searchQuery
        let contact = selectedContact
        let from = dateFrom
        let to = dateTo
        let dir = direction
        let regex = useRegex
        let chatIDs: [Int64] = selectedChatIDString.isEmpty ? [] :
            selectedChatIDString.split(separator: ",").compactMap { Int64($0) }

        Task.detached {
            let results = engine.search(
                query: query,
                contactFilter: contact,
                dateFrom: from,
                dateTo: to,
                direction: dir,
                chatIDs: chatIDs,
                useRegex: regex,
                page: page
            )
            let elapsed = Date().timeIntervalSince(start)

            await MainActor.run { [self] in
                if page == 1 {
                    self.allResults = results.results
                } else {
                    self.allResults.append(contentsOf: results.results)
                }
                self.results = results
                self.searchTime = elapsed
                self.isSearching = false
            }
        }
    }

    func loadMore() {
        guard let results = results else { return }
        let nextPage = results.page + 1
        performSearch(page: nextPage)
    }

    var hasMore: Bool {
        guard let results = results else { return false }
        return results.page * results.perPage < results.total
    }

    func loadContext(messageID: Int64) -> [MessageInfo] {
        engine?.context(messageID: messageID) ?? []
    }

    func loadAttachments(messageID: Int64) -> [AttachmentInfo] {
        engine?.attachments(messageID: messageID) ?? []
    }

    private func buildDropdowns() {
        guard let store = store else { return }

        // Contact entries
        var seenContacts: [String: (name: String, ids: Set<String>)] = [:]
        for (_, hinfo) in store.handles {
            let key = hinfo.name.lowercased()
            if seenContacts[key] == nil {
                seenContacts[key] = (name: hinfo.name, ids: [hinfo.id])
            } else {
                seenContacts[key]!.ids.insert(hinfo.id)
            }
        }
        contactEntries = seenContacts.values.map { entry in
            let isResolved = !entry.ids.contains(entry.name)
            return ContactEntry(
                id: entry.name,
                name: entry.name,
                rawID: entry.ids.sorted().first ?? "",
                isResolved: isResolved
            )
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }

        // Chat entries (deduplicated by name, merged IDs)
        var seenChats: [String: (name: String, isGroup: Bool, msgCount: Int, chatIDs: [Int64], hasDisplayName: Bool)] = [:]
        for (cid, cinfo) in store.chats {
            let key = cinfo.name.lowercased()
            let count = (try? Int(store.db.queryScalar(
                "SELECT COUNT(*) FROM chatdb.chat_message_join WHERE chat_id = ?",
                params: [cid]
            ))) ?? 0

            if seenChats[key] == nil {
                seenChats[key] = (name: cinfo.name, isGroup: cinfo.isGroup, msgCount: count,
                                  chatIDs: [cid], hasDisplayName: cinfo.hasDisplayName)
            } else {
                seenChats[key]!.chatIDs.append(cid)
                seenChats[key]!.msgCount += count
                seenChats[key]!.hasDisplayName = seenChats[key]!.hasDisplayName || cinfo.hasDisplayName
            }
        }
        chatEntries = seenChats.values.compactMap { entry in
            if entry.msgCount == 0 { return nil }
            let isResolved = entry.hasDisplayName ||
                store.contacts.resolvedNames.contains(where: { entry.name.contains($0) })
            return ChatEntry(
                id: entry.chatIDs.map(String.init).joined(separator: ","),
                name: entry.name,
                isGroup: entry.isGroup,
                messageCount: entry.msgCount,
                isResolved: isResolved
            )
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}
