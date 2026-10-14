import Foundation
import SwiftUI
import AppKit
import CryptoKit

struct SshTab: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    var name = ""
    var command = ""   // empty = interactive shell
}

struct Machine: Identifiable, Hashable, Codable {
    var id = UUID().uuidString
    var name = ""
    var host = ""          // tailnet IP or DNS name
    var os = ""
    var kind: Kind = .both
    var sshUser = ""
    var rdpUser = ""
    var tags: [String] = []
    var sshTabs: [SshTab] = []
    var authVerifiedAt: Date? = nil
    var online: Bool? = nil  // matched from tailnet status, nil = unknown
    var sshPort = ""         // empty = 22 / ~/.ssh/config
    var sshKey = ""          // ~/.ssh/<name>; empty = ssh's default choice (agent + config)
    var sshOptions = ""      // extra ssh args, e.g. -J bastion
    var folderId = ""        // "" = top level

    enum Kind: String, Codable, CaseIterable { case ssh, rdp, both }
    var usesSSH: Bool { kind != .rdp }
    var usesRDP: Bool { kind != .ssh }
}

extension Machine {
    enum CodingKeys: String, CodingKey {
        case id, name, host, os, kind, sshUser, rdpUser, tags, sshTabs, authVerifiedAt, online, sshPort, sshKey, sshOptions, folderId
    }

    /// Lenient decode — fields added after the first release (sshTabs, authVerifiedAt)
    /// must not brick vaults written by older builds. Every key falls back to its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        os = try c.decodeIfPresent(String.self, forKey: .os) ?? ""
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .both
        sshUser = try c.decodeIfPresent(String.self, forKey: .sshUser) ?? ""
        rdpUser = try c.decodeIfPresent(String.self, forKey: .rdpUser) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        sshTabs = try c.decodeIfPresent([SshTab].self, forKey: .sshTabs) ?? []
        authVerifiedAt = try c.decodeIfPresent(Date.self, forKey: .authVerifiedAt)
        online = try c.decodeIfPresent(Bool.self, forKey: .online)
        sshPort = try c.decodeIfPresent(String.self, forKey: .sshPort) ?? ""
        sshKey = try c.decodeIfPresent(String.self, forKey: .sshKey) ?? ""
        sshOptions = try c.decodeIfPresent(String.self, forKey: .sshOptions) ?? ""
        folderId = try c.decodeIfPresent(String.self, forKey: .folderId) ?? ""
    }

    var sshLogin: String { sshUser.isEmpty ? NSUserName() : sshUser }

    /// Everything between `ssh` and the remote command — one place, so tabs, verify, specs and the
    /// transfer scanner all connect the same way. A chosen key is the *only* key offered (IdentitiesOnly).
    /// ponytail: -A in OPTIONS does re-enable forwarding (flags are last-wins, -o is first-wins)
    // ponytail: options split on whitespace — quoted values unsupported; shlex it if anyone needs them
    var sshArgs: [String] {
        // hardening first, so OPTIONS can't silently weaken it (ssh keeps the first -o per keyword):
        // no shared ControlMaster sockets left behind, no agent forwarding (add -A in OPTIONS to opt in)
        var a = ["-o", "ControlPath=none", "-a"]
        if let p = Int(sshPort.trimmingCharacters(in: .whitespaces)) { a += ["-p", String(p)] }
        if !sshKey.isEmpty { a += ["-i", SSHKeys.privPath(sshKey), "-o", "IdentitiesOnly=yes"] }
        a += sshOptions.split(whereSeparator: \.isWhitespace).map(String.init)
        return a + ["\(sshLogin)@\(host)"]
    }
}

/// VMware-style library folder. Machines live in exactly one folder (or the top level); folders nest.
struct Folder: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var parent = ""   // "" = top level
    var color = ""    // hex; "" = derived from the name

    var tint: Color { UInt32(color, radix: 16).map { Color(hex: $0) } ?? tagColor(name) }

    static let palette: [(name: String, hex: String)] = [
        ("Amber", "FF9F0A"), ("Green", "30D158"), ("Blue", "4F8EF7"), ("Violet", "BF5AF2"),
        ("Red", "FF453A"), ("Cyan", "64D2FF"), ("Graphite", "8E9199"),
    ]
}

struct DiscoveredPeer: Identifiable, Hashable {
    var hostName: String
    var dnsName: String?
    var os: String?
    var ips: [String]
    var online: Bool
    var exitOption = false               // can route our traffic
    var isExit = false                   // currently routing our traffic
    var location: TailnetStatus.Location? = nil   // set only on Mullvad exit nodes
    var curAddr = ""                     // non-empty = direct UDP path
    var relay = ""                       // home DERP region
    var rx: Int64 = 0
    var tx: Int64 = 0
    var active = false                   // recent traffic
    var id: String { ip }
    var ip: String { ips.first ?? dnsName ?? hostName }
    var isMullvad: Bool { location != nil }
}

enum Route: Hashable { case overview, pipelines, orchestrate, cloud, keys, snippets, docs, machine(String) }

enum TagSuggestions {
    static let all = [
        "production", "staging", "dev", "ci", "homelab", "infra", "backup", "research",
    ]
}

struct TailnetStatus: Codable {
    struct Location: Codable, Hashable {
        var Country: String?
        var CountryCode: String?
        var City: String?
        var Priority: Int?
    }
    struct PeerRaw: Codable {
        var ID: String?
        var HostName: String?
        var DNSName: String?
        var OS: String?
        var TailscaleIPs: [String]?
        var Online: Bool?
        var LastSeen: String?
        var ExitNode: Bool?
        var ExitNodeOption: Bool?
        var Location: Location?
        var CurAddr: String?
        var Relay: String?
        var RxBytes: Int64?
        var TxBytes: Int64?
        var Active: Bool?

        var peer: DiscoveredPeer {
            var dns = DNSName
            if let d = dns, d.hasSuffix(".") { dns = String(d.dropLast()) }
            return DiscoveredPeer(hostName: HostName ?? "?", dnsName: dns, os: OS,
                                  ips: TailscaleIPs ?? [], online: Online ?? false,
                                  exitOption: ExitNodeOption ?? false, isExit: ExitNode ?? false,
                                  location: Location, curAddr: CurAddr ?? "", relay: Relay ?? "",
                                  rx: RxBytes ?? 0, tx: TxBytes ?? 0, active: Active ?? false)
        }
    }
    struct Tailnet: Codable { var Name: String? }
    var BackendState: String?
    var Health: [String]?
    var Peer: [String: PeerRaw]?
    var selfNode: PeerRaw?
    var CurrentTailnet: Tailnet?
    enum CodingKeys: String, CodingKey { case BackendState, Health, Peer, CurrentTailnet, selfNode = "Self" }

    var machines: [DiscoveredPeer] {
        (Peer ?? [:]).values.map(\.peer)
            .sorted { ($0.online ? 0 : 1, $0.hostName.lowercased()) < ($1.online ? 0 : 1, $1.hostName.lowercased()) }
    }
}

/// "US" → 🇺🇸
func flag(_ countryCode: String?) -> String {
    String((countryCode ?? "").uppercased().unicodeScalars
        .compactMap { Unicode.Scalar(127397 + $0.value) }.map(Character.init))
}

/// How a machine is reached. External = not on your tailnet (public IP / DNS) — a fact, not a warning.
enum Reach {
    case online, offline, external, unknown   // unknown = tailnet status not loaded (yet)
    var label: String {
        switch self { case .online: "ONLINE"; case .offline: "OFFLINE"; case .external: "EXTERNAL"; case .unknown: "UNKNOWN" }
    }
    var color: Color {
        switch self { case .online: .ok; case .offline: .ledOff; case .external: .external; case .unknown: .dim }
    }
}

extension Color { static let external = Color(hex: 0x7D8FA3) }


@MainActor
public final class Store: ObservableObject {
    private let vaultKey: SymmetricKey?
    private let vaultPath = Vault.path   // where this store's data came from — and the only place it's written
    private var db = DB()

    @Published var machines: [Machine] = [] { didSet { persist() } }   // array order = your manual order
    @Published var folders: [Folder] = [] { didSet { db.folders = folders; commit() } }
    @Published private(set) var credentials: [Credential] = [] { didSet { db.credentials = credentials; commit() } }
    @Published var remotes: [RcloneRemote] = [] { didSet { db.remotes = remotes; commit() } }
    @Published private(set) var sessions: [Session] = []
    @Published var keys: [KeyRecord] = []
    @Published var discovered: [DiscoveredPeer] = []   // your tailnet peers — Mullvad filtered out
    @Published var exitNodes: [DiscoveredPeer] = []
    @Published var me: DiscoveredPeer?
    @Published var tailnetName = ""
    @Published var switchingExit = false
    private var byHost: [String: DiscoveredPeer] = [:]
    @Published var backendState = ""
    @Published var health: [String] = []
    @Published var error: String?
    @Published var lastUpdated: Date?
    @Published var selection: Route? = .overview
    @Published private(set) var events: [PipelineEvent] = [] { didSet { board.schedule() } }   // newest first (by arrival)
    @Published private(set) var eventsSeenAt = Date.distantPast
    @Published private(set) var pipelineToken = ""
    @Published var pipelineGroups: [PipelineGroup] = [] { didSet { db.pipelineGroups = pipelineGroups; commit(); board.schedule() } }
    @Published var snippets: [Snippet] = [] { didSet { db.snippets = snippets; commit() } }
    @Published var services: [String: ServiceSettings] = [:] { didSet { db.services = services; commit(); board.schedule() } }   // section labels
    let terms = Terminals()
    let cloud = Transfers()
    let inbox = Inbox()
    let claude = Orchestrator()
    let board = PipelineBoard()

    var binMissing: Bool { Tailscale.bin == nil }

    public convenience init() { self.init(vaultKey: Vault.key()) }

    init(vaultKey: SymmetricKey?) {
        self.vaultKey = vaultKey
        db = Vault.load(key: vaultKey)
        var ms = db.machines
        let fs = db.folders ?? Self.foldersFromTags(&ms)   // one-time: last build's tag groups → folders
        machines = ms
        folders = fs
        if db.folders == nil {   // didSet doesn't run inside init — persist the migration explicitly
            db.machines = ms
            db.folders = fs
            commit()
        }
        sessions = db.sessions
        credentials = db.credentials ?? []
        remotes = db.remotes ?? []
        Gate.lockOnSleep()
        keys = db.keys
        events = db.events ?? []
        eventsSeenAt = db.eventsSeenAt ?? .distantPast
        pipelineGroups = db.pipelineGroups ?? []
        snippets = db.snippets ?? []
        services = db.services ?? [:]
        pipelineToken = db.pipelineToken ?? ""
        if pipelineToken.isEmpty {
            pipelineToken = Self.newToken()
            db.pipelineToken = pipelineToken
            commit()
        }
        terms.store = self
        cloud.store = self
        inbox.store = self
        claude.store = self
        board.store = self
        board.schedule()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushVault() }
        }
        if vaultKey == nil {
            error = "Keychain unavailable — encrypted vault disabled, changes won't survive a restart."
        } else if let note = Vault.resetNote {
            error = note
            Vault.resetNote = nil
        }
    }

    private func persist() {
        db.machines = machines
        commit()
    }

    private static let vaultQueue = DispatchQueue(label: AppInfo.bundleID + ".vault", qos: .utility)
    private var saveScheduled = false

    /// Encoding + sealing + writing the whole vault took ~7 ms per change on the main thread — per webhook event.
    /// Now a burst of changes becomes one write, 0.3 s later, on a background queue, always of the newest data.
    // ponytail: a crash can lose the last ≤ 0.3 s of changes; quitting flushes
    private func commit() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated { self?.writeVault() }
        }
    }

    private func writeVault() {
        saveScheduled = false
        let snapshot = db, key = vaultKey, path = vaultPath
        Self.vaultQueue.async {
            guard !Vault.save(snapshot, key: key, path: path) else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { if self?.error == nil { self?.error = "vault write failed — data kept in memory only" } }
            }
        }
    }

    /// Quit: write now and wait for it.
    func flushVault() {
        saveScheduled = false
        let snapshot = db, key = vaultKey, path = vaultPath
        Self.vaultQueue.sync { _ = Vault.save(snapshot, key: key, path: path) }
    }

    func upsert(_ m: Machine) {
        guard let i = machines.firstIndex(where: { $0.id == m.id }) else { return }
        var m = m
        if m.sshArgs != machines[i].sshArgs { m.authVerifiedAt = nil }   // new route → old verification means nothing
        machines[i] = m
    }

    func remove(_ m: Machine) {
        machines.removeAll { $0.id == m.id }
        if selection == .machine(m.id) { selection = .overview }
        for t in terms.tabs(m.id) { terms.close(t) }
        credentials.removeAll { $0.machineId == m.id }
        log(.machineDelete, machine: m)
    }

    // MARK: Server passwords (sudo / root)
    // Each password is its own AES-GCM box under a key derived from the vault key (HKDF, separate domain),
    // stored sealed inside the already-sealed vault, and only opened at the moment of use.

    /// Per-purpose key, HKDF-derived from the vault key — a leak of one domain's boxes says nothing about another's.
    private func key(_ domain: String) -> SymmetricKey? {
        vaultKey.map { HKDF<SHA256>.deriveKey(inputKeyMaterial: $0, info: Data("tailnet-manager.\(domain).v1".utf8), outputByteCount: 32) }
    }
    func seal(_ plain: Data, _ domain: String) -> Data? { key(domain).flatMap { try? AES.GCM.seal(plain, using: $0).combined } }
    func unseal(_ box: Data, _ domain: String) -> Data? {
        guard let k = key(domain), let b = try? AES.GCM.SealedBox(combined: box) else { return nil }
        return try? AES.GCM.open(b, using: k)
    }

    func credentials(for machineId: String) -> [Credential] { credentials.filter { $0.machineId == machineId } }

    /// One password per user per machine — saving again replaces it. Returns an error message, nil on success.
    func saveCredential(machine: String, user: String, password: String) -> String? {
        let u = user.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty, !password.isEmpty else { return "user and password required" }
        guard let box = seal(Data(password.utf8), "secrets") else {
            return "encrypted vault unavailable (Keychain) — not storing a password in the clear"
        }
        credentials.removeAll { $0.machineId == machine && $0.user == u }
        credentials.append(Credential(machineId: machine, user: u, sealed: box))
        return nil
    }

    func deleteCredential(_ id: String) { credentials.removeAll { $0.id == id } }

    /// Plaintext bytes — callers gate this behind Gate.unlock and zero the buffer after use.
    func openCredential(_ c: Credential) -> [UInt8]? { unseal(c.sealed, "secrets").map { [UInt8]($0) } }

    // MARK: Folders

    private var folderIds: Set<String> { Set(folders.map(\.id)) }

    /// Unknown parent / folder ids (a deleted folder) fall back to the top level — nothing gets lost.
    func folders(in parent: String) -> [Folder] {
        let ids = folderIds
        return folders.filter { $0.parent == parent || (parent.isEmpty && !ids.contains($0.parent)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func machines(in folder: String) -> [Machine] {
        let ids = folderIds
        return machines.filter { $0.folderId == folder || (folder.isEmpty && !ids.contains($0.folderId)) }
    }

    /// Top level → … → this folder.
    func path(_ folderId: String) -> [Folder] {
        var out: [Folder] = [], id = folderId
        while let f = folders.first(where: { $0.id == id }), !out.contains(f) { out.insert(f, at: 0); id = f.parent }
        return out
    }

    /// Every machine in tree order (folders depth-first, then top-level machines) — the overview's ring order.
    func treeOrder(_ parent: String = "") -> [Machine] {
        folders(in: parent).flatMap { treeOrder($0.id) } + machines(in: parent)
    }

    func allMachines(under folderId: String) -> [Machine] { treeOrder(folderId) }

    func flatTree(_ parent: String = "", depth: Int = 0) -> [(folder: Folder, depth: Int)] {
        folders(in: parent).flatMap { [($0, depth)] + flatTree($0.id, depth: depth + 1) }
    }

    /// Sidebar drag payloads: "m:<id>" = machine, "f:<id>" = folder. `before` = drop target machine (reorder).
    @discardableResult
    func drop(_ items: [String], into folder: String, before machine: String? = nil) -> Bool {
        var ok = false
        for it in items {
            let id = String(it.dropFirst(2))
            if it.hasPrefix("m:"), machines.contains(where: { $0.id == id }) {
                move(machine: id, to: folder, before: machine)
                ok = true
            } else if it.hasPrefix("f:") {
                ok = move(folder: id, into: folder) || ok
            }
        }
        return ok
    }

    @discardableResult
    func addFolder(_ name: String, in parent: String = "") -> Folder? {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return nil }
        let f = Folder(name: n, parent: parent)
        folders.append(f)
        return f
    }

    func renameFolder(_ id: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].name = n
    }

    func setColor(_ id: String, _ hex: String) {
        if let i = folders.firstIndex(where: { $0.id == id }) { folders[i].color = hex }
    }

    /// Deleting a folder never deletes machines: its contents move up one level.
    func deleteFolder(_ id: String) {
        guard let f = folders.first(where: { $0.id == id }) else { return }
        machines = machines.map { m in var m = m; if m.folderId == id { m.folderId = f.parent }; return m }
        folders = folders.compactMap { x in
            if x.id == id { return nil }
            var x = x
            if x.parent == id { x.parent = f.parent }
            return x
        }
    }

    /// Into `folder`, placed just before `before` (a machine id) or at the end.
    func move(machine id: String, to folder: String, before: String? = nil) {
        guard let i = machines.firstIndex(where: { $0.id == id }), id != before else { return }
        var ms = machines
        var m = ms.remove(at: i)
        m.folderId = folder
        let at = before.flatMap { b in ms.firstIndex { $0.id == b } } ?? ms.count
        ms.insert(m, at: at)
        machines = ms   // one write
    }

    /// Nest a folder; refuses to put a folder inside itself or its own subtree.
    @discardableResult
    func move(folder id: String, into parent: String) -> Bool {
        guard id != parent, !path(parent).contains(where: { $0.id == id }),
              let i = folders.firstIndex(where: { $0.id == id }) else { return false }
        folders[i].parent = parent
        return true
    }

    /// Vaults from the tag-group build have no folders yet: each machine's first tag becomes its folder.
    static func foldersFromTags(_ machines: inout [Machine]) -> [Folder] {
        var byName: [String: Folder] = [:]
        for i in machines.indices {
            guard let t = machines[i].tags.first else { continue }
            let f = byName[t] ?? Folder(name: t)
            byName[t] = f
            machines[i].folderId = f.id
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    func log(_ kind: SessionKind, machine: Machine? = nil, detail: String = "", user: String = "", durationMs: Int? = nil) {
        let name = machine.map { $0.name.isEmpty ? $0.host : $0.name } ?? "—"
        db.addSession(Session(machineId: machine?.id ?? "-", machineName: name,
                              kind: kind, detail: detail, user: user, durationMs: durationMs))
        sessions = db.sessions
        commit()
    }

    // MARK: Pipeline events (webhooks from your servers — Pipelines.swift)

    var unseenEvents: Int { events.prefix(while: { $0.receivedAt > eventsSeenAt }).count }

    /// false = a replay of an event already stored (same event_id) — dropped, the sender still gets 202.
    @discardableResult
    func receive(_ e: PipelineEvent, seen: Bool) -> Bool {
        if let id = e.eventId, events.contains(where: { $0.eventId == id }) { return false }
        events.insert(e, at: 0)
        if events.count > DB.maxEvents { events.removeLast(events.count - DB.maxEvents) }
        if seen { eventsSeenAt = e.receivedAt }
        savePipeline()
        return true
    }

    func markEventsSeen() {
        guard unseenEvents > 0 else { return }
        eventsSeenAt = Date()
        savePipeline()
    }

    func clearEvents() { events = []; savePipeline() }

    /// Every server holding the old token gets 401 until it's updated.
    func rotatePipelineToken() { pipelineToken = Self.newToken(); savePipeline() }

    nonisolated static func newToken() -> String { (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined() }

    private func savePipeline() {
        db.events = events
        db.eventsSeenAt = eventsSeenAt
        db.pipelineToken = pipelineToken
        commit()
        updateBadge()
    }

    /// The missed-updates count on the Dock icon too — visible with the window closed.
    func updateBadge() { NSApp?.dockTile.badgeLabel = unseenEvents > 0 ? "\(unseenEvents)" : nil }

    /// Which of your machines a webhook sender's IP belongs to (by host field or its tailnet peer).
    func machine(ip: String) -> Machine? {
        let p = byHost[ip.lowercased()]
        return machines.first { $0.host == ip || (p != nil && peer($0)?.ip == p?.ip) }
    }

    func peerName(ip: String) -> String? { byHost[ip.lowercased()]?.hostName }

    func syncKeys(_ live: [SSHKeys.KeyInfo]) {
        var byName = Dictionary(uniqueKeysWithValues: db.keys.map { ($0.name, $0) })
        for k in live {
            if var r = byName[k.name] {
                r.keyType = k.keyType
                r.hasPrivate = k.hasPrivate
                r.hasPublic = k.hasPublic
                r.lastSeenAt = Date()
                byName[k.name] = r
            } else {
                byName[k.name] = KeyRecord(name: k.name, keyType: k.keyType,
                                           hasPrivate: k.hasPrivate, hasPublic: k.hasPublic)
            }
        }
        db.keys = byName.values.sorted { $0.name < $1.name }
        keys = db.keys
        commit()
    }

    func refresh() async {
        guard let bin = Tailscale.bin else {
            error = "Tailscale CLI not found — status LEDs will show UNKNOWN. Install Tailscale, then re-run install.sh so the app can find it."
            return
        }
        let (code, out) = await Shell.run("'\(bin)' status --json")
        guard code == 0, let brace = out.firstIndex(of: "{") else {
            error = out.isEmpty ? "tailscale exited with code \(code)" : out
            return
        }
        do {
            apply(try JSONDecoder().decode(TailnetStatus.self, from: Data(String(out[brace...]).utf8)))
        } catch {
            self.error = "Failed to parse `tailscale status --json`: \(error.localizedDescription)"
        }
    }

    func apply(_ s: TailnetStatus) {
        let all = s.machines
        discovered = all.filter { !$0.isMullvad }
        exitNodes = all.filter(\.exitOption)
        me = s.selfNode?.peer
        tailnetName = s.CurrentTailnet?.Name ?? ""
        var bh: [String: DiscoveredPeer] = [:]
        for p in discovered {
            var keys = p.ips + [p.hostName]
            if let d = p.dnsName { keys += [d, String(d.prefix { $0 != "." })] }
            for k in keys where bh[k.lowercased()] == nil { bh[k.lowercased()] = p }  // online sorts first, wins
        }
        byHost = bh
        health = s.Health ?? []
        backendState = s.BackendState ?? ""
        error = nil
        lastUpdated = Date()
    }

    func peer(_ m: Machine) -> DiscoveredPeer? { byHost[m.host.lowercased()] }
    func online(_ m: Machine) -> Bool? { peer(m)?.online }
    func reach(_ m: Machine) -> Reach {
        if let p = peer(m) { return p.online ? .online : .offline }
        return lastUpdated == nil ? .unknown : .external
    }
    var exitNode: DiscoveredPeer? { exitNodes.first(where: \.isExit) }

    /// nil = route directly (no exit node)
    func setExitNode(_ p: DiscoveredPeer?) async {
        guard let bin = Tailscale.bin else { return }
        switchingExit = true
        defer { switchingExit = false }
        let (code, out) = await Shell.run("'\(bin)' set --exit-node=\(Remote.q(p?.ip ?? ""))")
        await refresh()
        if code != 0 { error = "exit node switch failed: " + out.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
