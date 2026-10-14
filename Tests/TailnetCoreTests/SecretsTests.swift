import XCTest
import CryptoKit
@testable import TailnetCore

@MainActor
final class SecretsTests: XCTestCase {
    func testPromptDetectionRefusesShellLines() {
        for p in ["[sudo] password for alice: ", "Password:", "Password: ", "alice@10.0.0.5's password: ",
                  "Enter passphrase for key '/home/j/.ssh/id_ed25519': ", "doas (alice@db) password: "] {
            XCTAssertTrue(PasswordPrompt.matches(p), p)
        }
        for p in ["alice@db:~$ ", "alice@db:~$ echo password: ", "root@db:/# grep password: ", "% read password: ",
                  "~/src ❯ > password:", "~/src ❯ echo password: ", "➜  src echo password: ", "λ grep password: ",
                  "Password: hunter2", ""] {
            XCTAssertFalse(PasswordPrompt.matches(p), p)
        }
    }

    func testPickNeverGuessesBetweenUsers() {
        let root = Credential(machineId: "m", user: "root", sealed: Data())
        let me = Credential(machineId: "m", user: "alice", sealed: Data())
        XCTAssertEqual(PasswordPrompt.pick("[sudo] password for alice: ", from: [root, me]), me)
        XCTAssertNil(PasswordPrompt.pick("[sudo] password for alice: ", from: [root]))   // asked for alice, only root saved
        XCTAssertEqual(PasswordPrompt.pick("Password: ", from: [root]), root)
        XCTAssertNil(PasswordPrompt.pick("Password: ", from: [root, me]))               // ambiguous → you choose
    }

    func testPasswordsAreSealedPerItemAndNeverPlaintextAtRest() throws {
        let tmp = NSTemporaryDirectory() + "vault-\(UUID().uuidString).bin"
        let previous = Vault.path
        Vault.path = tmp
        defer {
            Vault.path = previous
            for f in [tmp, tmp + ".bak"] { try? FileManager.default.removeItem(atPath: f) }
        }
        let key = SymmetricKey(size: .bits256)
        let s = Store(vaultKey: key)
        s.machines = [Machine(id: "m", name: "db", host: "10.0.0.5")]
        let secret = "hunter2-correct-horse"

        XCTAssertNil(s.saveCredential(machine: "m", user: "root", password: secret))
        let c = try XCTUnwrap(s.credentials(for: "m").first)
        XCTAssertNil(c.sealed.range(of: Data("hunter2".utf8)))
        XCTAssertEqual(s.openCredential(c), Array(secret.utf8))

        s.flushVault()                                                             // writes are deferred; quitting does this
        let file = try Data(contentsOf: URL(fileURLWithPath: tmp))
        XCTAssertNil(file.range(of: Data("hunter2".utf8)))                         // not in the vault file
        let opened = try JSONEncoder().encode(Vault.load(key: key))
        XCTAssertNil(opened.range(of: Data("hunter2".utf8)))                       // nor in the decrypted vault: own seal

        XCTAssertNil(s.saveCredential(machine: "m", user: "root", password: "rotated"))
        XCTAssertEqual(s.credentials(for: "m").count, 1)                           // same user replaces
        s.remove(s.machines[0])
        XCTAssertTrue(s.credentials.isEmpty)                                       // machine gone → its passwords gone

        XCTAssertNotNil(Store(vaultKey: nil).saveCredential(machine: "m", user: "root", password: "x"))   // no Keychain → refuse
    }
}
