import Foundation
import CryptoKit
import Security

// MARK: - Encrypted database (AES-GCM sealed file, key held in the macOS Keychain)
// ponytail: whole-file seal/open per write — fine for a few thousand records;
// move to SQLCipher/GRDB if the session log ever outgrows ~10k entries.

enum SessionKind: String, Codable {
    case ssh, htop, rdp, console, specs, verify, keyAdd, keyDelete, machineAdd, machineDelete, transfer, password, rclone, claude
}

struct Session: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var machineId: String
    var machineName: String
    var kind: SessionKind
    var detail = ""
    var user = ""
    var at = Date()
    var durationMs: Int? = nil
}

struct KeyRecord: Codable, Identifiable, Hashable {
    var name: String
    var keyType = ""
    var hasPrivate = false
    var hasPublic = false
    var addedAt = Date()
    var lastSeenAt = Date()
    var id: String { name }
}

struct DB: Codable {
    var machines: [Machine] = []
    var keys: [KeyRecord] = []
    var sessions: [Session] = []
    var folders: [Folder]? = nil   // nil = vault predates folders (optional so old vaults still decode)
    var credentials: [Credential]? = nil
    var remotes: [RcloneRemote]? = nil
    var events: [PipelineEvent]? = nil   // webhook updates from your servers, newest first
    var eventsSeenAt: Date? = nil
    var pipelineToken: String? = nil
    var pipelineGroups: [PipelineGroup]? = nil   // your named pipelines (which runs each claims, its run days)
    var snippets: [Snippet]? = nil
    var services: [String: ServiceSettings]? = nil   // your names for pipeline sections
    static let maxSessions = 500
    // ponytail: every event reseals the whole vault — fine to ~1 event/s; batch writes if a pipeline gets chattier
    static let maxEvents = 1000

    mutating func addSession(_ s: Session) {
        sessions.insert(s, at: 0)
        if sessions.count > DB.maxSessions { sessions = Array(sessions.prefix(DB.maxSessions)) }
    }
}

/// The bundle id (build.sh writes the same string). It also prefixes the Keychain item that holds the vault key,
/// so changing it orphans every existing install's key.
public enum AppInfo {
    public static let bundleID = "io.github.xorroproprop.tailnet-manager"
    /// Named by the bundle id, so no other build of this app (a fork, a private copy) shares a vault it can't open.
    static var supportDir: String { NSHomeDirectory() + "/Library/Application Support/" + bundleID }
}

enum Vault {
    static var path: String = AppInfo.supportDir + "/vault.bin"
    private static let service = AppInfo.bundleID + ".vault"
    private static let account = "db-key"

    /// 256-bit key from the Keychain (created on first run). Never touches disk unencrypted.
    static func key() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, !data.isEmpty {
            return SymmetricKey(data: data)
        }
        let k = SymmetricKey(size: .bits256)
        let raw = k.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: raw,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? k : nil
    }

    static func load(key: SymmetricKey? = key()) -> DB {
        guard let key else { return DB() }
        guard let blob = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return migrateFromDefaults() }
        guard let plain = try? AES.GCM.open(try AES.GCM.SealedBox(combined: blob), using: key) else {
            return backupAndReset()
        }
        return (try? JSONDecoder().decode(DB.self, from: plain)) ?? backupAndReset()
    }

    /// `path` is fixed by the caller when its data was opened — a deferred write must never land on whatever
    /// `Vault.path` says later (tests swap it).
    @discardableResult
    static func save(_ db: DB, key: SymmetricKey? = key(), path: String = Vault.path) -> Bool {
        guard let key, let plain = try? JSONEncoder().encode(db),
              let sealed = try? AES.GCM.seal(plain, using: key).combined else { return false }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // keep last-good copy — insurance against any future clobber/corruption
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path + ".bak")
            try? FileManager.default.copyItem(atPath: path, toPath: path + ".bak")
        }
        do {
            try sealed.write(to: URL(fileURLWithPath: path), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return true
        } catch { return false }
    }

    /// Set when load() had to move an unreadable vault aside — Store shows it instead of an unexplained empty app.
    static var resetNote: String?

    private static func backupAndReset() -> DB {
        // decrypt failed (corrupt file or wrong key) — keep the bytes for forensics, start fresh
        let ts = Int(Date().timeIntervalSince1970)
        try? FileManager.default.moveItem(atPath: path, toPath: path + ".corrupt-\(ts)")
        resetNote = "Couldn't open the encrypted vault with the Keychain key — it was kept as vault.bin.corrupt-\(ts) and a new one started."
        return migrateFromDefaults()
    }

    private static func migrateFromDefaults() -> DB {
        guard let d = UserDefaults.standard.data(forKey: "machines"),
              let ms = try? JSONDecoder().decode([Machine].self, from: d), !ms.isEmpty else { return DB() }
        UserDefaults.standard.removeObject(forKey: "machines")
        var db = DB()
        db.machines = ms
        _ = save(db)
        return db
    }
}
