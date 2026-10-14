import XCTest
@testable import TailnetCore

final class ConnectionAndCloudTests: XCTestCase {
    func testSshArgsHardenFirstThenPinKeyPortAndOptions() {
        var m = Machine(name: "db", host: "100.10.0.9")
        m.sshUser = "alice"
        XCTAssertEqual(m.sshArgs, ["-o", "ControlPath=none", "-a", "alice@100.10.0.9"])
        m.sshPort = " 2222 "
        m.sshKey = "id_work"
        m.sshOptions = "-J bastion  -o ServerAliveInterval=30"
        XCTAssertEqual(m.sshArgs, ["-o", "ControlPath=none", "-a",            // hardening can't be overridden by OPTIONS -o
                                   "-p", "2222",
                                   "-i", SSHKeys.privPath("id_work"), "-o", "IdentitiesOnly=yes",   // only the chosen key is offered
                                   "-J", "bastion", "-o", "ServerAliveInterval=30",
                                   "alice@100.10.0.9"])
        m.sshPort = "abc"   // junk port is ignored, not passed through
        XCTAssertFalse(m.sshArgs.contains("-p"))
    }

    func testMachineDecodesVaultWithoutConnectionFields() throws {
        let legacy = #"[{"id":"x","name":"n","host":"h","kind":"ssh","tags":["a"]}]"#
        let m = try JSONDecoder().decode([Machine].self, from: Data(legacy.utf8))[0]
        XCTAssertEqual([m.sshPort, m.sshKey, m.sshOptions], ["", "", ""])
        XCTAssertEqual(m.folderId, "")
    }

    func testAuthReportNamesTheKey() {
        let ok = "debug1: Offering public key: /Users/alice/.ssh/id_rsa RSA SHA256:x\ndebug1: Server accepts key: /Users/alice/.ssh/id_work ED25519 SHA256:y\nAuthenticated"
        XCTAssertEqual(Remote.authReport(ok, ok: true), "authenticated with id_work")
        let bad = "debug1: Offering public key: /Users/alice/.ssh/id_rsa RSA\ndebug1: Offering public key: /Users/alice/.ssh/id_ed25519 ED25519\ndebug1: Offering public key: /Users/alice/.ssh/id_rsa RSA\nalice@db: Permission denied (publickey)."
        XCTAssertEqual(Remote.authReport(bad, ok: false), "alice@db: Permission denied (publickey). · tried: id_rsa, id_ed25519")
        XCTAssertTrue(Remote.authReport("No ED25519 host key is known for db and you have requested strict checking.\nHost key verification failed.", ok: false)
            .hasPrefix("host key not trusted yet"))
    }

    func testTransferArgvParsing() {
        let r = Transfer.parse("/usr/bin/rclone --config /etc/rclone.conf -P sync /data/backups gcs:bucket/backups --transfers 8 --rc")
        XCTAssertEqual(r, .init(tool: "rclone", op: "sync", src: "/data/backups", dst: "gcs:bucket/backups"))
        let g = Transfer.parse("/usr/bin/python3 /usr/lib/google-cloud-sdk/lib/gcloud.py storage cp -r /srv/a /srv/b gs://b/y")
        XCTAssertEqual(g, .init(tool: "gcloud", op: "cp", src: "/srv/a", dst: "gs://b/y"))
        let u = Transfer.parse("python3 /opt/gsutil/gsutil -m -o GSUtil:parallel_thread_count=8 rsync -r data gs://bkt/data")
        XCTAssertEqual(u, .init(tool: "gsutil", op: "rsync", src: "data", dst: "gs://bkt/data"))
        XCTAssertEqual(Transfer.seconds("2-03:04:05"), 2 * 86400 + 3 * 3600 + 4 * 60 + 5)
        XCTAssertEqual(Transfer.seconds("04:05"), 245)
    }

    func testScanFoldsWorkersAndReadsStatsAndIdentity() {
        let out = """
        T\t100\t1\t01:00:00\t5000\t9000\tpython3 gsutil -m cp -r /d gs://b
        T\t101\t100\t59:00\t100\t1000\tpython3 gsutil -m cp -r /d gs://b
        T\t200\t1\t10:00\t\t\trclone sync /a gcs:b --rc
        R\t200\t{"bytes": 50, "totalBytes": 200, "speed": 10.5, "eta": 15, "errors": 0}
        G\talice@example.com\tproj-x
        C\tgcs:   google cloud storage
        """
        let (ts, ident) = Scan.parse(out, machineId: "m", machineName: "db")
        XCTAssertEqual(ts.map(\.pid), [100, 200])                  // worker 101 folded into 100
        XCTAssertEqual(ts[0].sent, 10000)
        XCTAssertEqual(ts[0].elapsed, 3600)
        XCTAssertNil(ts[1].sent)                                   // no /proc (macOS) → unknown, not zero
        XCTAssertEqual(ts[1].stats?.fraction, 0.25)
        XCTAssertEqual(ts[1].speed, 10.5)
        XCTAssertEqual(ident?.gcloud, "alice@example.com · proj-x")
        XCTAssertEqual(ident?.rclone, ["gcs: google cloud storage"])
    }

    @MainActor func testEditedRouteIsWhatConnectUsesAndDropsOldVerification() {
        let store = Store(vaultKey: nil)
        var m = Machine(name: "Main Home Machine", host: "100.64.0.1")
        m.authVerifiedAt = Date()
        store.machines = [m]

        m.name = "Home"                                   // cosmetic edit keeps verification
        store.upsert(m)
        XCTAssertNotNil(store.machines[0].authVerifiedAt)

        m.host = "100.64.0.2"                             // new IP → old verification is void
        store.upsert(m)
        XCTAssertNil(store.machines[0].authVerifiedAt)
        XCTAssertEqual(store.machines[0].sshArgs.last, "\(m.sshLogin)@100.64.0.2")   // the args a new tab is built from
        XCTAssertEqual(TermSession.args(store.machines[0]).last, "\(m.sshLogin)@100.64.0.2")
    }

    func testVerifyUsesACrossPlatformNoopSoWindowsHostsCanVerify() {
        var m = Machine(name: "build-box", host: "100.64.0.9"); m.sshUser = "bob"
        let cmd = Remote.sshCommand(m, command: Remote.okCheck, verbose: true)
        XCTAssertEqual(Remote.okCheck, "exit 0")                    // runs 0 on POSIX sh AND Windows cmd.exe
        XCTAssertFalse(cmd.contains("'true'"))                      // `true` is exit 1 on cmd.exe → verify fell over on Windows
        XCTAssertTrue(cmd.hasSuffix("'exit 0'"), cmd)
        XCTAssertTrue(cmd.contains("'-v'"))                         // still verbose, so authReport can name the key
        XCTAssertTrue(cmd.contains("bob@100.64.0.9"))
    }

    /// Any user on a host controls the argv `ps` shows. The scan used to run that argv's first word (`/bin/sh` here, so
    /// `sh rc core/stats` ran ./rc from the scan's directory); it must only ever call rclone itself.
    func testScannerNeverRunsAProgramNamedByPs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tnm-scan-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let marker = dir + "/ran"
        try "touch '\(marker)'\n".write(toFile: dir + "/rc", atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 5; : rclone copy a b --rc"]   // looks like an rclone transfer with --rc to the scan
        try p.run()
        defer { p.terminate() }
        let (_, out) = Shell.run("cd \(Remote.q(dir)) && /bin/sh -c \(Remote.q(Scan.script))")
        XCTAssertTrue(out.contains("T\t\(p.processIdentifier)\t"), out)                     // the scan saw it
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))                       // and ran nothing of its
    }

    /// Numbers from a remote ps, /proc or rclone's rc can be anything; none of them may trap.
    func testHostileScanNumbersAreClamped() {
        let out = "T\t1\t0\t999999999999999-99:99:99\t-5\t9223372036854775807\trclone copy a b:c\n"
            + "T\t2\t1\t00:01\t1\t9223372036854775807\trclone copy a b:c\n"
            + "R\t1\t{\"speed\":1e300,\"eta\":1e300,\"bytes\":1,\"totalBytes\":2}\n"
        let (ts, _) = Scan.parse(out, machineId: "m", machineName: "m")
        XCTAssertEqual(ts.count, 1)                               // worker 2 folded into 1
        XCTAssertEqual(ts[0].sent, 1 << 51)                       // two counters capped at 1 PiB each, summed
        XCTAssertEqual(ts[0].recv, 1)                             // negative → 0, plus 1
        XCTAssertEqual(ts[0].stats?.speed, 1e15)
        XCTAssertLessThan(ts[0].elapsed, 100_000 * 86400 + 4_000_000_000)
    }
}
