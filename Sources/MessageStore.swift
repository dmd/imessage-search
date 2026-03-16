import Foundation
import SQLite3

final class MessageStore {
    let db: SQLiteDatabase
    let contacts: ContactResolver
    private(set) var handles: [Int64: HandleInfo] = [:]
    private(set) var chats: [Int64: ChatInfo] = [:]
    private(set) var messageCount: Int = 0
    private(set) var totalChats: Int = 0
    private(set) var totalContacts: Int = 0
    private(set) var dateFrom: String?
    private(set) var dateTo: String?

    static let appleEpochOffset: Int64 = 978307200
    static let perPage = 50
    static let contextSize = 5

    init(chatDBPath: String, contacts: ContactResolver) throws {
        self.db = try SQLiteDatabase(inMemory: true)
        self.contacts = contacts

        // Attach chat.db read-only
        try db.attachReadOnly(path: chatDBPath, as: "chatdb")

        // Register REGEXP function
        registerRegexp()

        // Create in-memory tables
        try db.execute("CREATE TABLE message_text (rowid INTEGER PRIMARY KEY, text TEXT NOT NULL)")
        try db.execute("""
            CREATE VIRTUAL TABLE message_fts USING fts5(
                text, content='', content_rowid='rowid'
            )
        """)

        // Populate from chat.db (streaming to avoid loading all rows into memory)
        var count = 0
        try db.execute("BEGIN")
        try db.forEach("SELECT ROWID, text, attributedBody FROM chatdb.message") { row in
            let rowid = row["ROWID"] as! Int64
            var text = row["text"] as? String
            if text == nil || text!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let blob = row["attributedBody"] as? Data {
                    text = AttributedBodyParser.extractText(from: blob)
                }
            }
            if let text = text?.replacingOccurrences(of: "\u{FFFC}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                try db.execute("INSERT INTO message_text(rowid, text) VALUES (?, ?)",
                              params: [rowid, text])
                try db.execute("INSERT INTO message_fts(rowid, text) VALUES (?, ?)",
                              params: [rowid, text])
                count += 1
            }
        }
        try db.execute("COMMIT")
        messageCount = count

        // Build handle cache
        let handleRows = try db.query("SELECT ROWID, id FROM chatdb.handle")
        for row in handleRows {
            let hid = row["ROWID"] as! Int64
            let handleStr = row["id"] as! String
            handles[hid] = HandleInfo(id: handleStr, name: contacts.resolve(handleStr))
        }
        totalContacts = handles.count

        // Build chat cache
        let chatRows = try db.query("""
            SELECT c.ROWID, c.display_name, c.chat_identifier,
                   GROUP_CONCAT(h.id, '|||') as members
            FROM chatdb.chat c
            LEFT JOIN chatdb.chat_handle_join chj ON c.ROWID = chj.chat_id
            LEFT JOIN chatdb.handle h ON chj.handle_id = h.ROWID
            GROUP BY c.ROWID
        """)
        for row in chatRows {
            let cid = row["ROWID"] as! Int64
            let displayName = row["display_name"] as? String
            let chatID = row["chat_identifier"] as? String
            let membersStr = row["members"] as? String
            let memberList = membersStr?.split(separator: "|||").map(String.init) ?? []
            let isGroup = (displayName != nil && !displayName!.isEmpty) || memberList.count > 1
            let memberNames = memberList.filter { !$0.isEmpty }.map { contacts.resolve($0) }

            let name: String
            if let dn = displayName, !dn.isEmpty {
                name = dn
            } else if isGroup && !memberNames.isEmpty {
                name = memberNames.sorted().joined(separator: ", ")
            } else if let ci = chatID {
                name = contacts.resolve(ci)
            } else {
                name = "Unknown Chat"
            }
            chats[cid] = ChatInfo(
                id: cid, name: name, isGroup: isGroup,
                identifier: chatID ?? "",
                hasDisplayName: displayName != nil && !displayName!.isEmpty
            )
        }
        totalChats = chats.count

        // Date range
        let dateRange = try db.query("SELECT MIN(date), MAX(date) FROM chatdb.message WHERE date > 0")
        if let row = dateRange.first {
            dateFrom = Self.appleNSToISO(row["MIN(date)"] as? Int64)
            dateTo = Self.appleNSToISO(row["MAX(date)"] as? Int64)
        }
    }

    // MARK: - Date utilities

    static func appleNSToISO(_ ns: Int64?) -> String? {
        guard let ns = ns, ns > 0 else { return nil }
        let ts = Double(ns) / 1_000_000_000.0 + Double(appleEpochOffset)
        let date = Date(timeIntervalSince1970: ts)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: date)
    }

    static func isoToAppleNS(_ iso: String) -> Int64 {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        guard let date = fmt.date(from: iso) else { return 0 }
        return Int64((date.timeIntervalSince1970 - Double(appleEpochOffset)) * 1_000_000_000)
    }

    /// Convert a message row to MessageInfo
    func messageToInfo(_ row: [String: Any?]) -> MessageInfo {
        var text = row["text"] as? String
        if text == nil || text!.isEmpty {
            if let blob = row["attributedBody"] as? Data {
                text = AttributedBodyParser.extractText(from: blob)
            }
        }
        text = (text ?? "").replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let handleRowid = row["handle_id"] as? Int64 ?? 0
        let hinfo = handles[handleRowid] ?? HandleInfo(id: "", name: "Unknown")
        let chatId = row["chat_id"] as? Int64 ?? 0
        let cinfo = chats[chatId] ?? ChatInfo(id: 0, name: "Unknown", isGroup: false, identifier: "", hasDisplayName: false)
        let isFromMe = (row["is_from_me"] as? Int64 ?? 0) != 0
        let sender = isFromMe ? "Me" : hinfo.name
        let dateRaw = row["date"] as? Int64 ?? 0

        return MessageInfo(
            id: row["message_id"] as? Int64 ?? 0,
            text: text ?? "",
            isFromMe: isFromMe,
            date: Self.appleNSToISO(dateRaw),
            dateRaw: dateRaw,
            sender: sender,
            handleID: hinfo.id,
            chatID: chatId,
            chatName: cinfo.name,
            isGroup: cinfo.isGroup,
            hasAttachments: (row["cache_has_attachments"] as? Int64 ?? 0) != 0
        )
    }

    // MARK: - REGEXP registration

    private func registerRegexp() {
        sqlite3_create_function_v2(
            db.rawPointer, "REGEXP", 2, SQLITE_UTF8, nil,
            { context, argc, argv in
                guard argc == 2 else {
                    sqlite3_result_int(context, 0)
                    return
                }
                guard let patternPtr = sqlite3_value_text(argv![0]),
                      let stringPtr = sqlite3_value_text(argv![1]) else {
                    sqlite3_result_int(context, 0)
                    return
                }
                let pattern = String(cString: patternPtr)
                let string = String(cString: stringPtr)
                do {
                    let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
                    let range = NSRange(string.startIndex..., in: string)
                    let match = regex.firstMatch(in: string, range: range) != nil
                    sqlite3_result_int(context, match ? 1 : 0)
                } catch {
                    sqlite3_result_int(context, 0)
                }
            }, nil, nil, nil
        )
    }
}
