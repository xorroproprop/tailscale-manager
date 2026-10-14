import XCTest
import CryptoKit
@testable import TailnetCore

final class RcloneTests: XCTestCase {
    var dir = ""
    var conf: String { dir + "/rclone.conf" }

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "rclone-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // stand-in rclone: just the two subcommands the deploy script uses
        let shim = dir + "/rclone"
        try """
        #!/bin/sh
        case "$1 $2" in
          "config file") echo "Configuration file is stored at:"; echo "$RCLONE_CONFIG" ;;
          "obscure -") read -r p; printf 'OBS(%s)\\n' "$p" ;;
          *) exit 1 ;;
        esac
        """.write(toFile: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    func deploy(_ r: RcloneRemote, _ secrets: [String: String], replace: Bool = false) -> (Int32, String) {
        Shell.run("PATH=\(Remote.q(dir)):$PATH RCLONE_CONFIG=\(Remote.q(conf)) /bin/sh -s",
                  input: Data(Rclone.deployScript(r, secrets: secrets, replace: replace).utf8))
    }
    func text() -> String { (try? String(contentsOfFile: conf, encoding: .utf8)) ?? "" }

    func testDeployWritesSectionObscuresPasswordsAndGuardsExisting() throws {
        try "[keep]\ntype = local\n".write(toFile: conf, atomically: true, encoding: .utf8)
        var sftp = RcloneRemote(name: "nas", type: "sftp")
        sftp.values = ["host": "nas.local", "user": "alice", "known_hosts_file": "~/.ssh/known_hosts"]

        let (code, out) = deploy(sftp, ["pass": "hunter2"])
        XCTAssertEqual(code, 0, out)
        XCTAssertTrue(out.contains("TNM_OK \(conf)"))
        XCTAssertTrue(text().contains("[nas]\ntype = sftp\nhost = nas.local\nuser = alice\npass = OBS(hunter2)\nknown_hosts_file = ~/.ssh/known_hosts\n"), text())
        XCTAssertFalse(text().contains("pass = hunter2"))                      // obscured on the host, never written raw
        let mode = (try FileManager.default.attributesOfItem(atPath: conf)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)

        let before = text()
        let (c2, o2) = deploy(sftp, ["pass": "other"])                        // exists, no replace → refuse, untouched
        XCTAssertEqual(c2, 4); XCTAssertTrue(o2.contains("TNM_EXISTS")); XCTAssertEqual(text(), before)

        sftp.values["host"] = "nas2.local"
        XCTAssertEqual(deploy(sftp, ["pass": "rotated"], replace: true).0, 0)   // replace: old section out, others kept, backup made
        XCTAssertEqual(text().components(separatedBy: "[nas]").count - 1, 1)
        XCTAssertTrue(text().contains("host = nas2.local") && text().contains("OBS(rotated)") && !text().contains("nas.local\n"))
        XCTAssertTrue(text().hasPrefix("[keep]\ntype = local\n"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir).contains { $0.hasPrefix("rclone.conf.tnm-") })
        XCTAssertEqual(deploy(sftp, ["pass": "rotated-again"], replace: true).0, 0)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix("rclone.conf.") }
        XCTAssertEqual(left.filter { $0.hasSuffix(".bak") }.count, 1, "\(left)")          // only the newest backup stays
        XCTAssertEqual(left.count, 1, "\(left)")                                           // and no temp file is left behind
    }

    func testValuesCannotBreakOutOfTheScript() {
        let canary = dir + "/pwned"
        var s3 = RcloneRemote(name: "s3x", type: "s3")
        s3.values = ["provider": "Other", "endpoint": "x'; touch \(canary); echo '"]
        let (code, out) = deploy(s3, ["secret_access_key": "$(touch \(canary))`touch \(canary)`"])
        XCTAssertEqual(code, 0, out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canary))       // nothing executed
        XCTAssertTrue(text().contains("secret_access_key = $(touch \(canary))`touch \(canary)`"))   // stored literally
    }

    func testRefusesEncryptedConfig() throws {
        try "RCLONE_ENCRYPT_V0:\nabc\n".write(toFile: conf, atomically: true, encoding: .utf8)
        let (code, out) = deploy(RcloneRemote(name: "x", type: "b2", values: ["account": "k"]), ["key": "s"])
        XCTAssertEqual(code, 3)
        XCTAssertTrue(out.contains("TNM_ERR rclone.conf is encrypted"))
        XCTAssertEqual(text(), "RCLONE_ENCRYPT_V0:\nabc\n")
    }

    @MainActor func testStoreSealsSecretsKeepsBlanksAndValidates() throws {
        let tmp = dir + "/vault.bin"
        let previous = Vault.path
        Vault.path = tmp
        defer { Vault.path = previous }
        let key = SymmetricKey(size: .bits256)
        let s = Store(vaultKey: key)

        var r = RcloneRemote(name: "r2", type: "s3", values: ["provider": "Cloudflare", "access_key_id": "AK"])
        XCTAssertNil(s.saveRemote(r, newSecrets: ["secret_access_key": "SUPERSECRET"]))
        r = s.remotes[0]
        XCTAssertEqual(r.secretKeys, ["secret_access_key"])
        s.flushVault()                                                            // writes are deferred; quitting does this
        XCTAssertNil(try Data(contentsOf: URL(fileURLWithPath: tmp)).range(of: Data("SUPERSECRET".utf8)))
        XCTAssertNil(try JSONEncoder().encode(Vault.load(key: key)).range(of: Data("SUPERSECRET".utf8)))   // own seal inside the vault
        XCTAssertEqual(s.remoteSecrets(r), ["secret_access_key": "SUPERSECRET"])

        r.values["region"] = "auto"
        XCTAssertNil(s.saveRemote(r, newSecrets: ["secret_access_key": ""]))     // blank = keep
        XCTAssertEqual(s.remoteSecrets(s.remotes[0]), ["secret_access_key": "SUPERSECRET"])
        XCTAssertNil(s.saveRemote(s.remotes[0], newSecrets: [:], cleared: ["secret_access_key"]))
        XCTAssertNil(s.remotes[0].sealed)

        XCTAssertNotNil(s.saveRemote(RcloneRemote(name: "bad name", type: "s3"), newSecrets: [:]))
        XCTAssertNotNil(s.saveRemote(RcloneRemote(name: "r2", type: "s3"), newSecrets: [:]))               // duplicate name
        XCTAssertNotNil(s.saveRemote(RcloneRemote(name: "n", type: "sftp"), newSecrets: [:]))              // host required
        XCTAssertNotNil(s.saveRemote(RcloneRemote(name: "n", type: "sftp", values: ["host": "a\nb"]), newSecrets: [:]))   // no newlines
        var moved = s.remotes[0]                                                                         // type change drops foreign keys
        moved.type = "b2"; moved.values["account"] = "kid"
        XCTAssertNil(s.saveRemote(moved, newSecrets: ["key": "appkey"]))
        XCTAssertEqual(Set(s.remotes[0].values.keys), ["account"])
    }
}
