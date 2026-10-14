import SwiftUI
import AppKit

// MARK: - Cloud transfers: rclone / gcloud storage / gsutil, found by scanning ps on this Mac + your machines
// ponytail: process scan, not a job runner — catches transfers started anywhere (tmux, cron, Ghostty, our tabs).
// Exit status of a vanished process is unknowable from outside; rclone --rc gives real progress while it runs.

struct RcloneStats: Codable, Hashable {
    var bytes: Int64?
    var totalBytes: Int64?
    var speed: Double?
    var eta: Double?
    var errors: Int?
    var transfers: Int?
    var totalTransfers: Int?
    var fraction: Double? {
        guard let b = bytes, let t = totalBytes, t > 0 else { return nil }
        return min(1, Double(b) / Double(t))
    }
}

struct Transfer: Identifiable, Hashable {
    var machineId: String
    var machineName: String
    var pid: Int
    var ppid: Int
    var elapsed: Int          // seconds
    var sent: Int64?          // /proc/<pid>/io wchar — bytes pushed to sockets ≈ uploaded (Linux only)
    var recv: Int64?          // rchar
    var args: String
    var rate: Double? = nil   // bytes/s between scans
    var stats: RcloneStats? = nil
    var id: String { "\(machineId):\(pid)" }

    struct Parsed: Hashable { var tool = "?", op = "", src = "", dst = "" }
    var parsed: Parsed { Self.parse(args) }
    var speed: Double? { stats?.speed ?? rate }

    /// "rclone -P sync /a gcs:b --transfers 8" → rclone · sync · /a → gcs:b
    // ponytail: heuristic argv read — a path-valued flag between src and dst (rare) can fool it
    static func parse(_ args: String) -> Parsed {
        let t = args.split(separator: " ").map(String.init)
        guard let i = t.firstIndex(where: {
            let b = ($0 as NSString).lastPathComponent
            return b == "rclone" || b == "gsutil" || b.hasPrefix("gcloud")
        }) else { return Parsed() }
        let b = (t[i] as NSString).lastPathComponent
        let tool = b == "rclone" ? "rclone" : b == "gsutil" ? "gsutil" : "gcloud"
        let ops: Set<String> = tool == "rclone" ? ["copy", "copyto", "sync", "move", "moveto", "bisync"] : ["cp", "rsync", "mv"]
        let rest = Array(t[(i + 1)...])
        guard let o = rest.firstIndex(where: { ops.contains($0) }) else { return Parsed(tool: tool) }
        let sizeLike = #/^\d+[kKMGTP]?i?B?$/#
        let pos = rest[(o + 1)...].filter { !$0.hasPrefix("-") && $0.wholeMatch(of: sizeLike) == nil }
        let dst = tool == "rclone" ? (pos.count > 1 ? pos[pos.startIndex + 1] : "") : (pos.count > 1 ? pos.last! : "")
        return Parsed(tool: tool, op: rest[o], src: pos.first ?? "", dst: dst)
    }

    /// ps etime "[[dd-]hh:]mm:ss" → seconds. Clamped: a remote ps can print anything, and an overflow would trap.
    static func seconds(_ etime: String) -> Int {
        let d = etime.split(separator: "-")
        let days = d.count == 2 ? min(Int(d[0]) ?? 0, 100_000) : 0
        return days * 86400 + (d.last ?? "").split(separator: ":").suffix(3)
            .compactMap { Int($0).map { min(max($0, 0), 1_000_000) } }.reduce(0) { $0 * 60 + $1 }
    }

    /// Byte counters from a remote /proc: 0 … 1 PiB, so sums and differences can't overflow.
    static func counter(_ s: String) -> Int64? { Int64(s).map { min(max($0, 0), 1 << 50) } }
}

struct CloudIdentity: Hashable {
    var gcloud = ""            // "account  project"
    var rclone: [String] = []  // "name: type"
    var isEmpty: Bool { gcloud.isEmpty && rclone.isEmpty }
}

enum Scan {
    static let script = #"""
    : TNM_SCAN
    PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/bin"
    ps -eo pid=,ppid=,etime=,args= 2>/dev/null | grep -v TNM_SCAN | grep -E '[r]clone .*(copy|copyto|sync|move|moveto|bisync)|[g]sutil .*(cp|rsync|mv)|[g]cloud.* storage +(cp|rsync|mv)' | while read -r pid ppid et args; do
      r=; w=
      if [ -r "/proc/$pid/io" ]; then
        r=$(awk '$1=="rchar:"{print $2}' "/proc/$pid/io"); w=$(awk '$1=="wchar:"{print $2}' "/proc/$pid/io")
      fi
      printf 'T\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$ppid" "$et" "$r" "$w" "$args"
      case "$args" in *rclone*--rc*) printf 'R\t%s\t%s\n' "$pid" "$(rclone rc core/stats 2>/dev/null | tr -d '\n')";; esac
    done
    if [ "$IDENT" = 1 ]; then
      command -v gcloud >/dev/null 2>&1 && printf 'G\t%s\n' "$(gcloud config list --format='value(core.account,core.project)' 2>/dev/null | head -n1)"
      command -v rclone >/dev/null 2>&1 && rclone listremotes --long 2>/dev/null | while read -r l; do printf 'C\t%s\n' "$l"; done
    fi
    exit 0
    """#

    /// Script output → transfers (worker processes folded into their parent) + identity if asked for.
    static func parse(_ out: String, machineId: String, machineName: String) -> (transfers: [Transfer], identity: CloudIdentity?) {
        var raw: [Int: Transfer] = [:]
        var stats: [Int: RcloneStats] = [:]
        var ident: CloudIdentity?
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
            switch f.first {
            case "T" where f.count == 7:
                guard let pid = Int(f[1]) else { continue }
                raw[pid] = Transfer(machineId: machineId, machineName: machineName, pid: pid, ppid: Int(f[2]) ?? 0,
                                    elapsed: Transfer.seconds(f[3]), sent: Transfer.counter(f[5]), recv: Transfer.counter(f[4]), args: f[6])
            case "R" where f.count >= 3:
                if let pid = Int(f[1]), var s = try? JSONDecoder().decode(RcloneStats.self, from: Data(f[2].utf8)) {
                    func sane(_ d: Double) -> Double? { d.isFinite && d >= 0 ? min(d, 1e15) : nil }   // Int(1e300) traps
                    s.speed = s.speed.flatMap(sane)
                    s.eta = s.eta.flatMap(sane)
                    stats[pid] = s
                }
            case "G" where f.count >= 2:
                ident = ident ?? CloudIdentity()
                ident?.gcloud = f.dropFirst().flatMap { $0.split(whereSeparator: \.isWhitespace) }.joined(separator: " · ")   // account⇥project
            case "C" where f.count >= 2:
                ident = ident ?? CloudIdentity()
                ident?.rclone.append(f[1].split(whereSeparator: \.isWhitespace).joined(separator: " "))
            default: break
            }
        }
        // gsutil -m / gcloud fork workers with the same argv — fold them (and their bytes) into the root
        func root(_ pid: Int) -> Int {
            var p = pid, hops = 0
            while let parent = raw[p]?.ppid, raw[parent] != nil, hops < 16 { p = parent; hops += 1 }
            return p
        }
        var roots = raw.filter { root($0.key) == $0.key }
        for (pid, t) in raw where roots[pid] == nil {
            guard var base = roots[root(pid)] else { continue }
            if let s = t.sent { base.sent = min((base.sent ?? 0) + s, 1 << 60) }
            if let s = t.recv { base.recv = min((base.recv ?? 0) + s, 1 << 60) }
            roots[base.pid] = base
        }
        for pid in roots.keys { roots[pid]?.stats = stats[pid] }
        return (roots.values.sorted { $0.pid < $1.pid }, ident)
    }
}

// MARK: - Scanner

@MainActor
final class Transfers: ObservableObject {
    @Published private(set) var active: [Transfer] = []
    @Published private(set) var identities: [String: CloudIdentity] = [:]   // machine id ("local" = this Mac)
    @Published private(set) var watched: [String] = []                     // names scanned last round
    @Published private(set) var lastScan: Date?
    @Published private(set) var scanning = false
    var visible = false
    weak var store: Store?
    private var samples: [String: (sent: Int64, at: Date)] = [:]

    static let local = Machine(id: "local", name: "this mac")

    func on(_ machineId: String) -> [Transfer] { active.filter { $0.machineId == machineId } }

    /// Hosts we may check: SSH, key auth verified by you, not known-offline.
    func targets(remote: Bool = true) -> [Machine] {
        guard let store, remote else { return [Self.local] }
        return [Self.local] + store.machines.filter { $0.usesSSH && $0.authVerifiedAt != nil && store.online($0) != false }
    }

    /// This Mac is checked in the background (local ps, no network). Your servers are only contacted
    /// while the Cloud page is open or when you hit Rescan — no SSH happens behind your back.
    func run() async {
        while !Task.isCancelled {
            await scan(remote: visible)
            try? await Task.sleep(for: .seconds(visible ? 15 : 60))
        }
    }

    func scan(remote: Bool = true, refreshIdentities: Bool = false) async {
        guard let store, !scanning else { return }
        scanning = true
        defer { scanning = false }
        let targets = targets(remote: remote)
        // gcloud is slow to start — ask for identities once per host, or on manual rescan
        let jobs: [(id: String, ident: Bool, cmd: String)] = targets.map { m in
            let ident = refreshIdentities || identities[m.id] == nil
            let script = (ident ? "IDENT=1\n" : "") + Scan.script
            let cmd = m.id == Self.local.id
                ? "/bin/sh -c " + Remote.q(script)
                : Remote.sshCommand(m, command: "sh -c " + Remote.q(script))
            return (m.id, ident, cmd)
        }
        let results = await withTaskGroup(of: (String, Bool, Int32, String).self) { g in
            for j in jobs { g.addTask { let r = await Shell.run(j.cmd); return (j.id, j.ident, r.code, r.output) } }
            var out: [(String, Bool, Int32, String)] = []
            for await r in g { out.append(r) }
            return out
        }
        let now = Date()
        var next: [Transfer] = []
        for (id, askedIdent, code, out) in results {
            let before = on(id)
            guard code == 0, let m = targets.first(where: { $0.id == id }) else { next += before; continue }   // unreachable → keep last known
            let name = m.name.isEmpty ? m.host : m.name
            let (found, ident) = Scan.parse(out, machineId: id, machineName: name)
            if askedIdent { identities[id] = ident ?? CloudIdentity() }
            for var t in found {
                if let s = t.sent, let prev = samples[t.id], now > prev.at { t.rate = Double(s - prev.sent) / now.timeIntervalSince(prev.at) }
                if let s = t.sent { samples[t.id] = (s, now) }
                next.append(t)
            }
            for gone in before where !found.contains(where: { $0.id == gone.id }) {
                samples[gone.id] = nil
                let p = gone.parsed
                var detail = "\(p.tool) \(p.op) \(p.src) → \(p.dst)"
                if let s = gone.stats?.bytes ?? gone.sent { detail += " · \(bytes(s))" }
                if let e = gone.stats?.errors, e > 0 { detail += " · \(e) errors" }
                store.log(.transfer, machine: m, detail: detail, durationMs: gone.elapsed * 1000)
            }
        }
        // machines that dropped out of the scan (went offline) keep their last-known transfers
        let scannedIds = Set(results.map(\.0))
        next += active.filter { t in !scannedIds.contains(t.machineId) && store.machines.contains { $0.id == t.machineId } }
        active = next.sorted { ($0.machineName.lowercased(), $0.pid) < ($1.machineName.lowercased(), $1.pid) }
        if remote {
            watched = targets.map { $0.name.isEmpty ? $0.host : $0.name }
            lastScan = now
        }
    }
}

func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .binary) }

func duration(_ seconds: Int) -> String {
    Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
}

// MARK: - Cloud page

struct CloudView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var cloud: Transfers

    var unwatched: [Machine] { store.machines.filter { $0.usesSSH && $0.authVerifiedAt == nil } }
    var history: [Session] { store.sessions.filter { $0.kind == .transfer } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                readout
                section("ACTIVE TRANSFERS") {
                    if cloud.active.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("nothing uploading — no rclone · gcloud storage · gsutil processes running")
                                .font(.mono(11)).foregroundStyle(.dim)
                            Text("tip: start rclone with --rc and this page shows real progress + ETA")
                                .font(.mono(9)).foregroundStyle(.tertiary)
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.panelDeep, in: RoundedRectangle(cornerRadius: 10))
                    } else {
                        ForEach(cloud.active) { TransferCard(t: $0) }
                    }
                }
                section("RCLONE REMOTES") { RemotesSection() }
                section("CLOUD ACCOUNTS") { accounts }
                section("HISTORY · ENCRYPTED LOG") { historyList }
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.bg)
        .navigationTitle("Cloud")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await cloud.scan(remote: true, refreshIdentities: true) } } label: {
                    Label("Rescan", systemImage: cloud.scanning ? "hourglass" : "arrow.triangle.2.circlepath")
                }
                .disabled(cloud.scanning)
                .help("Rescan transfers and cloud accounts now")
            }
        }
        .onAppear {
            cloud.visible = true
            Task { await cloud.scan(remote: true) }
        }
        .onDisappear { cloud.visible = false }
    }

    func section<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) { SectionLabel(t: t); c() }
    }

    var readout: some View {
        HStack(alignment: .top, spacing: 36) {
            stat("ACTIVE", "\(cloud.active.count)", cloud.active.isEmpty ? .primary : .accent)
            stat("THROUGHPUT", cloud.active.compactMap(\.speed).reduce(0, +) > 0
                 ? bytes(Int64(min(cloud.active.compactMap(\.speed).reduce(0, +), 1e15))) + "/s" : "—")
            stat("WATCHING", "\(cloud.watched.count) hosts · while open")
            VStack(alignment: .leading, spacing: 4) {
                Text("LAST SCAN").font(.mono(9)).foregroundStyle(.dim).tracking(2)
                if let d = cloud.lastScan {
                    Text(d, style: .relative).font(.mono(13))
                } else {
                    Text(cloud.scanning ? "scanning…" : "—").font(.mono(13))
                }
            }
            Spacer()
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) { Rectangle().fill(Color.accent).frame(width: 2) }
        .overlay(alignment: .bottomLeading) {
            if !unwatched.isEmpty {
                Text("not watched (verify key auth to include): " + unwatched.map { $0.name.isEmpty ? $0.host : $0.name }.joined(separator: ", "))
                    .font(.mono(9)).foregroundStyle(.tertiary).lineLimit(1)
                    .offset(x: 12, y: 18)
            }
        }
    }

    func stat(_ k: String, _ v: String, _ c: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(k).font(.mono(9)).foregroundStyle(.dim).tracking(2)
            Text(v).font(.mono(13)).foregroundStyle(c)
        }
    }

    @ViewBuilder var accounts: some View {
        let rows = cloud.targets().compactMap { m in cloud.identities[m.id].flatMap { $0.isEmpty ? nil : (m, $0) } }
        if rows.isEmpty {
            Text(cloud.lastScan == nil ? "scanning…" : "no gcloud or rclone config found on watched hosts")
                .font(.mono(10)).foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(rows, id: \.0.id) { m, ident in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(m.name.isEmpty ? m.host : m.name).font(.system(size: 12, weight: .semibold))
                            .frame(width: 130, alignment: .leading).lineLimit(1)
                        VStack(alignment: .leading, spacing: 5) {
                            if !ident.gcloud.isEmpty { pair("GCLOUD", ident.gcloud, .gcloud) }
                            if !ident.rclone.isEmpty { pair("RCLONE", ident.rclone.joined(separator: "  ·  "), .accent) }
                        }
                    }
                }
            }
        }
    }

    func pair(_ k: String, _ v: String, _ c: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(k).font(.mono(8).weight(.bold)).tracking(1.5).foregroundStyle(c).frame(width: 52, alignment: .leading)
            Text(v).font(.mono(10)).textSelection(.enabled)
        }
    }

    @ViewBuilder var historyList: some View {
        if history.isEmpty {
            Text("finished transfers land here — tool, paths, bytes moved, how long it ran")
                .font(.mono(10)).foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(history.prefix(40)) { s in
                    HStack(spacing: 12) {
                        Text(MachineDetailView.sessionFmt.string(from: s.at)).font(.mono(9)).foregroundStyle(.tertiary)
                        Text(s.machineName).font(.mono(10)).frame(width: 110, alignment: .leading).lineLimit(1)
                        Text(s.detail).font(.mono(10)).foregroundStyle(.dim).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if let ms = s.durationMs { Text(duration(ms / 1000)).font(.mono(9)).foregroundStyle(.tertiary) }
                    }
                }
            }
        }
    }
}

extension Color { static let gcloud = Color(hex: 0x4F8EF7) }

func toolColor(_ tool: String) -> Color { tool == "rclone" ? .accent : .gcloud }

struct TransferCard: View {
    @EnvironmentObject private var store: Store
    let t: Transfer

    var body: some View {
        let p = t.parsed
        let c = toolColor(p.tool)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(p.tool.uppercased()).font(.mono(9).weight(.bold)).tracking(1.5)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(c.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(c)
                Text(p.op.isEmpty ? "transfer" : p.op).font(.mono(12).weight(.semibold))
                Spacer()
                Text("\(t.machineName) · pid \(t.pid)").font(.mono(10)).foregroundStyle(.dim)
            }
            HStack(spacing: 8) {
                Text(p.src.isEmpty ? "—" : p.src).truncationMode(.middle)
                Image(systemName: "arrow.right").foregroundStyle(c).font(.system(size: 10, weight: .bold))
                Text(p.dst.isEmpty ? "—" : p.dst).truncationMode(.middle)
            }
            .font(.mono(11)).lineLimit(1)
            ProgressStrip(fraction: t.stats?.fraction, color: c)
            HStack(spacing: 18) {
                if let f = t.stats?.fraction { metric("DONE", "\(Int(f * 100))%") }
                if let b = t.stats?.bytes {
                    metric("MOVED", bytes(b) + (t.stats?.totalBytes.map { " / " + bytes($0) } ?? ""))
                } else if let s = t.sent {
                    metric("SENT", bytes(s))
                }
                if let sp = t.speed, sp > 0 { metric("SPEED", bytes(Int64(sp)) + "/s") }
                if let eta = t.stats?.eta, eta > 0 { metric("ETA", duration(Int(eta))) }
                if let e = t.stats?.errors, e > 0 { metric("ERRORS", "\(e)", .bad) }
                metric("ELAPSED", duration(t.elapsed))
                Spacer()
                if t.stats == nil, p.tool == "rclone" {
                    Text("add --rc for % + ETA").font(.mono(9)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .background(Color.panelDeep, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.ink.opacity(0.07)))
        .contextMenu {
            Button("Copy command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t.args, forType: .string)
            }
            if t.machineId != Transfers.local.id {
                Button("Open \(t.machineName)") { store.selection = .machine(t.machineId) }
            }
        }
        .help(t.args)
    }

    func metric(_ k: String, _ v: String, _ c: Color = .primary) -> some View {
        HStack(spacing: 6) {
            Text(k).font(.mono(8)).foregroundStyle(.dim).tracking(1.5)
            Text(v).font(.mono(10)).foregroundStyle(c)
        }
    }
}

/// Determinate when rclone --rc reports totals, otherwise a moving sweep that just says "alive".
struct ProgressStrip: View {
    let fraction: Double?
    let color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.ink.opacity(0.06))
                if let f = fraction {
                    Capsule().fill(color).frame(width: max(4, g.size.width * f))
                        .shadow(color: color.opacity(0.6), radius: 4)
                } else {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
                        let x = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                        Capsule()
                            .fill(LinearGradient(colors: [color.opacity(0), color, color.opacity(0)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: g.size.width * 0.28)
                            .offset(x: (g.size.width * 1.28) * x - g.size.width * 0.28)
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: 4)
    }
}
