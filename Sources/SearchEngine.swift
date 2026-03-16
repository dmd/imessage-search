import Foundation

struct SearchEngine {
    let store: MessageStore

    /// Preprocess FTS query: convert "-term" to "NOT term"
    static func preprocessFTSQuery(_ q: String) -> String {
        let pattern = #"(?:^|\s)-(\w+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return q }
        let range = NSRange(q.startIndex..., in: q)
        return regex.stringByReplacingMatches(in: q, range: range, withTemplate: " NOT $1")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Search messages with query and filters
    func search(
        query: String,
        contactFilter: String,
        dateFrom: String,
        dateTo: String,
        direction: String,   // "all", "sent", "received"
        chatIDs: [Int64],
        useRegex: Bool,
        page: Int
    ) -> SearchResults {
        let isEmpty = query.isEmpty && contactFilter.isEmpty && dateFrom.isEmpty && dateTo.isEmpty && chatIDs.isEmpty
        if isEmpty { return SearchResults(results: [], total: 0, page: 1, perPage: MessageStore.perPage) }

        let offset = (page - 1) * MessageStore.perPage
        var params: [Any?] = []
        var base: String

        if !query.isEmpty && !useRegex {
            // FTS search
            let ftsQuery = Self.preprocessFTSQuery(query)
            base = """
                SELECT m.ROWID as message_id, m.text, m.attributedBody,
                       m.is_from_me, m.date, m.handle_id,
                       m.cache_has_attachments, cmj.chat_id
                FROM message_fts fts
                JOIN chatdb.message m ON fts.rowid = m.ROWID
                LEFT JOIN chatdb.chat_message_join cmj ON m.ROWID = cmj.message_id
                WHERE message_fts MATCH ?
            """
            params.append(ftsQuery)
        } else if !query.isEmpty && useRegex {
            // Regex search
            base = """
                SELECT m.ROWID as message_id, m.text, m.attributedBody,
                       m.is_from_me, m.date, m.handle_id,
                       m.cache_has_attachments, cmj.chat_id
                FROM message_text mt
                JOIN chatdb.message m ON mt.rowid = m.ROWID
                LEFT JOIN chatdb.chat_message_join cmj ON m.ROWID = cmj.message_id
                WHERE mt.text REGEXP ?
            """
            params.append(query)
        } else {
            // Filter-only
            base = """
                SELECT m.ROWID as message_id, m.text, m.attributedBody,
                       m.is_from_me, m.date, m.handle_id,
                       m.cache_has_attachments, cmj.chat_id
                FROM chatdb.message m
                LEFT JOIN chatdb.chat_message_join cmj ON m.ROWID = cmj.message_id
                WHERE 1=1
            """
        }

        // Direction filter
        if direction == "sent" {
            base += " AND m.is_from_me = 1"
        } else if direction == "received" {
            base += " AND m.is_from_me = 0"
        }

        // Date filters
        if !dateFrom.isEmpty {
            base += " AND m.date >= ?"
            params.append(MessageStore.isoToAppleNS(dateFrom))
        }
        if !dateTo.isEmpty {
            // End-of-day inclusive: add one day
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            if let date = fmt.date(from: dateTo) {
                let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: date)!
                let ns = Int64((nextDay.timeIntervalSince1970 - Double(MessageStore.appleEpochOffset)) * 1_000_000_000)
                base += " AND m.date <= ?"
                params.append(ns)
            }
        }

        // Chat filter
        if !chatIDs.isEmpty {
            let placeholders = chatIDs.map { _ in "?" }.joined(separator: ",")
            base += " AND cmj.chat_id IN (\(placeholders))"
            params.append(contentsOf: chatIDs.map { $0 as Any? })
        }

        // Contact filter
        if !contactFilter.isEmpty {
            let cfLower = contactFilter.lowercased()
            let matchingHandleIDs = store.handles.filter { (_, info) in
                info.name.lowercased().contains(cfLower) || info.id.lowercased().contains(cfLower)
            }.map { $0.key }

            if matchingHandleIDs.isEmpty {
                return SearchResults(results: [], total: 0, page: page, perPage: MessageStore.perPage)
            }
            let placeholders = matchingHandleIDs.map { _ in "?" }.joined(separator: ",")
            base += " AND m.handle_id IN (\(placeholders))"
            params.append(contentsOf: matchingHandleIDs.map { $0 as Any? })
        }

        // Count total
        let total: Int
        do {
            total = Int(try store.db.queryScalar("SELECT COUNT(*) FROM (\(base))", params: params))
        } catch {
            return SearchResults(results: [], total: 0, page: page, perPage: MessageStore.perPage)
        }

        // Fetch page
        let resultSQL = base + " ORDER BY m.date DESC LIMIT ? OFFSET ?"
        var pageParams = params
        pageParams.append(MessageStore.perPage)
        pageParams.append(offset)

        let results: [MessageInfo]
        do {
            let rows = try store.db.query(resultSQL, params: pageParams)
            results = rows.map { store.messageToInfo($0) }
        } catch {
            return SearchResults(results: [], total: 0, page: page, perPage: MessageStore.perPage)
        }

        return SearchResults(results: results, total: total, page: page, perPage: MessageStore.perPage)
    }

    /// Load conversation context around a message
    func context(messageID: Int64, count: Int = MessageStore.contextSize) -> [MessageInfo] {
        guard let chatRow = try? store.db.query(
            "SELECT chat_id FROM chatdb.chat_message_join WHERE message_id = ? LIMIT 1",
            params: [messageID]
        ).first, let chatID = chatRow["chat_id"] as? Int64 else { return [] }

        guard let dateRow = try? store.db.query(
            "SELECT date FROM chatdb.message WHERE ROWID = ?",
            params: [messageID]
        ).first, let targetDate = dateRow["date"] as? Int64 else { return [] }

        let beforeRows = (try? store.db.query("""
            SELECT m.ROWID as message_id, m.text, m.attributedBody,
                   m.is_from_me, m.date, m.handle_id,
                   m.cache_has_attachments, ? as chat_id
            FROM chatdb.chat_message_join cmj
            JOIN chatdb.message m ON cmj.message_id = m.ROWID
            WHERE cmj.chat_id = ? AND m.date <= ?
            ORDER BY m.date DESC LIMIT ?
        """, params: [chatID, chatID, targetDate, count + 1])) ?? []

        let afterRows = (try? store.db.query("""
            SELECT m.ROWID as message_id, m.text, m.attributedBody,
                   m.is_from_me, m.date, m.handle_id,
                   m.cache_has_attachments, ? as chat_id
            FROM chatdb.chat_message_join cmj
            JOIN chatdb.message m ON cmj.message_id = m.ROWID
            WHERE cmj.chat_id = ? AND m.date > ?
            ORDER BY m.date ASC LIMIT ?
        """, params: [chatID, chatID, targetDate, count])) ?? []

        let allRows = beforeRows.reversed() + afterRows
        var seen = Set<Int64>()
        var result: [MessageInfo] = []
        for row in allRows {
            let mid = row["message_id"] as! Int64
            if seen.contains(mid) { continue }
            seen.insert(mid)
            var info = store.messageToInfo(row)
            info.isMatch = (mid == messageID)
            result.append(info)
        }
        return result
    }

    /// Get attachments for a message
    func attachments(messageID: Int64) -> [AttachmentInfo] {
        guard let rows = try? store.db.query("""
            SELECT a.ROWID, a.filename, a.mime_type, a.transfer_name, a.total_bytes
            FROM chatdb.attachment a
            JOIN chatdb.message_attachment_join maj ON a.ROWID = maj.attachment_id
            WHERE maj.message_id = ?
        """, params: [messageID]) else { return [] }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return rows.compactMap { row in
            let rawPath = (row["filename"] as? String) ?? ""
            let fullPath = rawPath.replacingOccurrences(of: "~", with: home)
            let transferName = (row["transfer_name"] as? String) ?? URL(fileURLWithPath: fullPath).lastPathComponent
            // Skip plugin payload attachments
            if transferName.hasSuffix(".pluginPayloadAttachment") { return nil }
            return AttachmentInfo(
                id: row["ROWID"] as! Int64,
                filename: transferName,
                mimeType: row["mime_type"] as? String,
                totalBytes: row["total_bytes"] as? Int64 ?? 0,
                exists: FileManager.default.fileExists(atPath: fullPath),
                fullPath: fullPath
            )
        }
    }
}
