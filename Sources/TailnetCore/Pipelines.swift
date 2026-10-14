import SwiftUI
import AppKit
import Network

// MARK: - Pipeline events: your servers POST job updates here; failures go red and bump the badge
// HTTPS: `tailscale serve` terminates TLS (real cert for this Mac's MagicDNS name, tailnet-only) and forwards to
// 127.0.0.1 — the app never listens on a network interface, so nothing on the LAN can even connect.
// ponytail: hand-rolled HTTP/1.1 behind that proxy — one request per connection, Content-Length bodies.

struct PipelineEvent: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var jobId: String
    var at: Date                 // the sender's timestamp
    var event: String
    var stage: String
    var status: String
    var source = ""              // your machine's name for the sender's IP, else the payload's "source", else the IP
    var machineId = ""           // set when the sender is one of your machines (Ask Claude targets it)
    var message = ""
    var telemetry = ""           // pretty JSON (or plain text), ≤ 4 KB
    var receivedAt = Date()
    // envelope v1 — optional, so events stored by older builds still decode (a required key would reset the vault)
    var service: String? = nil       // "nightly-backup" — the page's sections
    var resourceType: String? = nil  // "job", "deploy", … — sub-sections within a service
    var resourceId: String? = nil
    var eventId: String? = nil       // a replayed event with a known id is dropped

    static let failStatuses: Set = ["fail", "failed", "failure", "error", "errored", "crashed", "timeout", "timed_out"]
    static let runningStatuses: Set = ["started", "running", "in_progress"]
    static let okStatuses: Set = ["success", "succeeded", "ok", "done", "completed", "complete", "finished"]
    // ponytail: one threshold for every pipeline — long stages send a heartbeat (see Docs) instead of a per-job setting
    static let staleAfter: TimeInterval = 30 * 60

    var failed: Bool { Self.failStatuses.contains(status.lowercased()) || event.lowercased().contains("fail") }
    var running: Bool { !failed && Self.runningStatuses.contains(status.lowercased()) }
    var color: Color { failed ? .bad : running ? .accent : Self.okStatuses.contains(status.lowercased()) ? .ok : .dim }

    struct Bad: Error { let message: String }

    /// Wire format: {job_id, timestamp, event, stage, status} + optional source, message, telemetry — and the v1
    /// envelope {event_id, occurred_at, service, type, resource: {type, id}, data}, which stands in for
    /// job_id / timestamp / event / telemetry when those are missing.
    static func decode(_ body: Data, now: Date = Date()) throws -> PipelineEvent {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw Bad(message: "body must be a JSON object")
        }
        let res = o["resource"] as? [String: Any] ?? [:]
        func text(_ v: Any?, _ k: String, max: Int = 200) throws -> String {
            switch v {
            case let s as String: return String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
            case let n as NSNumber: return String(n.stringValue.prefix(max))   // numeric job ids
            case nil, is NSNull: return ""
            default: throw Bad(message: "\(k) must be a string")
            }
        }
        func either(_ a: String, _ b: String, _ v: Any?, _ w: Any?) throws -> String {
            let x = try text(v, a)
            let s = x.isEmpty ? try text(w, b) : x
            if s.isEmpty { throw Bad(message: "\(a) (or \(b)) is required") }
            return s
        }
        func opt(_ v: Any?, _ k: String) throws -> String? { let s = try text(v, k, max: 128); return s.isEmpty ? nil : s }
        guard let at = date(o["timestamp"] ?? o["occurred_at"]) else {
            throw Bad(message: "timestamp (or occurred_at) must be ISO-8601 (2026-10-05T14:03:22Z) or epoch seconds")
        }
        let status = try text(o["status"], "status")
        if status.isEmpty { throw Bad(message: "status is required") }
        var e = PipelineEvent(jobId: try either("job_id", "resource.id", o["job_id"], res["id"]), at: at,
                              event: try either("type", "event", o["type"], o["event"]),
                              stage: try text(o["stage"], "stage"), status: status)
        e.source = try text(o["source"], "source", max: 100)
        e.message = try text(o["message"], "message", max: 2000)
        e.service = try opt(o["service"], "service")
        e.resourceType = try opt(res["type"], "resource.type")
        e.resourceId = try opt(res["id"], "resource.id")
        e.eventId = try opt(o["event_id"], "event_id")
        e.receivedAt = now
        if let t = o["telemetry"] ?? o["data"], !(t is NSNull), !((t as? [String: Any])?.isEmpty ?? false) {
            let s = (t as? String) ?? (JSONSerialization.isValidJSONObject(t)
                ? (try? JSONSerialization.data(withJSONObject: t, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
                    .map { String(decoding: $0, as: UTF8.self) } ?? ""
                : "\(t)")
            e.telemetry = s.count > 4000 ? String(s.prefix(4000)) + "\n…(truncated)" : s
        }
        return e
    }

    private static let iso = ISO8601DateFormatter()
    private static let isoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// ISO-8601 with any fraction (Python sends 6 digits, .NET 7), "Z" or an offset; no zone = UTC.
    /// Numbers are epoch seconds (or milliseconds).
    static func date(_ v: Any?) -> Date? {
        if let n = v as? NSNumber {
            let s = n.doubleValue
            return Date(timeIntervalSince1970: s > 1e11 ? s / 1000 : s)
        }
        guard var s = (v as? String)?.trimmingCharacters(in: .whitespaces), s.count >= 19 else { return nil }
        if let sp = s.range(of: " ") { s.replaceSubrange(sp, with: "T") }   // Python's str(datetime)
        if !(s.hasSuffix("Z") || s.dropFirst(19).contains { $0 == "+" || $0 == "-" }) { s += "Z" }
        return isoFraction.date(from: s) ?? iso.date(from: s)
    }
}

/// Every event of one run on one server.
struct PipelineJob: Identifiable {
    let id: String                 // source + job_id — two servers may both count from 1
    let events: [PipelineEvent]    // newest first
    var latest: PipelineEvent { events[0] }

    var started: Date { events.last?.at ?? latest.at }
    var service: String? { events.lazy.compactMap(\.service).first }
    var kind: String? { events.reversed().lazy.compactMap(\.resourceType).first }   // what the run started as

    /// Went quiet mid-stage: the process likely died without reporting.
    func stale(_ now: Date) -> Bool { latest.running && now.timeIntervalSince(latest.receivedAt) > PipelineEvent.staleAfter }
    func attention(_ now: Date) -> Bool { latest.failed || stale(now) }
    func tint(_ now: Date) -> Color { stale(now) ? .accent : latest.color }
    func label(_ now: Date) -> String { stale(now) ? "STALE" : latest.status.uppercased() }

    /// Stages in the order they first showed up, each as its latest event — unzip ✓ → zip ✓ → upload ✗.
    var stages: [PipelineEvent] {
        var at: [String: Int] = [:], out: [PipelineEvent] = []
        for e in events.reversed() where !e.stage.isEmpty {   // oldest first
            if let i = at[e.stage] { out[i] = e } else { at[e.stage] = out.count; out.append(e) }
        }
        return out
    }

    /// Failed / gone-quiet jobs first, then most recently updated.
    static func group(_ events: [PipelineEvent], now: Date = Date()) -> [PipelineJob] {
        Dictionary(grouping: events) { $0.source + "\u{1F}" + $0.jobId }
            .map { PipelineJob(id: $0.key, events: $0.value.sorted { ($0.at, $0.receivedAt) > ($1.at, $1.receivedAt) }) }
            .sorted { ($0.attention(now) ? 0 : 1, $1.latest.receivedAt) < ($1.attention(now) ? 0 : 1, $0.latest.receivedAt) }
    }
}

/// A named pipeline you define: it claims every run whose sender and job_id match, so a scheduled job's runs
/// stack up in one place instead of one loose card per run.
struct PipelineGroup: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name = ""
    var source = ""            // "" = any sender
    var idContains = ""        // text every run's job_id shares; "" = every run from `source`
    var days: Set<Int> = []    // Calendar weekdays it runs on (1 = Sunday); empty = unscheduled
    var createdAt = Date()

    static let week = [2, 3, 4, 5, 6, 7, 1]   // Mon … Sun

    func matches(_ j: PipelineJob) -> Bool {
        (source.isEmpty || j.latest.source == source)
            && (idContains.isEmpty || j.latest.jobId.localizedCaseInsensitiveContains(idContains))
    }

    /// Named, and never a catch-all by accident.
    var valid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !(source.isEmpty && idContains.isEmpty) }

    var rule: String {
        [source.isEmpty ? "any sender" : source, idContains.isEmpty ? "" : "job_id contains “\(idContains)”"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var schedule: String {
        days.count == 7 ? "DAILY"
            : Self.week.filter(days.contains).map { Calendar.current.shortWeekdaySymbols[$0 - 1].uppercased() }.joined(separator: " · ")
    }

    /// "db-backup-20261006-0200-a1b2" → "db-backup": drops trailing parts with a digit in them (dates, times, run ids).
    static func stem(_ jobId: String) -> String {
        let sep: (Character) -> Bool = { "-_.: /".contains($0) }
        var s = Substring(jobId)
        while let last = s.split(whereSeparator: sep).last, last.contains(where: \.isNumber) {
            s = s[..<last.startIndex]
            while s.last.map(sep) == true { s.removeLast() }
        }
        return String(s)
    }
}

extension PipelineGroup {
    /// Prefilled from one run: its sender, its job_id minus the run-specific tail, its stages as the name.
    init(like j: PipelineJob) {
        let stem = Self.stem(j.latest.jobId)
        source = j.latest.source
        idContains = stem
        name = j.stages.isEmpty ? (stem.isEmpty ? j.latest.source : stem) : j.stages.map(\.stage).joined(separator: " → ")
    }
}

/// One pipeline and the runs it claimed.
struct PipelineLane: Identifiable {
    let group: PipelineGroup
    let runs: [PipelineJob]   // newest first
    var id: String { group.id }

    // ponytail: whole days in the Mac's time zone — a run that slips past midnight reads as missed; add a run time if that bites
    /// The last run day before today, if nothing started on it. Days before the pipeline existed (and before its
    /// first run) don't count.
    func missed(_ now: Date, cal: Calendar = .current) -> Date? {
        let today = cal.startOfDay(for: now)
        let since = cal.startOfDay(for: min(group.createdAt, runs.last?.started ?? .distantFuture))
        guard let d = (1...7).lazy.compactMap({ cal.date(byAdding: .day, value: -$0, to: today) })
                .first(where: { group.days.contains(cal.component(.weekday, from: $0)) }),
              d >= since else { return nil }
        return ran(on: d, cal) ? nil : d
    }

    /// Today if it's a run day and nothing has started yet, else the next run day.
    func next(_ now: Date, cal: Calendar = .current) -> Date? {
        let today = cal.startOfDay(for: now)
        return ((ran(on: today, cal) ? 1 : 0)...7).lazy.compactMap { cal.date(byAdding: .day, value: $0, to: today) }
            .first { group.days.contains(cal.component(.weekday, from: $0)) }
    }

    func attention(_ now: Date) -> Bool { runs.first?.attention(now) == true || missed(now) != nil }

    private func ran(on day: Date, _ cal: Calendar) -> Bool { runs.contains { cal.isDate($0.started, inSameDayAs: day) } }

    /// Each pipeline with its runs, plus the runs no pipeline claims. Pipelines needing attention first, then by name.
    // ponytail: a run two pipelines both match goes to the first by name
    static func sort(_ jobs: [PipelineJob], into groups: [PipelineGroup], now: Date) -> (lanes: [PipelineLane], loose: [PipelineJob]) {
        let groups = groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var claimed: [String: [PipelineJob]] = [:], loose: [PipelineJob] = []
        for j in jobs {
            if let g = groups.first(where: { $0.matches(j) }) { claimed[g.id, default: []].append(j) } else { loose.append(j) }
        }
        let lanes = groups.map { g in PipelineLane(group: g, runs: (claimed[g.id] ?? []).sorted { $0.started > $1.started }) }
        return (lanes.filter { $0.attention(now) } + lanes.filter { !$0.attention(now) }, loose)
    }
}

/// The Pipelines page's derived model. Grouping ~1000 events into runs, pipelines and sections took ~25 ms and ran on
/// every redraw; now it's computed off the main thread, once per burst of changes (≤ 5×/s), and the page just reads it.
@MainActor
final class PipelineBoard: ObservableObject {
    struct Snapshot {
        var jobs = 0
        var lanes: [PipelineLane] = []
        var loose: [PipelineJob] = []
        var sections: [PipelineSection] = []
        var at = Date()
    }

    @Published private(set) var snapshot = Snapshot()
    weak var store: Store?
    private var dirty = false, running = false

    /// Something changed — recompute after the burst lands. Changes during a recompute trigger one more.
    func schedule() {
        dirty = true
        guard !running else { return }
        running = true
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.dirty else { self?.running = false; return }
                self.dirty = false
                await self.recompute()
            }
        }
    }

    func recompute() async {
        guard let store else { return }
        let events = store.events, groups = store.pipelineGroups, now = Date()
        snapshot = await Task.detached(priority: .userInitiated) { Self.compute(events, groups, now) }.value
    }

    nonisolated static func compute(_ events: [PipelineEvent], _ groups: [PipelineGroup], _ now: Date) -> Snapshot {
        let jobs = PipelineJob.group(events, now: now)
        let sorted = PipelineLane.sort(jobs, into: groups, now: now)
        let sections = PipelineSection.build(sorted.lanes, sorted.loose, now: now)
        return Snapshot(jobs: jobs.count, lanes: sorted.lanes, loose: sorted.loose, sections: sections, at: now)
    }
}

extension Store {
    func savePipelineGroup(_ g: PipelineGroup) {
        var g = g
        g.name = g.name.trimmingCharacters(in: .whitespaces)
        g.idContains = g.idContains.trimmingCharacters(in: .whitespaces)
        if let i = pipelineGroups.firstIndex(where: { $0.id == g.id }) { pipelineGroups[i] = g } else { pipelineGroups.append(g) }
    }

    /// Runs are never deleted with it — they go back to the loose list.
    func deletePipelineGroup(_ id: String) { pipelineGroups.removeAll { $0.id == id } }
}

// MARK: - Minimal HTTP/1.1 request reader

enum HTTP {
    static let maxBody = 64 * 1024

    struct Request { var method: String; var path: String; var headers: [String: String]; var body: Data }
    enum Parse { case incomplete(expectsContinue: Bool), bad(Int, String), done(Request) }

    static func parse(_ buf: Data) -> Parse {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
            return buf.count > 8192 ? .bad(431, "headers too large") : .incomplete(expectsContinue: false)
        }
        let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let line = head[0].split(separator: " ")
        guard line.count == 3 else { return .bad(400, "malformed request line") }
        var headers: [String: String] = [:]
        for h in head.dropFirst() {
            guard let c = h.firstIndex(of: ":") else { continue }
            headers[h[..<c].trimmingCharacters(in: .whitespaces).lowercased()] = h[h.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .bad(411, "send Content-Length, not chunked") }
        guard let len = Int(headers["content-length"] ?? "0"), len >= 0 else { return .bad(400, "bad Content-Length") }
        guard len <= maxBody else { return .bad(413, "body over 64 KB") }
        let body = buf[end.upperBound...]
        guard body.count >= len else {
            return .incomplete(expectsContinue: headers["expect"]?.lowercased() == "100-continue")
        }
        return .done(Request(method: String(line[0]), path: String(line[1]), headers: headers, body: Data(body.prefix(len))))
    }

    static func reason(_ code: Int) -> String {
        [202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed",
         411: "Length Required", 413: "Payload Too Large", 431: "Request Header Fields Too Large"][code] ?? "Error"
    }
}

// MARK: - Listener: loopback only, published to the tailnet over HTTPS by tailscale serve

@MainActor
final class Inbox: ObservableObject {
    nonisolated static let defaultPort: UInt16 = 8787     // 127.0.0.1 only
    nonisolated static let httpsPort = 8443               // what your servers use: https://<mac>.<tailnet>.ts.net:8443
    nonisolated static let path = "/pipeline-events"
    let port: UInt16
    @Published private(set) var listeningPort: UInt16?
    @Published private(set) var httpsURL: String?      // nil = tailscale serve isn't forwarding to us (yet)
    @Published private(set) var problem: String?       // can't listen (port busy, …)
    @Published private(set) var lastReject: String?    // last refused request — the first thing to check when events don't show
    var visible = false                                // Pipelines page on screen
    weak var store: Store?
    private var listener: NWListener?

    init(port: UInt16 = Inbox.defaultPort) { self.port = port }

    var target: String { "http://127.0.0.1:\(port)" }

    /// Idempotent — the poll loop calls it every tick, so a busy port gets retried.
    func start() {
        guard listener == nil else { return }
        let l: NWListener
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        do { l = try NWListener(using: params) } catch {
            problem = "can't listen on :\(port) — \(error.localizedDescription)"
            return
        }
        l.newConnectionHandler = { [weak self] c in MainActor.assumeIsolated { self?.serve(c) } }
        l.stateUpdateHandler = { [weak self, weak l] s in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch s {
                case .ready:
                    self.listeningPort = l?.port?.rawValue
                    self.problem = nil
                case .failed(let e):
                    self.problem = "listener on :\(self.port) failed — \(e.localizedDescription)"
                    self.listeningPort = nil
                    l?.cancel()
                    self.listener = nil   // next start() retries
                default: break
                }
            }
        }
        l.start(queue: .main)
        listener = l
    }

    /// Is tailscale serve forwarding HTTPS to us? Local CLI call, no network — the poll loop runs it.
    func refreshHTTPS() async {
        guard let bin = Tailscale.bin else { httpsURL = nil; return }
        let (code, out) = await Shell.run("'\(bin)' serve status --json 2>/dev/null")
        httpsURL = code == 0 ? Self.httpsURL(serveStatus: out, target: target) : nil
    }

    /// One-time, persists across reboots (undo: `tailscale serve --https=8443 off`). In a terminal, because the
    /// first run may ask you to enable HTTPS certificates for the tailnet and waits until you have.
    func enableHTTPS() {
        guard let bin = Tailscale.bin else { problem = "Tailscale CLI not found"; return }
        Remote.terminal("\(Remote.q(bin)) serve --bg --https=\(Self.httpsPort) \(target)")
    }

    /// `tailscale serve status --json` → our public https URL, if a handler proxies to `target`.
    nonisolated static func httpsURL(serveStatus out: String, target: String) -> String? {
        guard let brace = out.firstIndex(of: "{"),
              let o = (try? JSONSerialization.jsonObject(with: Data(out[brace...].utf8))) as? [String: Any],
              let web = o["Web"] as? [String: Any] else { return nil }
        for (hostPort, v) in web.sorted(by: { $0.key < $1.key }) {
            let handlers = (v as? [String: Any])?["Handlers"] as? [String: Any] ?? [:]
            let ours = handlers.values.contains { (($0 as? [String: Any])?["Proxy"] as? String)?.hasPrefix(target) == true }
            if ours { return "https://" + (hostPort.hasSuffix(":443") ? String(hostPort.dropLast(4)) : hostPort) + path }
        }
        return nil
    }

    /// Constant-time — the token is the only secret between your servers and this Mac.
    nonisolated static func authorized(_ header: String?, token: String) -> Bool {
        guard let h = header, h.lowercased().hasPrefix("bearer "), !token.isEmpty else { return false }
        let a = Array(h.dropFirst(7).trimmingCharacters(in: .whitespaces).utf8), b = Array(token.utf8)
        return a.count == b.count && zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { c.cancel() }   // slow or stuck clients
        read(c, Data(), continued: false)
    }

    private func read(_ c: NWConnection, _ buf: Data, continued: Bool) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { return c.cancel() }
                let buf = buf + (data ?? Data())
                switch HTTP.parse(buf) {
                case .incomplete(let wantsContinue):
                    guard !done, error == nil else { return c.cancel() }
                    if wantsContinue && !continued {   // curl and Windows PowerShell wait for this before sending the body
                        c.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
                    }
                    self.read(c, buf, continued: continued || wantsContinue)
                case .bad(let code, let why):
                    self.reply(c, code, ["error": why], from: "?")
                case .done(let r):
                    let (code, body) = self.handle(r)
                    self.reply(c, code, body, from: Self.sender(r))
                }
            }
        }
    }

    /// The real client's tailnet IP — tailscale serve sets X-Forwarded-For (only local processes reach us directly).
    /// The last hop is the one the proxy added; earlier entries are whatever the client sent.
    nonisolated static func sender(_ r: HTTP.Request) -> String {
        r.headers["x-forwarded-for"]?.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "this mac"
    }

    func handle(_ r: HTTP.Request) -> (Int, [String: Any]) {
        guard r.path.split(separator: "?").first.map(String.init) == Self.path else { return (404, ["error": "POST \(Self.path)"]) }
        guard r.method == "POST" else { return (405, ["error": "POST only"]) }
        guard let store, Self.authorized(r.headers["authorization"], token: store.pipelineToken) else {
            return (401, ["error": "missing or wrong bearer token — copy it from Tailnet Manager → Docs"])
        }
        do {
            var e = try PipelineEvent.decode(r.body)
            let ip = Self.sender(r)
            let m = store.machine(ip: ip)
            e.machineId = m?.id ?? ""
            e.source = m.map { $0.name.isEmpty ? $0.host : $0.name } ?? (e.source.isEmpty ? store.peerName(ip: ip) ?? ip : e.source)
            let fresh = store.receive(e, seen: visible && NSApp?.isActive == true)
            return (202, fresh ? ["ok": true, "id": e.id] : ["ok": true, "duplicate": true])
        } catch {
            return (400, ["error": (error as? PipelineEvent.Bad)?.message ?? "invalid event"])
        }
    }

    private func reply(_ c: NWConnection, _ code: Int, _ body: [String: Any], from: String) {
        if code >= 400 { refused(from, "\(code) · \(body["error"] ?? "")") }
        let json = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let head = "HTTP/1.1 \(code) \(HTTP.reason(code))\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + json, completion: .contentProcessed { _ in c.cancel() })
    }

    private func refused(_ from: String, _ why: String) {
        lastReject = "\(Date().formatted(date: .omitted, time: .standard)) · \(from) · \(why)"
    }
}

// MARK: - Sidebar: red box with the number of updates you haven't seen

struct PipelinesSidebarLabel: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        let n = store.unseenEvents
        HStack {
            Label("Pipelines", systemImage: "waveform.path.ecg")
            Spacer()
            if n > 0 {
                Text(n > 99 ? "99+" : "\(n)").font(.mono(9).weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.bad, in: RoundedRectangle(cornerRadius: 3))
                    .help("\(n) pipeline update\(n == 1 ? "" : "s") since you last looked")
            }
        }
    }
}

// MARK: - Pipelines page

struct PipelinesView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var inbox: Inbox
    @EnvironmentObject private var board: PipelineBoard
    @State private var confirmClear = false
    @State private var editing: PipelineGroup?
    @State private var renaming: SectionRef?

    var body: some View {
        let snap = board.snapshot, now = snap.at   // computed off the main thread — see PipelineBoard
        let services = snap.sections.filter(\.isService), others = snap.sections.filter { !$0.isService }
        ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    readout(snap.lanes, snap.loose, now)
                    if snap.jobs == 0 && snap.sections.isEmpty {
                        Text("nothing yet — Docs has the snippet your servers POST with")
                            .font(.mono(11)).foregroundStyle(.dim)
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.panelDeep, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if !services.isEmpty {
                        group("PIPELINE SERVICES", "each service's events and runs · \(Image(systemName: "folder.badge.plus")) on a run makes a scheduled pipeline inside it", services, now)
                    }
                    if !others.isEmpty {
                        group("OTHER SENDERS · LAST \(DB.maxEvents) EVENTS · ENCRYPTED", "events that name no service, by the machine that sent them", others, now)
                    }
                }
                .padding(24)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .background(Color.bg)
        .navigationTitle("Pipelines")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { editing = PipelineGroup() } label: { Label("New pipeline", systemImage: "folder.badge.plus") }
                    .help("Group runs into a named pipeline with its run days")
                Button { confirmClear = true } label: { Label("Clear", systemImage: "trash") }
                    .disabled(store.events.isEmpty).help("Delete every stored pipeline event")
            }
        }
        .sheet(item: $editing) { PipelineGroupEditor(group: $0) }
        .sheet(item: $renaming) { SectionNameSheet(id: $0.id) }
        .task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)); board.schedule() } }   // STALE / MISSED age without new events
        .confirmationDialog("Delete all \(store.events.count) pipeline events?", isPresented: $confirmClear) {
            Button("Delete", role: .destructive) { store.clearEvents() }
        }
        .onAppear { inbox.visible = true; store.markEventsSeen() }
        .onDisappear { inbox.visible = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.markEventsSeen()
        }
    }

    func group(_ title: String, _ hint: LocalizedStringKey, _ sections: [PipelineSection], _ now: Date) -> some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            SectionLabel(t: title)
            Text(hint).font(.mono(10)).foregroundStyle(.tertiary)
            ForEach(sections) { s in
                ServiceSection(section: s, now: now, editPipeline: { editing = $0 }, rename: { renaming = SectionRef(id: s.id) })
            }
        }
    }

    /// Counts what's true now: each pipeline's latest run plus every loose run — an old failure that a newer
    /// run of the same pipeline has since fixed doesn't keep the page red.
    func readout(_ lanes: [PipelineLane], _ loose: [PipelineJob], _ now: Date) -> some View {
        let current = lanes.compactMap(\.runs.first) + loose
        let failed = current.filter(\.latest.failed).count
        let stale = current.filter { $0.stale(now) }.count
        let missed = lanes.filter { $0.missed(now) != nil }.count
        return HStack(alignment: .top, spacing: 32) {
            stat("PIPELINES", "\(lanes.count)")
            stat("RUNNING", "\(current.filter { $0.latest.running && !$0.stale(now) }.count)")
            stat("FAILED", "\(failed)", failed > 0 ? .bad : .primary)
            stat("STALE", "\(stale)", stale > 0 ? .accent : .primary)
            stat("MISSED", "\(missed)", missed > 0 ? .accent : .primary)
            stat("LAST EVENT", store.events.first.map { $0.receivedAt.formatted(.relative(presentation: .named)) } ?? "—")
            stat("INBOX", inbox.listeningPort == nil ? "✗ off" : inbox.httpsURL == nil ? "◐ no https" : "● https",
                 inbox.listeningPort == nil ? .bad : inbox.httpsURL == nil ? .accent : .ok)
            Spacer()
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) { Rectangle().fill(Color.accent).frame(width: 2) }
    }

    func stat(_ k: String, _ v: String, _ c: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(k).font(.mono(9)).foregroundStyle(.dim).tracking(2)
            Text(v).font(.mono(13)).foregroundStyle(c)
        }
    }
}

func statusPill(_ t: String, _ c: Color) -> some View {
    Text(t).font(.mono(9).weight(.bold)).tracking(1.5)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(c.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
        .foregroundStyle(c)
}

/// One pipeline: its rule and run days, a strip of recent runs, then the runs themselves (click the header to fold).
struct PipelineCard: View {
    @EnvironmentObject private var store: Store
    @AppStorage("collapsedPipelines") private var collapsedRaw = ""
    let lane: PipelineLane
    let now: Date
    let edit: () -> Void
    @State private var showAll = false

    var body: some View {
        let g = lane.group, last = lane.runs.first, missed = lane.missed(now)
        let open = !collapsedRaw.split(separator: " ").contains(Substring(g.id))
        let tint = missed != nil && last?.attention(now) != true ? Color.accent : last?.tint(now) ?? Color.dim
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.dim)
                    .rotationEffect(.degrees(open ? 90 : 0))
                Circle().fill(tint).frame(width: 8, height: 8).shadow(color: tint.opacity(0.6), radius: 3)
                Text(g.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(g.rule).font(.mono(10)).foregroundStyle(.dim).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let last {
                    statusPill(last.label(now), last.tint(now))
                    Text(last.latest.receivedAt.formatted(.relative(presentation: .named))).font(.mono(9)).foregroundStyle(.tertiary)
                }
                Menu {
                    Button("Edit pipeline…", action: edit)
                    Divider()
                    Button("Delete pipeline (keeps runs)", role: .destructive) { store.deletePipelineGroup(g.id) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle(g.id, open) }
            HStack(spacing: 14) {
                Label(g.days.isEmpty ? "no run days — Edit to set them" : g.schedule, systemImage: "calendar")
                    .foregroundStyle(g.days.isEmpty ? Color.dim : Color.primary)
                if let n = lane.next(now) { Text("next " + day(n)).foregroundStyle(.dim) }
                Text("\(lane.runs.count) run\(lane.runs.count == 1 ? "" : "s")").foregroundStyle(.dim)
                Spacer()
                history
            }
            .font(.mono(10))
            .padding(.leading, 20)
            if let missed {
                Text("✗ missed \(missed.formatted(.dateTime.weekday(.wide).month().day())) — no run started that day")
                    .font(.mono(10)).foregroundStyle(Color.accent).padding(.leading, 20)
            }
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    if lane.runs.isEmpty {
                        Text("no runs yet — waiting for \(g.rule)").font(.mono(10)).foregroundStyle(.tertiary)
                    }
                    ForEach(showAll ? lane.runs : Array(lane.runs.prefix(3))) { JobCard(job: $0, now: now, nested: true, showSource: g.source.isEmpty) }
                    if lane.runs.count > 3 {
                        Button(showAll ? "show the latest 3" : "show all \(lane.runs.count) runs") { showAll.toggle() }
                            .buttonStyle(.borderless).font(.mono(10))
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .background(Color.panelDeep, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(lane.attention(now) ? tint.opacity(0.5) : Color.ink.opacity(0.07)))
    }

    /// Last 20 runs, oldest → newest: how this pipeline has been doing, at a glance.
    var history: some View {
        HStack(spacing: 2) {
            ForEach(Array(lane.runs.prefix(20).reversed())) { r in
                RoundedRectangle(cornerRadius: 1.5).fill(r.tint(now)).frame(width: 5, height: 14)
                    .help("\(r.started.formatted(date: .abbreviated, time: .shortened)) · \(r.label(now)) · \(r.latest.jobId)")
            }
        }
    }

    func day(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? "today" : Calendar.current.isDateInTomorrow(d) ? "tomorrow" : d.formatted(.dateTime.weekday(.wide))
    }

    func toggle(_ id: String, _ open: Bool) {
        var c = Set(collapsedRaw.split(separator: " ").map(String.init))
        if open { c.insert(id) } else { c.remove(id) }
        collapsedRaw = c.sorted().joined(separator: " ")
    }
}

struct JobCard: View {
    @EnvironmentObject private var claude: Orchestrator   // not the Store: hundreds of cards observing it redrew on every event
    let job: PipelineJob
    let now: Date
    var nested = false                          // inside a pipeline card
    var showSource = true                       // off when the pipeline already names the sender
    var group: ((PipelineJob) -> Void)? = nil   // loose runs: make a pipeline from this one
    @State private var open = false

    static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    var body: some View {
        let e = job.latest
        let stale = job.stale(now)
        let tint = job.tint(now)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(tint).frame(width: 7, height: 7).shadow(color: tint.opacity(0.6), radius: 3)
                Text(e.jobId).font(.mono(12).weight(.semibold)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if showSource { Text(e.source).font(.mono(10)).foregroundStyle(.dim).lineLimit(1) }
                Spacer()
                if let group {
                    Button { group(job) } label: { Image(systemName: "folder.badge.plus") }
                        .buttonStyle(.borderless).help("Make a pipeline from this run — every run like it goes there")
                }
                statusPill(job.label(now), tint)
                Text(e.receivedAt.formatted(.relative(presentation: .named))).font(.mono(9)).foregroundStyle(.tertiary)
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 9)).foregroundStyle(.dim)
            }
            .contentShape(Rectangle())
            .onTapGesture { open.toggle() }
            if !job.stages.isEmpty { stages(stale) }
            if !e.message.isEmpty {
                Text(e.message).font(.mono(10)).foregroundStyle(e.failed ? Color.bad : Color.dim)
                    .lineLimit(open ? nil : 2).textSelection(.enabled)
            }
            if stale {
                Text("no update for \(duration(Int(now.timeIntervalSince(e.receivedAt)))) while \(e.status) — it may have died without reporting")
                    .font(.mono(9)).foregroundStyle(Color.accent)
            }
            if open { details }
        }
        .padding(nested ? 12 : 14)
        .background(nested ? Color.bg : Color.panelDeep, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(job.attention(now) ? tint.opacity(0.5) : Color.ink.opacity(0.07)))
    }

    /// unzip → zip → upload, each tinted by how it went, then how long the run took (so far).
    func stages(_ stale: Bool) -> some View {
        let secs = Int(job.latest.at.timeIntervalSince(job.started))
        return HStack(spacing: 5) {
            ForEach(Array(job.stages.enumerated()), id: \.element.id) { i, s in
                if i > 0 { Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).foregroundStyle(.tertiary) }
                let c = stale && s.running ? Color.accent : s.color
                Text(s.stage).font(.mono(10)).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(c.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(c)
                    .help("\(s.stage): \(s.status) · \(Self.timeFmt.string(from: s.at))")
            }
            if secs > 0 {
                Text(duration(secs)).font(.mono(9)).foregroundStyle(.tertiary).padding(.leading, 6)
                    .help("first event → latest event")
            }
        }
    }

    var telemetry: String { job.events.first { !$0.telemetry.isEmpty }?.telemetry ?? "" }

    @ViewBuilder var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(job.events.prefix(40)) { x in
                HStack(spacing: 10) {
                    Text(Self.timeFmt.string(from: x.at)).font(.mono(9)).foregroundStyle(.tertiary)
                    Text(x.event).font(.mono(10)).frame(width: 130, alignment: .leading).lineLimit(1)
                    Text(x.stage).font(.mono(10)).foregroundStyle(.dim).frame(width: 100, alignment: .leading).lineLimit(1)
                    Text(x.status).font(.mono(10)).foregroundStyle(x.color).frame(width: 80, alignment: .leading)
                    Text(x.message).font(.mono(9)).foregroundStyle(.dim).lineLimit(1).truncationMode(.tail)
                }
            }
        }
        if !telemetry.isEmpty {
            Text(telemetry).font(.mono(9)).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.bg, in: RoundedRectangle(cornerRadius: 6))
        }
        if job.attention(now) {
            Button { ask() } label: { Label("Ask Claude…", systemImage: "sparkles") }
                .controlSize(.small)
                .help("Prefill an Orchestrate task to investigate this on the machine that sent it")
        }
    }

    func ask() {
        let e = job.latest
        claude.draft = """
        Pipeline job \(e.jobId) on \(e.source) \(job.stale(now) ? "went quiet while \(e.status)" : "failed") \
        at stage "\(e.stage)" (event \(e.event), \(e.at.formatted())).
        \(e.message.isEmpty ? "" : "Message: \(e.message)\n")\(telemetry.isEmpty ? "" : "Telemetry:\n\(telemetry)\n")
        Find out why on that machine: the process, its recent logs, disk and memory. Read-only — change nothing yet. \
        Report the likely cause and the fix you'd make.
        """
        if !e.machineId.isEmpty { claude.picked = [e.machineId] }
        claude.store?.selection = .orchestrate
    }
}

/// New / edit a pipeline: its name, which runs it claims, the days it runs on — with a live count of what it matches.
struct PipelineGroupEditor: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var group: PipelineGroup

    var body: some View {
        let jobs = PipelineJob.group(store.events)
        let matched = jobs.filter(group.matches)
        let sources = Set(store.events.map(\.source) + [group.source]).subtracting([""]).sorted()
        VStack(alignment: .leading, spacing: 12) {
            Text(store.pipelineGroups.contains { $0.id == group.id } ? "EDIT PIPELINE" : "NEW PIPELINE")
                .font(.mono(11)).foregroundStyle(.dim).tracking(2)
            row("NAME") { TextField("e.g. unzip → db → S3", text: $group.name) }
            row("FROM") {
                Picker("", selection: $group.source) {
                    Text("any sender").tag("")
                    ForEach(sources, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
            row("JOB ID HAS") { TextField("text every run's job_id shares, e.g. db-backup", text: $group.idContains) }
            row("RUNS ON") {
                HStack(spacing: 4) {
                    ForEach(PipelineGroup.week, id: \.self) { d in
                        Toggle(Calendar.current.shortWeekdaySymbols[d - 1], isOn: Binding(
                            get: { group.days.contains(d) },
                            set: { if $0 { group.days.insert(d) } else { group.days.remove(d) } }))
                    }
                }
                .toggleStyle(.button)
            }
            Text("a run day that passes with no run shows MISSED · leave all off if it isn't scheduled")
                .font(.mono(9)).foregroundStyle(.tertiary).padding(.leading, 104)
            Group {
                if group.source.isEmpty && group.idContains.isEmpty {
                    Text("pick a sender or a job_id text — a pipeline can't claim every run").foregroundStyle(Color.accent)
                } else {
                    Text("matches \(matched.count) of \(jobs.count) runs"
                         + (matched.max { $0.started < $1.started }.map { " — newest: \($0.latest.jobId)" } ?? ""))
                        .foregroundStyle(.dim)
                }
            }
            .font(.mono(10)).lineLimit(2)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.bg, in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { store.savePipelineGroup(group); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(!group.valid)
            }
        }
        .padding(20).frame(width: 560)
        .preferredColorScheme(Theme.current.scheme)
    }

    func row<C: View>(_ k: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 8) {
            Text(k).font(.mono(9)).foregroundStyle(.dim).tracking(1).frame(width: 96, alignment: .leading)
            c().textFieldStyle(.roundedBorder).font(.mono(11))
        }
    }
}

// MARK: - Docs: copy-paste instructions for adding the webhook to another server

enum PipelineDocs {
    /// The cert is for the MagicDNS name, so that's what servers must call — not the 100.x IP.
    static func url(_ dnsName: String?) -> String {
        "https://\(dnsName ?? "<this-mac>.<tailnet>.ts.net"):\(Inbox.httpsPort)\(Inbox.path)"
    }

    static let fields = """
    job_id     required  string/number — the same for every event of one run; start it with the pipeline's name (db-backup-20261006-0200) so runs group
    timestamp  required  ISO-8601 UTC (2026-10-05T14:03:22Z) or epoch seconds
    event      required  job_started · stage_started · stage_finished · heartbeat · job_finished · job_failed
    stage      optional  extract, parse, upload… ("" for job-level events)
    status     required  running · success · failed · skipped   (failed / error / timeout → red)
    source     optional  sender name (your machine name for the sender's IP wins)
    message    optional  one human line, ≤ 2000 chars — the error on failure
    telemetry  optional  any JSON, first 4 KB kept — traceback tail, counts, durations
    — envelope v1 (optional; fills in job_id / timestamp / event / telemetry when those are missing) —
    service    the page's section, e.g. "nightly-backup"
    type       job.started · job.stage_finished · job.failed · …   (preferred over event)
    resource   {"type": "job" | "deploy" | …, "id": "<id>"} — sub-section + grouping when job_id is absent
    event_id   uuid — a replay with a known id is dropped (still 202)
    occurred_at  RFC 3339 UTC · data  any JSON (shown like telemetry)
    """

    static let payload = """
    {
      "job_id": "export-2026-10-05-0042",
      "timestamp": "2026-10-05T14:03:22Z",
      "event": "stage_finished",
      "stage": "extract",
      "status": "success",
      "message": "18,234 rows",
      "telemetry": { "rows": 18234, "duration_s": 41.2 }
    }
    """

    static func env(_ url: String) -> (unix: String, windows: String) {
        ("""
         # shell profile, or the service's environment (systemd: Environment=TNM_URL=…)
         export TNM_URL="\(url)"
         export TNM_TOKEN="<paste token>"
         """,
         """
         :: user-level; add /M for services that run as SYSTEM. Restart the process afterwards.
         setx TNM_URL "\(url)"
         setx TNM_TOKEN "<paste token>"
         """)
    }

    static let python = """
    import json, os, socket, urllib.request
    from datetime import datetime, timezone

    def tnm_notify(job_id, event, stage, status, message="", telemetry=None):
        \"\"\"Push one update to Tailnet Manager. Never raises; gives up after 5 s.\"\"\"
        try:
            body = {"job_id": str(job_id), "timestamp": datetime.now(timezone.utc).isoformat(),
                    "event": event, "stage": stage, "status": status, "source": socket.gethostname()}
            if message:
                body["message"] = str(message)[:2000]
            if telemetry is not None:
                body["telemetry"] = telemetry
            req = urllib.request.Request(os.environ["TNM_URL"], data=json.dumps(body, default=str).encode(),
                                         headers={"Authorization": "Bearer " + os.environ["TNM_TOKEN"],
                                                  "Content-Type": "application/json"})
            urllib.request.urlopen(req, timeout=5).close()  # verifies the TLS cert — never disable that
        except Exception as e:
            print(f"tnm_notify skipped: {e}")
    """

    static let pythonUsage = """
    import traceback
    tnm_notify(job, "job_started", "", "running")
    stage = ""
    try:
        for stage in ("extract", "parse", "upload"):
            tnm_notify(job, "stage_started", stage, "running")
            run_stage(stage)
            tnm_notify(job, "stage_finished", stage, "success")
        tnm_notify(job, "job_finished", "", "success")
    except Exception as e:
        tnm_notify(job, "job_failed", stage, "failed", message=repr(e),
                   telemetry={"traceback": traceback.format_exc()[-3000:]})
        raise
    """

    static let powershell = """
    function Send-TnmEvent {
        param([string]$JobId, [string]$EventName, [string]$Stage = "", [string]$Status,
              [string]$Message = "", $Telemetry = $null)
        try {
            # Windows PowerShell 5.1 on older builds doesn't offer TLS 1.2 by default
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $body = @{ job_id = $JobId; timestamp = (Get-Date).ToUniversalTime().ToString("o")
                       event = $EventName; stage = $Stage; status = $Status; source = $env:COMPUTERNAME }
            if ($Message) { $body.message = $Message }
            if ($null -ne $Telemetry) { $body.telemetry = $Telemetry }
            $json = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 8 -Compress))
            Invoke-RestMethod -Method Post -Uri $env:TNM_URL -TimeoutSec 5 -Body $json `
                -ContentType "application/json; charset=utf-8" -Headers @{ Authorization = "Bearer $env:TNM_TOKEN" } | Out-Null
        } catch { Write-Warning "Send-TnmEvent skipped: $_" }
    }
    # Send-TnmEvent -JobId $job -EventName job_failed -Stage parse -Status failed -Message $_.Exception.Message `
    #               -Telemetry @{ trace = $_.ScriptStackTrace }
    """

    static let curl = """
    curl -sS -X POST "$TNM_URL" -H "Authorization: Bearer $TNM_TOKEN" -H "Content-Type: application/json" \\
      -d "{\\"job_id\\":\\"test-1\\",\\"timestamp\\":\\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\\",\\"event\\":\\"job_failed\\",\\"stage\\":\\"setup\\",\\"status\\":\\"failed\\",\\"message\\":\\"hello from $(hostname)\\"}"
    """

    static let replies = "202 landed · 400 bad payload (the reply names the field) · 401 wrong token · 502 app not running · timeout = Mac asleep or not on the tailnet · TLS error = calling the IP instead of the ts.net name"

    /// Paste into the Claude session on that server. No token in it — that goes in the env var.
    static func handoff(_ url: String) -> String {
        let e = env(url)
        return """
        # Add Tailnet Manager pipeline webhooks to this server

        Push this server's job updates to the Tailnet Manager app on my Mac, so I don't have to watch it. \
        Failed jobs show up red there with whatever telemetry you send.

        ## Contract
        POST \(url)   (HTTPS, tailnet only — Tailscale's own cert; use this name, not the 100.x IP)
        Headers: `Authorization: Bearer $TNM_TOKEN`, `Content-Type: application/json`
        Read the URL and token from env vars TNM_URL / TNM_TOKEN — never hard-code or commit the token.

        ```
        \(fields)
        ```

        Example: `\(payload.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: ""))`
        Replies: \(replies).

        ## What to do
        - Send job_started → stage_started / stage_finished per stage → job_finished. On any exception send job_failed \
        with status "failed", the error in `message`, and the traceback tail plus context (input, counts, durations) in `telemetry`.
        - Wrap the top-level entry point so even an unexpected crash sends job_failed.
        - Stages that can run > 10 min: send a `heartbeat` (status "running") every few minutes — a running job \
        that goes quiet for 30 min is flagged STALE.
        - Fire-and-forget: 5 s timeout, swallow every error. Never slow down or fail a job because the Mac is asleep.
        - Keep TLS verification on (no verify=False / -SkipCertificateCheck) — the cert is a real one.
        - No secrets or personal data in message / telemetry.

        ## Env vars
        ```sh
        \(e.unix)
        ```
        ```bat
        \(e.windows)
        ```

        ## Sender — Python (stdlib)
        ```python
        \(python)
        ```
        ```python
        \(pythonUsage)
        ```

        ## Sender — PowerShell
        ```powershell
        \(powershell)
        ```

        ## Test
        ```sh
        \(curl)
        ```

        Then tell me the job_id format, the stage names, and what goes into telemetry.
        """
    }
}

/// This Mac only (no Universal Clipboard) and marked concealed, so clipboard managers skip it — a snippet may be a .env.
func copyString(_ s: String) {
    let pb = NSPasteboard.general
    pb.prepareForNewContents(with: .currentHostOnly)
    pb.setString(s, forType: .string)
    pb.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
}

struct DocsView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var inbox: Inbox
    @State private var copiedHandoff = false
    @State private var tokenNote: String?
    @State private var confirmRotate = false

    var url: String { inbox.httpsURL ?? PipelineDocs.url(store.me?.dnsName) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pipeline webhook").font(.system(size: 22, weight: .bold))
                    Text("Any server on your tailnet can push job updates to this Mac over HTTPS. Failures go red, and everything you haven't seen counts up on the Pipelines badge and the Dock icon.")
                        .font(.mono(11)).foregroundStyle(.dim).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button { copyString(PipelineDocs.handoff(url)); copiedHandoff = true } label: {
                            Label(copiedHandoff ? "Copied" : "Copy handoff for that server's Claude", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.borderedProminent).tint(Color.accent)
                        Text("markdown brief: contract, rules, snippets — no token").font(.mono(9)).foregroundStyle(.tertiary)
                    }
                }
                section("ENDPOINT") { endpoint }
                section("1 · SET TWO ENV VARS ON THE SERVER") {
                    let e = PipelineDocs.env(url)
                    CodeBlock(title: "LINUX / MACOS", code: e.unix)
                    CodeBlock(title: "WINDOWS", code: e.windows)
                }
                section("2 · DROP IN THE SENDER") {
                    CodeBlock(title: "PYTHON · STDLIB ONLY", code: PipelineDocs.python)
                    CodeBlock(title: "POWERSHELL", code: PipelineDocs.powershell)
                }
                section("3 · CALL IT AT EVERY STEP — AND ON FAILURE") {
                    CodeBlock(title: "PYTHON", code: PipelineDocs.pythonUsage)
                    Text("stages that run > 10 min: send a heartbeat (status running) every few minutes — a running job silent for 30 min shows STALE")
                        .font(.mono(9)).foregroundStyle(.tertiary)
                }
                section("4 · TEST") {
                    CodeBlock(title: "CURL", code: PipelineDocs.curl)
                    Text(PipelineDocs.replies).font(.mono(9)).foregroundStyle(.tertiary)
                }
                section("PAYLOAD") {
                    CodeBlock(title: "JSON", code: PipelineDocs.payload)
                    CodeBlock(title: "FIELDS", code: PipelineDocs.fields)
                }
            }
            .padding(28)
            .frame(maxWidth: 940, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.bg)
        .navigationTitle("Docs")
        .task { await inbox.refreshHTTPS() }
        .confirmationDialog("Rotate the webhook token?", isPresented: $confirmRotate) {
            Button("Rotate", role: .destructive) { store.rotatePipelineToken(); tokenNote = "rotated — update TNM_TOKEN on every server" }
        } message: { Text("Every server using the current token gets 401 until you update it.") }
    }

    func section<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { SectionLabel(t: t); c() }
    }

    var endpoint: some View {
        VStack(alignment: .leading, spacing: 9) {
            row("URL") {
                Text(url).font(.mono(11)).textSelection(.enabled)
                Button { copyString(url) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy")
            }
            row("HTTPS") {
                if inbox.httpsURL != nil {
                    Text("● published by tailscale serve — Tailscale's cert, tailnet only").font(.mono(10)).foregroundStyle(Color.ok)
                } else {
                    Text("✗ not published yet").font(.mono(10)).foregroundStyle(Color.bad)
                    Button("Enable HTTPS…") { inbox.enableHTTPS() }.controlSize(.small)
                        .help("Runs `tailscale serve --bg --https=\(Inbox.httpsPort) \(inbox.target)` in a terminal — once; it persists")
                }
            }
            row("TOKEN") {
                Text("••••••••" + store.pipelineToken.suffix(4)).font(.mono(11))
                Button("Copy") { Task { await copyToken() } }.controlSize(.small)
                    .help("Touch ID, then on the clipboard for \(Int(SecretPasteboard.clearAfter)) s — this Mac only")
                Button("Rotate…") { confirmRotate = true }.controlSize(.small)
                if let tokenNote { Text(tokenNote).font(.mono(9)).foregroundStyle(.dim) }
            }
            row("LOCAL") {
                if let p = inbox.listeningPort {
                    Text("● 127.0.0.1:\(p) — loopback only; tailscale serve forwards to it").font(.mono(10)).foregroundStyle(Color.ok)
                } else {
                    Text(inbox.problem ?? "starting…").font(.mono(10)).foregroundStyle(Color.bad)
                }
            }
            if let r = inbox.lastReject {
                row("LAST REFUSED") { Text(r).font(.mono(10)).foregroundStyle(Color.accent).textSelection(.enabled) }
            }
        }
    }

    func row<C: View>(_ k: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(k).font(.mono(9)).foregroundStyle(.dim).tracking(1).frame(width: 96, alignment: .leading)
            c()
        }
    }

    func copyToken() async {
        guard await Gate.unlock("copy the pipeline webhook token") else { tokenNote = "not unlocked"; return }
        SecretPasteboard.copy(Array(store.pipelineToken.utf8))
        tokenNote = "copied — clears in \(Int(SecretPasteboard.clearAfter)) s"
    }
}

struct CodeBlock: View {
    let title: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.mono(9)).foregroundStyle(.dim).tracking(1.5)
                Spacer()
                Button(copied ? "Copied" : "Copy") { copyString(code); copied = true }.controlSize(.small)
            }
            Text(code).font(.mono(10)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.bg, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.ink.opacity(0.06)))
        }
    }
}
