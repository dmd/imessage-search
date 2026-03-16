import Foundation
import SQLite3

struct ContactResolver {
    /// Map of normalized phone/lowercased email → display name
    private let lookup: [String: String]

    init() {
        var lookup: [String: String] = [:]
        let abBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AddressBook")

        // Find all AddressBook databases
        var dbPaths: [URL] = []
        if let sources = try? FileManager.default.contentsOfDirectory(
            at: abBase.appendingPathComponent("Sources"),
            includingPropertiesForKeys: nil
        ) {
            for source in sources {
                let db = source.appendingPathComponent("AddressBook-v22.abcddb")
                if FileManager.default.fileExists(atPath: db.path) {
                    dbPaths.append(db)
                }
            }
        }
        let topDB = abBase.appendingPathComponent("AddressBook-v22.abcddb")
        if FileManager.default.fileExists(atPath: topDB.path) {
            dbPaths.append(topDB)
        }

        for dbPath in dbPaths {
            var db: OpaquePointer?
            guard sqlite3_open_v2(
                "file:\(dbPath.path)?mode=ro&immutable=1",
                &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil
            ) == SQLITE_OK, let db = db else { continue }
            defer { sqlite3_close(db) }

            // Phone numbers
            var stmt: OpaquePointer?
            let phoneSql = """
                SELECT r.ZFIRSTNAME, r.ZLASTNAME, r.ZNICKNAME, r.ZORGANIZATION,
                       p.ZFULLNUMBER
                FROM ZABCDRECORD r
                JOIN ZABCDPHONENUMBER p ON p.ZOWNER = r.Z_PK
            """
            if sqlite3_prepare_v2(db, phoneSql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let name = Self.resolveName(stmt: stmt!, firstCol: 0)
                    let phone = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                    if let name = name, let phone = phone {
                        let normed = Self.normalizePhone(phone)
                        if !normed.isEmpty { lookup[normed] = name }
                    }
                }
                sqlite3_finalize(stmt)
            }

            // Email addresses
            stmt = nil
            let emailSql = """
                SELECT r.ZFIRSTNAME, r.ZLASTNAME, r.ZNICKNAME, r.ZORGANIZATION,
                       e.ZADDRESS
                FROM ZABCDRECORD r
                JOIN ZABCDEMAILADDRESS e ON e.ZOWNER = r.Z_PK
            """
            if sqlite3_prepare_v2(db, emailSql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let name = Self.resolveName(stmt: stmt!, firstCol: 0)
                    let email = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                    if let name = name, let email = email {
                        lookup[email.lowercased()] = name
                    }
                }
                sqlite3_finalize(stmt)
            }
        }

        self.lookup = lookup
    }

    /// Resolve a handle ID to a display name
    func resolve(_ handleID: String?) -> String {
        guard let handleID = handleID, !handleID.isEmpty else { return "Unknown" }
        if handleID.contains("@") {
            return lookup[handleID.lowercased()] ?? handleID
        }
        return lookup[Self.normalizePhone(handleID)] ?? handleID
    }

    /// Number of loaded contact mappings
    var count: Int { lookup.count }

    /// All resolved contact names (for checking if a chat name contains a known contact)
    var resolvedNames: [String] { Array(Set(lookup.values)) }

    // MARK: - Static helpers

    static func normalizePhone(_ raw: String) -> String {
        let digits = raw.unicodeScalars.filter(CharacterSet.decimalDigits.contains).map(String.init).joined()
        if digits.count > 10 && digits.hasPrefix("1") {
            return String(digits.dropFirst())
        }
        return digits
    }

    private static func resolveName(stmt: OpaquePointer, firstCol: Int32) -> String? {
        let first = sqlite3_column_text(stmt, firstCol).map { String(cString: $0) } ?? ""
        let last = sqlite3_column_text(stmt, firstCol + 1).map { String(cString: $0) } ?? ""
        let nick = sqlite3_column_text(stmt, firstCol + 2).map { String(cString: $0) }
        let org = sqlite3_column_text(stmt, firstCol + 3).map { String(cString: $0) }

        let fullName = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
        if !fullName.isEmpty { return fullName }
        if let nick = nick, !nick.isEmpty { return nick }
        if let org = org, !org.isEmpty { return org }
        return nil
    }
}
