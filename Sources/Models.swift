import Foundation

struct MessageInfo: Identifiable, Hashable {
    let id: Int64          // message ROWID
    let text: String
    let isFromMe: Bool
    let date: String?      // formatted "YYYY-MM-DD HH:MM"
    let dateRaw: Int64     // raw Apple nanosecond timestamp for sorting
    let sender: String
    let handleID: String   // raw handle identifier
    let chatID: Int64
    let chatName: String
    let isGroup: Bool
    let hasAttachments: Bool
    var isMatch: Bool = false  // used in context view
}

struct HandleInfo {
    let id: String         // raw handle string (phone/email)
    let name: String       // resolved display name
}

struct ChatInfo {
    let id: Int64
    let name: String
    let isGroup: Bool
    let identifier: String
    let hasDisplayName: Bool
}

struct ContactEntry: Identifiable {
    let id: String         // for Identifiable
    let name: String
    let rawID: String      // raw handle identifier
    let isResolved: Bool
}

struct ChatEntry: Identifiable {
    let id: String         // comma-separated chat IDs
    let name: String
    let isGroup: Bool
    let messageCount: Int
    let isResolved: Bool
}

struct AttachmentInfo: Identifiable {
    let id: Int64
    let filename: String
    let mimeType: String?
    let totalBytes: Int64
    let exists: Bool
    let fullPath: String
}

struct SearchResults {
    let results: [MessageInfo]
    let total: Int
    let page: Int
    let perPage: Int
}

/// A chat that has matching messages, with the count of matches
struct ChatMatch: Identifiable, Hashable {
    let id: String           // unique key: chatName
    let chatName: String
    let chatIDs: [Int64]     // may span multiple internal chat IDs
    let isGroup: Bool
    let matchCount: Int

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ChatMatch, rhs: ChatMatch) -> Bool { lhs.id == rhs.id }
}

/// A single matching message within a chat, shown in the middle column
struct MessageMatch: Identifiable, Hashable {
    let id: Int64            // message ROWID
    let date: String?
    let snippet: String      // first ~80 chars of message text
    let isFromMe: Bool
    let sender: String

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: MessageMatch, rhs: MessageMatch) -> Bool { lhs.id == rhs.id }
}

enum AppLoadState {
    case loading(status: String)
    case permissionDenied
    case ready
    case error(String)
}
