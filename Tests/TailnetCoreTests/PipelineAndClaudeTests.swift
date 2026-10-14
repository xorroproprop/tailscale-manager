import XCTest
@testable import TailnetCore

final class PipelineAndClaudeTests: XCTestCase {
    func body(_ json: String) -> Data { Data(json.utf8) }

    func testDecodesWhatPythonPowerShellAndCurlSendAndRejectsBadEvents() throws {
        // Python isoformat (6 digits, +00:00), .NET "o" (7 digits), plain Z, naive (= UTC), epoch ms
        for ts in [#""2026-10-05T14:03:22.123456+00:00""#, #""2026-10-05T14:03:22.1234567Z""#,
                   #""2026-10-05T14:03:22Z""#, #""2026-10-05 14:03:22""#, "1791209002000"] {
            let e = try PipelineEvent.decode(body(#"{"job_id":42,"timestamp":\#(ts),"event":"job_failed","stage":"parse","status":"FAILED"}"#))
            XCTAssertEqual(e.jobId, "42")                                     // numeric ids become strings
            XCTAssertEqual(e.at.timeIntervalSince1970, 1791209002, accuracy: 1, ts)
            XCTAssertTrue(e.failed)
        }
        let offset = try PipelineEvent.decode(body(#"{"job_id":"j","timestamp":"2026-10-05T09:03:22-05:00","event":"x","status":"running"}"#))
        XCTAssertEqual(offset.at.timeIntervalSince1970, 1791209002, accuracy: 1)
        XCTAssertEqual(offset.stage, "")                                      // stage optional
        XCTAssertTrue(offset.running)

        let t = try PipelineEvent.decode(body(#"{"job_id":"j","timestamp":"2026-10-05T14:03:22Z","event":"stage_finished","status":"success","telemetry":{"rows":3,"path":"C:/in/a.csv"},"message":"ok"}"#))
        XCTAssertFalse(t.failed)
        XCTAssertTrue(t.telemetry.contains(#""path" : "C:/in/a.csv""#))
        XCTAssertEqual(t.message, "ok")

        func error(_ json: String) -> String? {
            do { _ = try PipelineEvent.decode(body(json)); return nil } catch { return (error as? PipelineEvent.Bad)?.message }
        }
        XCTAssertEqual(error("[1]"), "body must be a JSON object")
        XCTAssertEqual(error(#"{"timestamp":"2026-10-05T14:03:22Z","event":"x","status":"ok"}"#), "job_id (or resource.id) is required")
        XCTAssertEqual(error(#"{"job_id":"j","timestamp":"2026-10-05T14:03:22Z","event":"x"}"#), "status is required")
        XCTAssertEqual(error(#"{"job_id":"j","timestamp":"yesterday","event":"x","status":"ok"}"#)?.hasPrefix("timestamp"), true)
        XCTAssertEqual(error(#"{"job_id":["a"],"timestamp":"2026-10-05T14:03:22Z","event":"x","status":"ok"}"#), "job_id must be a string")
    }

    func testHTTPReaderHandlesSplitsContinueChunkedAndOversize() {
        let req = "POST /pipeline-events?x=1 HTTP/1.1\r\nHost: a\r\nContent-Length: 4\r\nAuthorization: Bearer t\r\n\r\n"
        guard case .incomplete(false) = HTTP.parse(Data("POST / HTTP/1.1\r\nHost".utf8)) else { return XCTFail("headers split") }
        guard case .incomplete(false) = HTTP.parse(Data((req + "ab").utf8)) else { return XCTFail("body split") }
        guard case .done(let r) = HTTP.parse(Data((req + "abcd").utf8)) else { return XCTFail("complete") }
        XCTAssertEqual([r.method, r.path, r.headers["authorization"]], ["POST", "/pipeline-events?x=1", "Bearer t"])
        XCTAssertEqual(r.body, Data("abcd".utf8))
        let expect = "POST / HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 9\r\n\r\n"
        guard case .incomplete(true) = HTTP.parse(Data(expect.utf8)) else { return XCTFail("100-continue") }
        guard case .bad(411, _) = HTTP.parse(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) else { return XCTFail("chunked") }
        guard case .bad(413, _) = HTTP.parse(Data("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)) else { return XCTFail("size") }
        guard case .bad(400, _) = HTTP.parse(Data("garbage\r\n\r\n".utf8)) else { return XCTFail("request line") }
    }

    func testTokenCheckAndServeStatus() {
        XCTAssertTrue(Inbox.authorized("Bearer abc123", token: "abc123"))
        XCTAssertTrue(Inbox.authorized("bearer  abc123 ", token: "abc123"))
        XCTAssertFalse(Inbox.authorized("Bearer abc124", token: "abc123"))
        XCTAssertFalse(Inbox.authorized("Bearer abc", token: "abc123"))
        XCTAssertFalse(Inbox.authorized(nil, token: "abc123"))
        XCTAssertFalse(Inbox.authorized("Bearer ", token: ""))               // an empty token never opens the door
        XCTAssertEqual(Store.newToken().count, 64)

        let status = #"{"TCP":{"8443":{"HTTPS":true}},"Web":{"mac1.tail9.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8787"}}},"mac1.tail9.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}}}"#
        XCTAssertEqual(Inbox.httpsURL(serveStatus: status, target: "http://127.0.0.1:8787"), "https://mac1.tail9.ts.net:8443/pipeline-events")
        XCTAssertEqual(Inbox.httpsURL(serveStatus: status, target: "http://127.0.0.1:3000"), "https://mac1.tail9.ts.net/pipeline-events")
        XCTAssertNil(Inbox.httpsURL(serveStatus: "{}", target: "http://127.0.0.1:8787"))
        XCTAssertEqual(PipelineDocs.url("mac1.tail9.ts.net"), "https://mac1.tail9.ts.net:8443/pipeline-events")
    }

    func testJobsGroupPerServerAndFlagFailedAndSilentOnes() {
        let now = Date()
        func ev(_ job: String, _ src: String, _ status: String, ago: TimeInterval) -> PipelineEvent {
            PipelineEvent(jobId: job, at: now - ago, event: "stage", stage: "s", status: status, source: src, receivedAt: now - ago)
        }
        let events = [ev("ok", "a", "success", ago: 10), ev("1", "b", "running", ago: 20),   // newest first
                      ev("1", "a", "failed", ago: 60), ev("1", "a", "running", ago: 120),
                      ev("quiet", "a", "running", ago: 3600)]
        let jobs = PipelineJob.group(events, now: now)
        XCTAssertEqual(jobs.count, 4)                                            // job "1" on a ≠ job "1" on b
        XCTAssertEqual(jobs.prefix(2).map(\.latest.jobId), ["1", "quiet"])       // failed + silent first
        XCTAssertTrue(jobs[0].latest.failed)
        XCTAssertTrue(jobs[1].stale(now))
        XCTAssertFalse(jobs.first { $0.latest.source == "b" }!.stale(now))      // running, but heard from recently
        XCTAssertEqual(jobs[0].events.count, 2)
    }

    func testPipelinesClaimRunsTrackStagesAndSpotMissedRunDays() throws {
        XCTAssertEqual(PipelineGroup.stem("db-backup-20261006-0200-a1b2"), "db-backup")
        XCTAssertEqual(PipelineGroup.stem("s3_backup_2026-10-06T02:00"), "s3_backup")
        XCTAssertEqual(PipelineGroup.stem("42"), "")
        XCTAssertEqual(PipelineGroup.stem("nightly"), "nightly")

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let iso = ISO8601DateFormatter()
        func t(_ s: String) -> Date { iso.date(from: s)! }
        func run(_ id: String, _ src: String, _ at: String, _ stages: [(String, String)] = [("upload", "success")]) -> [PipelineEvent] {
            stages.enumerated().map { i, s in
                PipelineEvent(jobId: id, at: t(at) + Double(i), event: "stage", stage: s.0, status: s.1, source: src, receivedAt: t(at) + Double(i))
            }
        }
        let now = t("2026-10-07T12:00:00Z")   // a Wednesday
        let events = (run("db-backup-1004", "Box_One", "2026-10-04T02:00:00Z")
                      + run("db-backup-1007", "Box_One", "2026-10-07T02:00:00Z",
                            [("unzip", "running"), ("unzip", "success"), ("zip", "running"), ("zip", "failed")])
                      + run("other-1", "Box_One", "2026-10-06T02:00:00Z")
                      + run("db-backup-9", "elsewhere", "2026-10-06T02:00:00Z")).reversed()
        let jobs = PipelineJob.group(Array(events), now: now)

        let fresh = try XCTUnwrap(jobs.first { $0.latest.jobId == "db-backup-1007" })
        XCTAssertEqual(fresh.stages.map(\.stage), ["unzip", "zip"])             // first-seen order, latest status each
        XCTAssertEqual(fresh.stages.map(\.status), ["success", "failed"])
        let like = PipelineGroup(like: fresh)
        XCTAssertEqual([like.source, like.idContains, like.name], ["Box_One", "db-backup", "unzip → zip"])

        var g = PipelineGroup(name: "db → S3", source: "Box_One", idContains: "DB-BACKUP", days: [1, 3, 4],   // Sun Tue Wed
                              createdAt: t("2026-10-06T10:00:00Z"))
        let sorted = PipelineLane.sort(jobs, into: [g, PipelineGroup(name: "zzz", idContains: "backup")], now: now)
        let lane = sorted.lanes[0]
        XCTAssertEqual(lane.runs.map(\.latest.jobId), ["db-backup-1007", "db-backup-1004"])   // case-insensitive, newest first
        XCTAssertEqual(sorted.lanes[1].runs.map(\.latest.jobId), ["db-backup-9"])           // first matching pipeline by name wins
        XCTAssertEqual(sorted.loose.map(\.latest.jobId), ["other-1"])
        XCTAssertEqual(lane.missed(now, cal: cal), t("2026-10-06T00:00:00Z"))   // Tuesday came and went with no run
        XCTAssertTrue(lane.attention(now))
        XCTAssertEqual(lane.next(now, cal: cal), t("2026-10-11T00:00:00Z"))     // ran today (Wed) → next is Sunday
        XCTAssertEqual(lane.next(t("2026-10-06T12:00:00Z"), cal: cal), t("2026-10-06T00:00:00Z"))   // Tue, not run yet → today

        g.days = [1, 4]                                                         // no Tuesday → nothing missed
        XCTAssertNil(PipelineLane(group: g, runs: lane.runs).missed(now, cal: cal))
        g.days = [3]
        XCTAssertNil(PipelineLane(group: g, runs: []).missed(t("2026-10-06T12:00:00Z"), cal: cal))   // made today, no runs: not missed yet
        XCTAssertFalse(PipelineGroup(name: "all").valid)                        // never a catch-all by accident
        XCTAssertFalse(PipelineGroup(name: " ", source: "x").valid)
    }

    @MainActor func testUnseenCountSeenAndCap() throws {
        let store = Store(vaultKey: nil)
        XCTAssertEqual(store.pipelineToken.count, 64)
        let e = try PipelineEvent.decode(body(#"{"job_id":"j","timestamp":"2026-10-05T14:03:22Z","event":"x","status":"ok"}"#))
        store.receive(e, seen: false)
        store.receive(e, seen: false)
        XCTAssertEqual(store.unseenEvents, 2)
        store.markEventsSeen()
        XCTAssertEqual(store.unseenEvents, 0)
        store.receive(PipelineEvent.withNewId(e), seen: true)                   // arrived while you were looking
        XCTAssertEqual(store.unseenEvents, 0)
        var later = e
        later.receivedAt = Date() + 1                                           // arrives after you looked
        for _ in 0..<(DB.maxEvents + 5) { store.receive(later, seen: false) }
        XCTAssertEqual(store.events.count, DB.maxEvents)
        XCTAssertEqual(store.unseenEvents, DB.maxEvents)
        let old = store.pipelineToken
        store.rotatePipelineToken()
        XCTAssertNotEqual(store.pipelineToken, old)
    }

    @MainActor func testHandleChecksRouteMethodTokenAndAttributesTheSender() {
        let store = Store(vaultKey: nil)
        store.machines = [Machine(name: "Box_One", host: "100.70.1.2")]
        let inbox = store.inbox
        func req(_ b: String, method m: String = "POST", path p: String = "/pipeline-events", token: String? = nil, xff: String? = "100.70.1.2") -> HTTP.Request {
            var h = ["authorization": "Bearer " + (token ?? store.pipelineToken)]
            h["x-forwarded-for"] = xff
            return HTTP.Request(method: m, path: p, headers: h, body: Data(b.utf8))
        }
        let ok = #"{"job_id":"j1","timestamp":"2026-10-05T14:03:22Z","event":"job_failed","stage":"parse","status":"failed","source":"DESKTOP-X"}"#
        XCTAssertEqual(inbox.handle(req(ok, method: "GET")).0, 405)
        XCTAssertEqual(inbox.handle(req(ok, path: "/other")).0, 404)
        XCTAssertEqual(inbox.handle(req(ok, token: "nope")).0, 401)
        XCTAssertEqual(inbox.handle(req("{}")).0, 400)
        XCTAssertTrue(store.events.isEmpty)                                      // nothing refused gets stored
        XCTAssertEqual(inbox.handle(req(ok)).0, 202)
        XCTAssertEqual(store.events.first?.source, "Box_One")                // your name for that IP wins
        XCTAssertEqual(store.events.first?.machineId, store.machines[0].id)
        XCTAssertEqual(inbox.handle(req(ok, xff: nil)).0, 202)
        XCTAssertEqual(Inbox.sender(req(ok, xff: "100.70.9.9, 100.70.1.2")), "100.70.1.2")   // a client-sent hop can't pose as another machine
        XCTAssertEqual(store.events.first?.source, "DESKTOP-X")                 // unknown sender → payload's name
        XCTAssertEqual(store.unseenEvents, 2)
    }

    /// Real socket: bound to 127.0.0.1 only, and a curl POST with Expect: 100-continue (what Windows PowerShell 5.1 sends) lands.
    @MainActor func testListenerIsLoopbackOnlyAndAcceptsARealPost() async throws {
        let store = Store(vaultKey: nil)
        let inbox = Inbox(port: 0)
        inbox.store = store
        inbox.start()
        for _ in 0..<100 where inbox.listeningPort == nil { try await Task.sleep(for: .milliseconds(20)) }
        let port = try XCTUnwrap(inbox.listeningPort)

        let (_, lsof) = await Shell.run("/usr/sbin/lsof -nP -a -p \(ProcessInfo.processInfo.processIdentifier) -iTCP:\(port) -sTCP:LISTEN")
        XCTAssertTrue(lsof.contains("127.0.0.1:\(port)"), lsof)
        XCTAssertFalse(lsof.contains("*:\(port)"), lsof)

        let json = #"{"job_id":"curl-1","timestamp":"2026-10-05T14:03:22.1234567Z","event":"job_failed","stage":"setup","status":"failed","telemetry":{"trace":"boom"}}"#
        let (_, out) = await Shell.run("curl -sS -m 5 -w ' %{http_code}' -H 'Expect: 100-continue' -H 'Authorization: Bearer \(store.pipelineToken)' -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:\(port)/pipeline-events", input: Data(json.utf8))
        XCTAssertTrue(out.hasSuffix(" 202"), out)
        XCTAssertEqual(store.events.first?.jobId, "curl-1")
        XCTAssertTrue(store.events.first?.telemetry.contains("boom") ?? false)

        let (_, bad) = await Shell.run("curl -sS -m 5 -w ' %{http_code}' -H 'Authorization: Bearer wrong' --data-binary @- http://127.0.0.1:\(port)/pipeline-events", input: Data(json.utf8))
        XCTAssertTrue(bad.hasSuffix(" 401"), bad)
        XCTAssertEqual(store.events.count, 1)
        XCTAssertTrue(inbox.lastReject?.contains("401") ?? false)
    }

    func testClaudeStreamLines() {
        XCTAssertEqual(ClaudeStream.parse(#"{"type":"system","subtype":"init","session_id":"s1","apiKeySource":"none","tools":["Bash"]}"#),
                       [.started(auth: "subscription login", session: "s1")])
        XCTAssertEqual(ClaudeStream.parse(#"{"type":"system","subtype":"init","session_id":"s1","apiKeySource":"ANTHROPIC_API_KEY"}"#),
                       [.started(auth: "API key (ANTHROPIC_API_KEY)", session: "s1")])
        XCTAssertEqual(ClaudeStream.parse(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Checking disk."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ssh x -- 'df -h'","description":"disk"}}]}}"#),
                       [.step(.text, "Checking disk."), .step(.command, "ssh x -- 'df -h'")])
        XCTAssertEqual(ClaudeStream.parse(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"/dev/sda1 40%","is_error":false}]}}"#),
                       [.step(.output, "/dev/sda1 40%")])
        XCTAssertEqual(ClaudeStream.parse(#"{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"Permission denied"}],"is_error":true}]}}"#),
                       [.step(.error, "Permission denied")])
        XCTAssertEqual(ClaudeStream.parse(#"{"type":"result","subtype":"success","is_error":false,"result":"All good.","session_id":"s1"}"#),
                       [.result("All good.", isError: false, session: "s1")])
        XCTAssertEqual(ClaudeStream.parse("Error: not logged in"), [.step(.error, "Error: not logged in")])
        XCTAssertEqual(ClaudeStream.parse(#"{"type":"stream_event"}"#), [])
    }

    func testMarkdownBlocks() {
        let md = """
        ## Summary
        Both hosts are **up**.
        Disk is fine.

        - web-1: ok
          - `df -h` 40%
        2. restart done
        > note
        ---
        | Host | Disk |
        |------|-----:|
        | p1 | 40% |
        ```
        $ uptime
        ```
        ```
        still streaming
        """
        XCTAssertEqual(Markdown.blocks(md), [
            .heading(2, "Summary"),
            .paragraph("Both hosts are **up**.\nDisk is fine."),
            .item(marker: "•", text: "web-1: ok", indent: 0),
            .item(marker: "•", text: "`df -h` 40%", indent: 1),
            .item(marker: "2.", text: "restart done", indent: 0),
            .quote("note"),
            .rule,
            .table([["Host", "Disk"], ["p1", "40%"]]),
            .code("$ uptime"),
            .code("still streaming"),
        ])
    }

    func testClaudeRunIsLockedToTheTargetsSshLineAndYourLogin() {
        var m = Machine(name: "Box_One", host: "100.70.1.2")
        m.sshUser = "alice"
        m.os = "windows"
        let prefix = "ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=yes -o ControlPath=none -a alice@100.70.1.2 --"
        XCTAssertEqual(ClaudeCLI.prefix(m), prefix)
        XCTAssertEqual(ClaudeCLI.rule(m), "Bash(\(prefix) *)")
        XCTAssertEqual(ClaudeCLI.word("/Users/alice/.ssh/id_work"), "/Users/alice/.ssh/id_work")
        XCTAssertEqual(ClaudeCLI.word("a b"), "'a b'")
        XCTAssertEqual(ClaudeCLI.word("it's"), #"'it'\''s'"#)

        let a = ClaudeCLI.args([m], resume: "s1")
        XCTAssertEqual(a.first, "-p")
        for flag in [["--tools", "Bash"], ["--permission-mode", "dontAsk"], ["--setting-sources", "project"],
                     ["--output-format", "stream-json"], ["--resume", "s1"]] {
            let i = a.firstIndex(of: flag[0])
            XCTAssertNotNil(i, flag[0])
            if let i { XCTAssertEqual(a[i + 1], flag[1]) }
        }
        XCTAssertTrue(a.contains("--strict-mcp-config"))
        XCTAssertEqual(Array(a.suffix(2)), ["--allowedTools", ClaudeCLI.rule(m)])   // the only thing allowed, and last
        XCTAssertFalse(a.contains("--dangerously-skip-permissions"))
        XCTAssertTrue(ClaudeCLI.roster([m]).contains("Box_One (windows): \(prefix) '<command>'"))
        XCTAssertNil(ClaudeCLI.env["ANTHROPIC_API_KEY"])
        XCTAssertNil(ClaudeCLI.env["CLAUDECODE"])

        // model / effort / 1M context ride along; the lock (allowedTools last) doesn't move
        let opus = ClaudeCLI.args([m], resume: nil, config: AgentConfig(provider: .claude, model: "opus", effort: "high", bigContext: true))
        XCTAssertEqual(opus[opus.firstIndex(of: "--model")! + 1], "opus[1m]")
        XCTAssertEqual(opus[opus.firstIndex(of: "--effort")! + 1], "high")
        XCTAssertEqual(Array(opus.suffix(2)), ["--allowedTools", ClaudeCLI.rule(m)])
        XCTAssertFalse(ClaudeCLI.args([m], resume: nil).contains("--model"))
    }

    /// dontAsk alone still lets Claude Code's read-only commands run on this Mac; the hook denies everything but the ssh lines.
    func testClaudeHookDeniesEverythingButThePickedSshLines() throws {
        var m = Machine(name: "Box_One", host: "100.70.1.2")
        m.sshUser = "alice"
        let prefixes = try JSONDecoder().decode([String].self, from: Data(BashHook.env([m]).utf8))
        XCTAssertEqual(prefixes, [ClaudeCLI.prefix(m)])
        func ev(_ tool: String, _ cmd: String) -> Data {
            try! JSONSerialization.data(withJSONObject: ["hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": ["command": cmd]])
        }
        XCTAssertNil(BashHook.verdict(ev("Bash", "\(prefixes[0]) 'uptime'"), prefixes: prefixes))
        for (tool, cmd) in [("Bash", "cat ~/.ssh/id_ed25519"), ("Bash", "ls"), ("Bash", "\(prefixes[0]) 'x'; cat ~/.ssh/id_ed25519"),
                            ("Bash", "\(prefixes[0]) \"$(cat ~/.ssh/id_ed25519)\""), ("Read", "/etc/hosts")] {
            XCTAssertNotNil(BashHook.verdict(ev(tool, cmd), prefixes: prefixes), cmd)
        }
        XCTAssertNotNil(BashHook.verdict(ev("Bash", "\(prefixes[0]) 'uptime'"), prefixes: []))   // no prefixes → deny all
        XCTAssertNotNil(BashHook.verdict(Data("junk".utf8), prefixes: prefixes))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tnm-hook-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        XCTAssertTrue(BashHook.install(exe: "/Apps/Tailnet Manager.app/Contents/MacOS/TailnetManager", dir: dir))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dir + "/.claude/settings.json"))) as? [String: Any])
        let hook = try XCTUnwrap(((json["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])?.first)
        XCTAssertEqual(hook["matcher"] as? String, "*")
        XCTAssertEqual((hook["hooks"] as? [[String: Any]])?.first?["command"] as? String,
                       "'/Apps/Tailnet Manager.app/Contents/MacOS/TailnetManager' --bash-hook")
    }

    func testClineApprovesOnlyThePickedMachinesSshLine() {
        var m = Machine(name: "Box_One", host: "100.70.1.2")
        m.sshUser = "alice"
        let other = Machine(name: "Other", host: "100.70.9.9")
        let p = ClaudeCLI.prefix(m)
        for ok in ["\(p) 'uptime'", "\(p) 'df -h | tail -1; ls'", #"\#(p) 'it'\''s'"#] { XCTAssertTrue(ClineCLI.allowed(ok, [m]), ok) }
        for bad in ["\(p) 'uptime'; rm -rf ~", "\(p) 'a' 'b'", "\(p) $(id)", "\(p) uptime", "\(p) 'x' && ls", "\(p)  'x'",
                    "\(p) 'x'\n", "\(ClaudeCLI.prefix(other)) 'uptime'", "ssh evil 'uptime'", "cat ~/.ssh/id_ed25519", "\(p) \"x\""] {
            XCTAssertFalse(ClineCLI.allowed(bad, [m]), bad)
        }

        let e = ClineCLI.env(provider: "zai-coding-plan", key: "k", model: "glm-5.3")
        XCTAssertEqual(e["CLINE_API_KEY"], "k")
        XCTAssertEqual(e["CLINE_MODEL"], "glm-5.3")
        XCTAssertEqual(e["CLINE_NO_AUTO_UPDATE"], "1")
        XCTAssertEqual(e["CLINE_SESSION_BACKEND_MODE"], "local")
        XCTAssertNil(ClineCLI.env(provider: "zai", key: "k", model: "default")["CLINE_MODEL"])

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try? #"{"providers":{"cline":{"settings":{}},"zai-coding-plan":{"settings":{"apiKey":"zk"}}}}"#.write(to: dir, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClineCLI.login(dir.path)?.provider, "zai-coding-plan")
        XCTAssertEqual(ClineCLI.login(dir.path)?.key, "zk")
        XCTAssertNil(ClineCLI.login("/nonexistent"))
    }

    func testClineACPConversation() throws {
        var m = Machine(name: "Box_One", host: "100.70.1.2")
        m.sshUser = "alice"
        let p = ClaudeCLI.prefix(m)
        var sent: [[String: Any]] = []
        let acp = ClineACP(targets: [m], cwd: "/w", prompt: "check disk", resume: nil) { sent.append($0) }
        func line(_ o: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! }
        func update(_ u: [String: Any]) -> String { line(["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": "s1", "update": u]]) }
        func permission(_ id: Int, _ title: String, _ input: [String: Any]) -> String {
            line(["jsonrpc": "2.0", "id": id, "method": "session/request_permission",
                  "params": ["sessionId": "s1", "toolCall": ["toolCallId": "t\(id)", "title": title, "rawInput": input]]])
        }
        func optionId(_ msg: [String: Any]) -> String? { ((msg["result"] as? [String: Any])?["outcome"] as? [String: Any])?["optionId"] as? String }

        acp.begin()
        XCTAssertEqual(sent.last?["method"] as? String, "initialize")
        XCTAssertEqual(acp.receive("[acp] starting ACP mode over stdio…"), [])
        XCTAssertEqual(acp.receive(line(["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": 1]])), [])
        XCTAssertEqual(sent.last?["method"] as? String, "session/new")
        XCTAssertEqual(acp.receive(line(["jsonrpc": "2.0", "id": 2, "result": ["sessionId": "s1"]])), [.started(auth: "Cline sign-in (z.ai)", session: "s1")])
        let prompt = ((sent.last?["params"] as? [String: Any])?["prompt"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(prompt.contains("\(p) '<command>'") && prompt.hasSuffix("check disk"))

        XCTAssertEqual(acp.receive(update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Checking "]])), [])
        XCTAssertEqual(acp.receive(update(["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": "hmm"]])), [])
        XCTAssertEqual(acp.receive(update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "disk."]])), [])
        // the ssh line is approved…
        XCTAssertEqual(acp.receive(permission(7, "run_commands: ssh", ["commands": ["\(p) 'df -h'"]])), [.step(.text, "Checking disk."), .step(.command, "\(p) 'df -h'")])
        XCTAssertEqual(optionId(sent.last!), "allow_once")
        XCTAssertEqual(acp.receive(update(["sessionUpdate": "tool_call_update", "toolCallId": "t7", "status": "completed",
                                           "rawOutput": [["query": "x", "result": "40%\n", "success": true]]])), [.step(.output, "40%\n")])
        // …everything else is rejected, and its failure isn't echoed as output
        for (id, title, input) in [(8, "read_files: x", ["files": [["path": "/etc/hosts"]]]), (9, "run_commands: ls", ["commands": ["ls ~"]]),
                                   (10, "run_commands: mixed", ["commands": ["\(p) 'df'", "ls"]]), (11, "editor: x", ["commands": ["\(p) 'df'"]]),
                                   (12, "run_commands: extra", ["commands": ["\(p) 'df'"], "cwd": "/"])] as [(Int, String, [String: Any])] {
            XCTAssertEqual(acp.receive(permission(id, title, input)), [.step(.error, "blocked: \(title)")], title)
            XCTAssertEqual(optionId(sent.last!), "reject_once", title)
        }
        XCTAssertEqual(acp.receive(update(["sessionUpdate": "tool_call_update", "toolCallId": "t8", "status": "failed", "rawOutput": "rejected"])), [])
        // fs/terminal requests we never offered get an error, not silence
        XCTAssertEqual(acp.receive(line(["jsonrpc": "2.0", "id": 20, "method": "fs/read_text_file", "params": [:]])), [])
        XCTAssertNotNil(sent.last?["error"])

        XCTAssertEqual(acp.receive(update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "All good."]])), [])
        XCTAssertEqual(acp.receive(line(["jsonrpc": "2.0", "id": 3, "result": ["stopReason": "end_turn"]])),
                       [.step(.text, "All good."), .result("", isError: false, session: "s1")])

        // resume: session/load, and its history replay is ignored until it answers
        sent = []
        let again = ClineACP(targets: [m], cwd: "/w", prompt: "and memory?", resume: "s1") { sent.append($0) }
        again.begin()
        _ = again.receive(line(["jsonrpc": "2.0", "id": 1, "result": [:]]))
        XCTAssertEqual(sent.last?["method"] as? String, "session/load")
        XCTAssertEqual(again.receive(update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "old reply"]])), [])
        XCTAssertEqual(again.receive(line(["jsonrpc": "2.0", "id": 2, "result": [:]])), [.started(auth: "Cline sign-in (z.ai)", session: "s1")])
        XCTAssertEqual(((sent.last?["params"] as? [String: Any])?["prompt"] as? [[String: Any]])?.first?["text"] as? String, "and memory?")
        XCTAssertEqual(again.receive(line(["jsonrpc": "2.0", "id": 3, "error": ["code": -32000, "message": "Authentication required"]])),
                       [.result("Authentication required", isError: true, session: "s1")])
    }

    func testCodexRunHasNoShellOnlyTheSSHBridge() throws {
        var m = Machine(name: "Box_One", host: "100.70.1.2")
        m.sshUser = "alice"
        let a = CodexCLI.args([m], resume: nil, config: AgentConfig(provider: .codex, model: "gpt-5.4", effort: "xhigh"), exe: "/A B/TNM")
        XCTAssertEqual(Array(a.prefix(2)), ["exec", "--json"])
        XCTAssertEqual(a.last, "-")   // prompt on stdin
        for f in ["--ignore-user-config", "--ignore-rules", "--skip-git-repo-check"] { XCTAssertTrue(a.contains(f), f) }
        let disabled = Set(a.indices.filter { a[$0] == "--disable" }.map { a[$0 + 1] })
        XCTAssertTrue(disabled.isSuperset(of: ["shell_tool", "unified_exec", "multi_agent", "browser_use", "computer_use"]))
        let cfg = a.indices.filter { a[$0] == "-c" }.map { a[$0 + 1] }
        for c in [#"sandbox_mode="read-only""#, #"approval_policy="never""#, #"mcp_servers.tailnet.command="/A B/TNM""#,
                  #"model_reasoning_effort="xhigh""#] { XCTAssertTrue(cfg.contains(c), c) }
        XCTAssertFalse(a.contains { $0.contains("danger") })
        XCTAssertEqual(a[a.firstIndex(of: "-m")! + 1], "gpt-5.4")

        // the bridge gets exactly the same ssh line the Claude rule allows
        let mcp = try XCTUnwrap(cfg.first { $0.hasPrefix("mcp_servers.tailnet.args=") })
        let b64 = try XCTUnwrap(mcp.firstMatch(of: #/"--ssh-mcp", "([A-Za-z0-9+\/=]+)"/#)?.1)
        let targets = try JSONDecoder().decode([SSHBridge.Target].self, from: XCTUnwrap(Data(base64Encoded: String(b64))))
        XCTAssertEqual(targets, [SSHBridge.Target(name: "Box_One", argv: Remote.batch + m.sshArgs + ["--"])])
        XCTAssertEqual(targets[0].argv.map(ClaudeCLI.word).joined(separator: " "), ClaudeCLI.prefix(m))

        XCTAssertEqual(Array(CodexCLI.args([m], resume: "t1", config: AgentConfig(provider: .codex), exe: "x").prefix(3)), ["exec", "resume", "t1"])
        XCTAssertNil(CodexCLI.env["OPENAI_API_KEY"])
        XCTAssertTrue(CodexCLI.roster([m]).contains("- Box_One (OS unknown)"))
    }

    func testCodexStreamLines() {
        XCTAssertEqual(CodexStream.parse(#"{"type":"thread.started","thread_id":"t1"}"#), [.started(auth: "ChatGPT login", session: "t1")])
        XCTAssertEqual(CodexStream.parse(#"{"type":"item.started","item":{"id":"i1","type":"mcp_tool_call","server":"tailnet","tool":"ssh","arguments":{"machine":"p1","command":"df -h"},"status":"in_progress"}}"#),
                       [.step(.command, "p1 › df -h")])
        XCTAssertEqual(CodexStream.parse(#"{"type":"item.completed","item":{"id":"i1","type":"mcp_tool_call","server":"tailnet","tool":"ssh","arguments":{},"result":{"content":[{"type":"text","text":"40%"}]},"error":null,"status":"completed"}}"#),
                       [.step(.output, "40%")])
        XCTAssertEqual(CodexStream.parse(#"{"type":"item.completed","item":{"id":"i1","type":"mcp_tool_call","arguments":{},"result":null,"error":{"message":"timed out"},"status":"failed"}}"#),
                       [.step(.error, "timed out")])
        XCTAssertEqual(CodexStream.parse(#"{"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"All good."}}"#), [.step(.text, "All good.")])
        XCTAssertEqual(CodexStream.parse(#"{"type":"turn.completed","usage":{"input_tokens":1}}"#), [.result("", isError: false, session: "")])
        XCTAssertEqual(CodexStream.parse(#"{"type":"turn.failed","error":{"message":"sign in again"}}"#), [.result("sign in again", isError: true, session: "")])
        XCTAssertEqual(CodexStream.parse("2026-10-07T18:53:57.287779Z ERROR codex_login::auth::manager: Failed to refresh token"), [])
        XCTAssertEqual(CodexStream.parse("Error: unknown config key"), [.step(.error, "Error: unknown config key")])
        XCTAssertEqual(CodexStream.parse(#"{"type":"item.completed","item":{"type":"reasoning","text":"…"}}"#), [])
    }

    func testSSHBridgeRunsOnlyThePickedMachines() {
        let t = [SSHBridge.Target(name: "p1", argv: ["ssh", "p1", "--"])]
        var ran: [String] = []
        func call(_ req: [String: Any]) -> [String: Any]? { SSHBridge.handle(req, targets: t) { ran.append("\($0.name):\($1)"); return ("ok", true) } }
        func result(_ r: [String: Any]?) -> [String: Any] { r?["result"] as? [String: Any] ?? [:] }

        XCTAssertNil(call(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        XCTAssertEqual(result(call(["id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]]))["protocolVersion"] as? String, "2025-06-18")
        let tools = result(call(["id": 2, "method": "tools/list"]))["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.map { $0["name"] as? String }, ["ssh"])
        XCTAssertEqual(result(call(["id": 3, "method": "tools/call", "params": ["name": "ssh", "arguments": ["machine": "evil", "command": "id"]]]))["isError"] as? Bool, true)
        XCTAssertEqual(result(call(["id": 4, "method": "tools/call", "params": ["name": "bash", "arguments": ["machine": "p1", "command": "id"]]]))["isError"] as? Bool, true)
        XCTAssertEqual(ran, [])
        XCTAssertEqual(result(call(["id": 5, "method": "tools/call", "params": ["name": "ssh", "arguments": ["machine": "p1", "command": "uptime"]]]))["isError"] as? Bool, false)
        XCTAssertEqual(ran, ["p1:uptime"])
        XCTAssertNotNil(call(["id": 6, "method": "resources/list"])?["error"])

        // two machines called the same get told apart by host
        let twins = [Machine(name: "box", host: "10.0.0.1"), Machine(name: "box", host: "10.0.0.2")]
        XCTAssertEqual(SSHBridge.targets(twins).map(\.name), ["box@10.0.0.1", "box@10.0.0.2"])
        // and the real runner hands the command to ssh as ONE argument after "--" — no local shell ever sees it
        XCTAssertEqual(SSHBridge.run(SSHBridge.Target(name: "x", argv: ["/bin/echo", "--"]), "uptime; rm -rf ~").out, "-- uptime; rm -rf ~\n")
    }
}

extension PipelineEvent {
    static func withNewId(_ e: PipelineEvent) -> PipelineEvent { var x = e; x.id = UUID().uuidString; x.receivedAt = Date(); return x }
}
