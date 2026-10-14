import XCTest
import CryptoKit
@testable import TailnetCore

final class VaultTests: XCTestCase {
    func testVaultEncryptsRoundTripsAndRejectsWrongKey() throws {
        let key = SymmetricKey(size: .bits256)
        let tmp = NSTemporaryDirectory() + "vault-test-\(UUID().uuidString).bin"
        let previous = Vault.path
        Vault.path = tmp
        defer { Vault.path = previous; try? FileManager.default.removeItem(atPath: tmp) }

        var db = DB()
        var m = Machine(name: "AI Dev Box", host: "100.10.0.1")
        m.tags = ["threat intel"]
        db.machines = [m]
        db.keys = [KeyRecord(name: "id_ed25519", keyType: "ssh-ed25519", hasPrivate: true, hasPublic: true)]

        XCTAssertTrue(Vault.save(db, key: key))

        // at rest it's ciphertext: no plaintext markers in the file
        let raw = try Data(contentsOf: URL(fileURLWithPath: tmp))
        XCTAssertNil(raw.range(of: Data("AI Dev Box".utf8)))
        XCTAssertNil(raw.range(of: Data("threat intel".utf8)))

        // correct key round-trips everything
        let loaded = Vault.load(key: key)
        XCTAssertEqual(loaded.machines, db.machines)
        XCTAssertEqual(loaded.machines.first?.tags, ["threat intel"])
        XCTAssertEqual(loaded.keys, db.keys)

        // wrong key can't decrypt → reset to empty
        XCTAssertTrue(Vault.load(key: SymmetricKey(size: .bits256)).machines.isEmpty)
    }

    func testSessionLogTrimsToCap() {
        var db = DB()
        for i in 0..<600 {
            db.addSession(Session(machineId: "m", machineName: "m", kind: .ssh, detail: "run \(i)"))
        }
        XCTAssertEqual(db.sessions.count, DB.maxSessions)
        XCTAssertEqual(db.sessions.first?.detail, "run 599")   // newest first
        XCTAssertEqual(db.sessions.last?.detail, "run 100")    // oldest beyond cap dropped
    }

    func testFixPermsTightensPrivateKeysOnly() throws {
        let dir = NSTemporaryDirectory() + "perm-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let key = dir + "/testkey"
        try "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----\n"
            .write(toFile: key, atomically: true, encoding: .utf8)
        let other = dir + "/notes.txt"
        try "not a key".write(toFile: other, atomically: true, encoding: .utf8)
        for p in [key, other] {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: p)
        }

        SSHKeys.fixPerms(in: dir)

        let keyMode = (try FileManager.default.attributesOfItem(atPath: key)[.posixPermissions] as? NSNumber)?.intValue
        let otherMode = (try FileManager.default.attributesOfItem(atPath: other)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(keyMode, 0o600)   // private key tightened
        XCTAssertEqual(otherMode, 0o644) // non-key files untouched
    }

    /// Writes are deferred now: a store must write where its data came from, even if Vault.path changes meanwhile
    /// (tests swap it back to the real vault in `defer`).
    @MainActor func testDeferredWritesGoWhereTheStoreWasOpened() throws {
        let a = NSTemporaryDirectory() + "vault-a-\(UUID().uuidString).bin", b = NSTemporaryDirectory() + "vault-b-\(UUID().uuidString).bin"
        let previous = Vault.path
        defer { Vault.path = previous; for f in [a, a + ".bak", b] { try? FileManager.default.removeItem(atPath: f) } }
        Vault.path = a
        let s = Store(vaultKey: SymmetricKey(size: .bits256))
        s.machines = [Machine(name: "x", host: "10.0.0.9")]
        Vault.path = b                                    // what a test's defer does
        s.flushVault()
        XCTAssertTrue(FileManager.default.fileExists(atPath: a))
        XCTAssertFalse(FileManager.default.fileExists(atPath: b))
    }

    /// Passphrases reach ssh-keygen on stdin via SSH_ASKPASS, never argv — and the key really ends up encrypted with it.
    func testKeygenTakesThePassphraseOffArgv() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tnm-keygen-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let key = dir + "/k", pass = "it's a \"p4ss\" $HOME"
        XCTAssertEqual(SSHKeys.keygen("-q -t ed25519 -C t -f \(Remote.q(key)) 2>&1", passphrase: pass).code, 0)
        XCTAssertNotEqual(Shell.run("ssh-keygen -y -P '' -f \(Remote.q(key))").code, 0)               // encrypted
        XCTAssertEqual(SSHKeys.keygen("-y -f \(Remote.q(key))", passphrase: pass).code, 0)          // with exactly that
        XCTAssertNotEqual(SSHKeys.keygen("-y -f \(Remote.q(key))", passphrase: "wrong").code, 0)
        XCTAssertNotEqual(SSHKeys.keygen("-y -f \(Remote.q(key))", passphrase: "a\nb").code, 0)     // no line breaks
        XCTAssertFalse(SSHKeys.validName("../evil"))
        XCTAssertFalse(SSHKeys.validName(".hidden"))
    }

    /// install.sh's environment file: known keys only, and ignored entirely if anyone but you could have written it.
    func testUserEnvironmentReadsOnlyKnownKeysFromAPrivateFile() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("tnm-env-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: f) }
        let text = "PATH=/opt/homebrew/bin:/usr/bin:/bin\nSSH_AUTH_SOCK=/tmp/agent.sock\nDYLD_INSERT_LIBRARIES=/tmp/x.dylib\nCLAUDE_BIN=\njunk\n"
        FileManager.default.createFile(atPath: f, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        XCTAssertEqual(UserEnvironment.read(f).map(\.0), ["PATH", "SSH_AUTH_SOCK"])     // unknown, empty and malformed lines dropped
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: f)
        XCTAssertTrue(UserEnvironment.read(f).isEmpty)                                    // world-writable → ignored
        XCTAssertTrue(UserEnvironment.read(f + "-missing").isEmpty)
    }
}
