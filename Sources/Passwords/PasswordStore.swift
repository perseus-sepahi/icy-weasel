import Foundation
import Security

/// A saved sign-in. The password itself is only read from the keychain at the
/// moment it's filled, copied or shown.
struct SavedLogin: Identifiable, Hashable, Sendable {
    let host: String
    let username: String
    var id: String { "\(host)|\(username)" }
}

/// Passwords live in the Mac's login keychain as internet passwords, the same
/// item type Safari has long used: encrypted by macOS, unlocked with the Mac,
/// readable in Keychain Access. Nothing is stored anywhere else.
enum PasswordStore {
    /// Tags items saved by Icy Weasel, so listing never touches other apps' items.
    /// Tests swap in their own marker.
    nonisolated(unsafe) static var marker = "Saved by Icy Weasel"

    private static func query(host: String, username: String? = nil) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host.lowercased(),
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            kSecAttrComment as String: marker
        ]
        if let username { q[kSecAttrAccount as String] = username }
        return q
    }

    /// Saves, or updates the password of an existing sign-in.
    @discardableResult
    static func save(host: String, username: String, password: String) -> Bool {
        guard !host.isEmpty, !password.isEmpty else { return false }
        let base = query(host: host, username: username)
        let data = Data(password.utf8)
        let updated = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = host.lowercased()
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Sign-ins for one exact host, or all of them.
    static func logins(for host: String? = nil) -> [SavedLogin] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrComment as String: marker,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        if let host { q[kSecAttrServer as String] = host.lowercased() }
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item -> SavedLogin? in
            guard let server = item[kSecAttrServer as String] as? String,
                  let account = item[kSecAttrAccount as String] as? String else { return nil }
            return SavedLogin(host: server, username: account)
        }
        .sorted { ($0.host, $0.username) < ($1.host, $1.username) }
    }

    static func password(for login: SavedLogin) -> String? {
        var q = query(host: login.host, username: login.username)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ login: SavedLogin) {
        SecItemDelete(query(host: login.host, username: login.username) as CFDictionary)
    }
}

/// Imports a password export from Google Password Manager / Chrome, Safari,
/// Firefox or most password managers (CSV with url, username, password columns).
enum PasswordImport {
    struct Row: Equatable { let host: String; let username: String; let password: String }

    static func parse(_ text: String) -> (rows: [Row], skipped: Int) {
        let records = csvRecords(text)
        guard let header = records.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) else { return ([], 0) }
        func column(_ names: [String]) -> Int? { names.lazy.compactMap { header.firstIndex(of: $0) }.first }
        guard let urlIndex = column(["url", "website", "origin", "login_uri", "login url"]),
              let passwordIndex = column(["password", "login_password"]) else { return ([], max(0, records.count - 1)) }
        let userIndex = column(["username", "login", "login_username", "user name", "email"])
        var rows: [Row] = [], skipped = 0
        for record in records.dropFirst() where !(record.count == 1 && record[0].isEmpty) {
            func field(_ i: Int?) -> String { guard let i, i < record.count else { return "" }; return record[i] }
            guard let url = URL(string: field(urlIndex).trimmingCharacters(in: .whitespaces)),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased(),
                  !field(passwordIndex).isEmpty else { skipped += 1; continue }
            rows.append(Row(host: host, username: field(userIndex), password: field(passwordIndex)))
        }
        return (rows, skipped)
    }

    /// RFC 4180: quoted fields, doubled quotes, commas and newlines inside quotes.
    static func csvRecords(_ text: String) -> [[String]] {
        var records: [[String]] = [], record: [String] = [], field = ""
        var inQuotes = false
        var chars = text.makeIterator()
        var pending: Character? = nil
        func next() -> Character? { if let p = pending { pending = nil; return p }; return chars.next() }
        while let c = next() {
            if inQuotes {
                if c == "\"" {
                    if let n = next() {
                        if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n }
                    } else { inQuotes = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": record.append(field); field = ""
                case "\n", "\r\n": record.append(field); records.append(record); record = []; field = ""
                case "\r": break
                default: field.append(c)
                }
            }
        }
        if !field.isEmpty || !record.isEmpty { record.append(field); records.append(record) }
        return records
    }
}
