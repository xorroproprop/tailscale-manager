import SwiftUI
import AppKit

func tagColor(_ tag: String) -> Color {
    var h: UInt64 = 5381
    for c in tag.unicodeScalars { h = (h << 5 &+ h) &+ UInt64(c.value) }
    return Color(hue: Double(h % 360) / 360, saturation: 0.5, brightness: 0.72)
}

struct TagChip: View {
    let tag: String
    var onRemove: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 4) {
            Text(tag).font(.mono(9)).tracking(1)
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 7, weight: .bold)) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tagColor(tag).opacity(0.16), in: Capsule())
        .foregroundStyle(tagColor(tag))
        .overlay(Capsule().strokeBorder(tagColor(tag).opacity(0.45), lineWidth: 0.5))
    }
}

// MARK: - Machine: a home page until you Connect; then terminal tabs until you Disconnect

struct MachineDetailView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var terms: Terminals
    let machine: Machine

    @AppStorage("showInspector") private var showInspector = false
    // text drafts (so typing a space isn't trimmed away mid-word) — saved on every keystroke
    @State private var name = ""
    @State private var host = ""
    @State private var os = ""
    @State private var sshUser = ""
    @State private var rdpUser = ""
    @State private var sshPort = ""
    @State private var sshOptions = ""
    @State private var syncedId: String?   // which machine the drafts belong to
    @State private var keyNames: [String] = []
    @State private var newTag = ""
    @State private var newTabName = ""
    @State private var newTabCmd = ""
    @State private var auth: AuthState = .unknown
    @State private var specs: [SpecRow]?
    @State private var note: String?
    @State private var busy = false

    enum AuthState: Equatable { case unknown, ok, fail(String) }
    struct SpecRow: Identifiable { let id = UUID(); let label: String; let value: String }

    private var online: Bool? { store.online(machine) }
    private var reach: Reach { store.reach(machine) }
    private var ip: String { machine.host }
    /// Always the saved record — the one Connect, Test, Specs and new tabs all use.
    private var current: Machine { store.machines.first { $0.id == machine.id } ?? machine }

    /// Live = at least one tab open. Nothing connects until you click Connect.
    var connected: Bool { !terms.tabs(machine.id).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if machine.usesSSH && connected {
                TermTabBar(machine: machine) { showInspector = true }
                terminalArea
            } else {
                home
            }
            statusBar
        }
        .background(Color.bg)
        .navigationTitle(machine.name.isEmpty ? machine.host : machine.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if machine.usesRDP {
                    Button { openRDP() } label: { Label("Remote Desktop", systemImage: "macwindow.and.arrow.down.rectangle") }
                        .help("Open an RDP session in Windows App")
                }
                if connected, let s = terms.current(machine.id) {
                    Button { Remote.terminal(s.command) } label: { Label("Pop out", systemImage: "arrow.up.forward.app") }
                        .help("Open this session in a Ghostty window (outside the app — Disconnect won't close it)")
                    Button { terms.disconnect(machine.id) } label: { Label("Disconnect", systemImage: "power") }
                        .labelStyle(.titleAndIcon).foregroundStyle(Color.bad)
                        .help("Close every tab on this machine")
                }
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                    .help("Edit machine, connection and tab presets")
            }
        }
        .inspector(isPresented: $showInspector) {
            inspector.inspectorColumnWidth(min: 300, ideal: 340, max: 480)
        }
        .onChange(of: [name, host, os, sshUser, rdpUser, sshPort, sshOptions]) { _, _ in save() }
        .task(id: machine.id) {
            terms.lastMachine = machine.id
            syncedId = nil   // drafts belong to the previous machine until reloaded below
            name = machine.name
            host = machine.host
            os = machine.os
            sshUser = machine.sshUser.isEmpty ? NSUserName() : machine.sshUser
            rdpUser = machine.rdpUser
            sshPort = machine.sshPort
            sshOptions = machine.sshOptions
            specs = nil
            auth = .unknown
            authDetail = ""
            syncedId = machine.id
            keyNames = SSHKeys.list().filter(\.hasPrivate).map(\.name)   // local only — never touches the host
        }
    }

    /// Text drafts → store. Runs on every keystroke, so what you see is what Connect uses.
    func save() {
        guard syncedId == machine.id else { return }   // never write one machine's drafts into another
        var m = current
        m.name = name.trimmingCharacters(in: .whitespaces)
        m.host = host.trimmingCharacters(in: .whitespaces)
        m.os = os.trimmingCharacters(in: .whitespaces)
        m.sshUser = sshUser.trimmingCharacters(in: .whitespaces)
        m.rdpUser = rdpUser.trimmingCharacters(in: .whitespaces)
        m.sshPort = sshPort.trimmingCharacters(in: .whitespaces)
        m.sshOptions = sshOptions.trimmingCharacters(in: .whitespaces)
        commit(m)
    }

    /// The one write path from this view (Store.upsert drops a verification the new route invalidates).
    func commit(_ new: Machine) {
        guard new != current else { return }
        if new.sshArgs != current.sshArgs { auth = .unknown; authDetail = "" }
        store.upsert(new)
    }

    /// Pickers write straight through — no draft to fall out of sync.
    func live<T>(_ kp: WritableKeyPath<Machine, T>) -> Binding<T> {
        Binding(get: { current[keyPath: kp] }, set: { var m = current; m[keyPath: kp] = $0; commit(m) })
    }

    func setTags(_ tags: [String]) { var m = current; m.tags = tags; commit(m) }

    func addTag() {
        let t = newTag.trimmingCharacters(in: .whitespaces)
        newTag = ""
        guard !t.isEmpty, !current.tags.contains(t) else { return }
        setTags(current.tags + [t])
    }

    // MARK: Terminal

    @ViewBuilder var terminalArea: some View {
        if let s = terms.current(machine.id) {
            TerminalHost(session: s)
                .id(s.id)
                .overlay(alignment: .bottom) {
                    EndedBanner(s: s, reconnect: { terms.reconnect(s) }, close: { terms.close(s) })
                }
                .overlay(alignment: .top) { NoticeBanner(s: s) }
        }
    }

    // MARK: Home (not connected)

    var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                homeHeader
                actions
                HStack(alignment: .top, spacing: 14) {
                    card("ROUTE") { route }
                    if machine.usesSSH { card("ACCESS") { accessSummary } }
                }
                HStack(alignment: .top, spacing: 14) {
                    if machine.usesSSH { card("SPECS") { specsSection } }
                    card("SESSIONS · ENCRYPTED LOG") { sessionHistory }
                }
            }
            .padding(28)
            .frame(maxWidth: 940, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    var homeHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: osIcon(machine.os))
                .font(.system(size: 22, weight: .medium))
                .frame(width: 58, height: 58)
                .background(Color.panelDeep, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(reach.color.opacity(0.6), lineWidth: 1.2))
            VStack(alignment: .leading, spacing: 6) {
                let path = store.path(machine.folderId)
                if !path.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.fill").foregroundStyle(path.last!.tint).font(.system(size: 9))
                        Text(path.map { $0.name.uppercased() }.joined(separator: "  ›  ")).font(.mono(9)).tracking(1.5)
                            .foregroundStyle(.dim)
                    }
                }
                Text(machine.name.isEmpty ? machine.host : machine.name).font(.system(size: 22, weight: .bold))
                Text(machine.usesSSH ? "\(machine.sshLogin)@\(machine.host)" + (machine.sshPort.isEmpty ? "" : ":" + machine.sshPort) : machine.host)
                    .font(.mono(11)).foregroundStyle(.dim).textSelection(.enabled)
                if !machine.tags.isEmpty {
                    HStack(spacing: 6) { ForEach(machine.tags, id: \.self) { TagChip(tag: $0) } }
                }
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(reach.color).frame(width: 7, height: 7)
                    .shadow(color: reach == .online ? Color.ok.opacity(0.7) : .clear, radius: 3)
                Text(reach.label)
                    .font(.mono(10)).tracking(2).foregroundStyle(reach == .offline ? Color.dim : reach.color)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.panelDeep, in: Capsule())
        }
    }

    var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if machine.usesSSH {
                    Button { terms.open(current) } label: {
                        Label("Connect", systemImage: "power").font(.system(size: 13, weight: .semibold)).frame(minWidth: 110)
                    }
                    .buttonStyle(.borderedProminent).tint(Color.accent).controlSize(.large)
                    .help("Open an SSH session — then + for more tabs")
                    Menu {
                        Button("htop") { terms.open(current, preset: SshTab(name: "htop", command: "htop")) }
                        let saved = machine.sshTabs.filter { !($0.name == "shell" && $0.command.isEmpty) }
                        if !saved.isEmpty { Divider() }
                        ForEach(saved) { t in Button(t.name) { terms.open(current, preset: t) } }
                        Divider()
                        Button("Manage presets…") { showInspector = true }
                    } label: { Text("Connect with…") }
                    .menuStyle(.button).controlSize(.large).fixedSize()
                }
                if machine.usesRDP {
                    Button { openRDP() } label: { Label("Remote Desktop", systemImage: "macwindow.and.arrow.down.rectangle") }
                        .controlSize(.large)
                }
            }
            Text(machine.usesSSH
                 ? "not connected — nothing is open to this host until you click Connect; Disconnect or closing the last tab ends it"
                 : "RDP opens the Windows App via a generated .rdp file")
                .font(.mono(9)).foregroundStyle(.tertiary)
        }
    }

    func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(t: title)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.panelDeep, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.ink.opacity(0.06)))
    }

    @ViewBuilder var route: some View {
        if let p = store.peer(machine) {
            kv("PATH", !p.online ? "offline" : p.curAddr.isEmpty ? "relay · DERP \(p.relay.uppercased())" : "direct · \(p.curAddr)")
            kv("TAILNET", p.ip)
            if p.rx + p.tx > 0 { kv("RX / TX", "\(bytes(p.rx)) / \(bytes(p.tx))") }
            if let os = p.os, !os.isEmpty { kv("REPORTED", os) }
        } else {
            Text("external — not on your tailnet, reached over the internet").font(.mono(10)).foregroundStyle(Color.external)
        }
    }

    var accessSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            kv("KEY", machine.sshKey.isEmpty ? "auto (agent + ssh config)" : "~/.ssh/" + machine.sshKey)
            let creds = store.credentials(for: machine.id)
            kv("PASSWORDS", creds.isEmpty ? "none saved" : creds.map(\.user).joined(separator: ", ") + " · ⌘⇧P at a prompt")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: authVerified ? "checkmark.seal.fill" : auth == .unknown ? "seal" : "xmark.seal.fill")
                    .foregroundStyle(authVerified ? Color.ok : authDot)
                Text(authText).font(.mono(10)).foregroundStyle(authVerified ? Color.ok : Color.dim)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button { Task { await verifyAuth() } } label: { Label(busy ? "Testing…" : "Test", systemImage: "bolt.horizontal") }
                    .disabled(busy)
                Button { showInspector = true } label: { Label("Edit connection", systemImage: "slider.horizontal.3") }
            }
            .controlSize(.small)
        }
    }

    func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(k).font(.mono(9)).foregroundStyle(.dim).tracking(1).frame(width: 70, alignment: .leading)
            Text(v).font(.mono(10)).textSelection(.enabled)
        }
    }

    func openRDP() {
        Remote.rdp(ip: ip, user: rdpUser.trimmingCharacters(in: .whitespaces))
        store.log(.rdp, machine: machine, user: rdpUser)
    }

    // MARK: Status bar

    var statusBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(reach.color).frame(width: 6, height: 6)
                    .shadow(color: reach == .online ? Color.ok.opacity(0.7) : .clear, radius: 3)
                Text(reach.label)
                    .foregroundStyle(reach == .offline ? Color.dim : reach.color)
            }
            if let p = store.peer(machine), p.online {
                Text(p.curAddr.isEmpty ? "RELAY · DERP \(p.relay.uppercased())" : "DIRECT · \(p.curAddr)")
            }
            if machine.usesSSH {
                Text("\(machine.sshLogin)@\(machine.host)" + (machine.sshPort.isEmpty ? "" : ":" + machine.sshPort)
                     + (machine.sshKey.isEmpty ? "" : " · KEY " + machine.sshKey))
                Button { showInspector = true } label: {
                    Text(authVerified ? "✓ KEY AUTH" : "⚠ KEY AUTH NOT VERIFIED")
                        .foregroundStyle(authVerified ? Color.ok : Color.accent)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if !machine.os.isEmpty { Text(machine.os.uppercased()) }
            Text(machine.kind == .both ? "SSH + RDP" : machine.kind.rawValue.uppercased())
        }
        .font(.mono(9)).foregroundStyle(.dim).tracking(1).lineLimit(1)
        .padding(.horizontal, 12).frame(height: 24)
        .background(Color.panelDeep)
        .overlay(alignment: .top) { Rectangle().fill(Color.ink.opacity(0.06)).frame(height: 1) }
    }

    // MARK: Inspector

    var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                section("MACHINE") { machineFields }
                section("CONNECTION") { connection }
                if machine.usesSSH {
                    section("PASSWORDS · SUDO / ROOT") { PasswordsSection(machine: machine) }
                    section("TAB PRESETS") { presets }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.panelDeep)
    }

    func section<C: View>(_ t: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(t: t)
            content()
        }
    }

    var machineFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("NAME", "machine name", $name)
            field("OS", "windows / linux / macos", $os)
            HStack(spacing: 6) {
                Text("FOLDER").font(.mono(9)).foregroundStyle(.dim).tracking(1).frame(width: 74, alignment: .leading)
                FolderSelect(selection: live(\.folderId))
            }
            Picker("", selection: live(\.kind)) {
                Text("SSH").tag(Machine.Kind.ssh)
                Text("RDP").tag(Machine.Kind.rdp)
                Text("SSH + RDP").tag(Machine.Kind.both)
            }
            .pickerStyle(.segmented).labelsHidden()
            let tags = machine.tags
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { t in
                            TagChip(tag: t) { setTags(tags.filter { $0 != t }) }
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                TextField("add tag", text: $newTag)
                    .textFieldStyle(.roundedBorder).font(.mono(11))
                    .onSubmit(addTag)
                Menu {
                    ForEach(TagSuggestions.all.filter { !machine.tags.contains($0) }, id: \.self) { s in
                        Button(s) { newTag = s; addTag() }
                    }
                } label: { Image(systemName: "tag") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Tag suggestions")
            }
            Text(note ?? "changes save as you type").font(.mono(9)).foregroundStyle(.tertiary)
        }
    }

    func field(_ k: String, _ prompt: String, _ value: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(k).font(.mono(9)).foregroundStyle(.dim).tracking(1).frame(width: 74, alignment: .leading)
            TextField(prompt, text: value)
                .textFieldStyle(.roundedBorder).font(.mono(11))
        }
    }

    // MARK: Tab presets

    var presets: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(machine.sshTabs) { t in
                HStack(spacing: 8) {
                    Image(systemName: "terminal").foregroundStyle(Color.accent).font(.system(size: 10))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.name).font(.mono(11))
                        Text(t.command.isEmpty ? "interactive shell" : t.command)
                            .font(.mono(9)).foregroundStyle(.dim).lineLimit(1)
                    }
                    Spacer()
                    Button("Open") { terms.open(current, preset: t) }.controlSize(.small)
                    Button { removePreset(t) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).foregroundStyle(.dim).help("Remove preset")
                }
            }
            TextField("name — e.g. logs", text: $newTabName)
                .textFieldStyle(.roundedBorder).font(.mono(11))
                .onSubmit(addPreset)
            HStack(spacing: 6) {
                TextField("command on connect (optional)", text: $newTabCmd)
                    .textFieldStyle(.roundedBorder).font(.mono(11))
                    .onSubmit(addPreset)
                Button("Add") { addPreset() }
                    .disabled(newTabName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("presets show up under the + menu in the tab bar").font(.mono(9)).foregroundStyle(.tertiary)
        }
    }

    func addPreset() {
        let n = newTabName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        var m = machine
        m.sshTabs.append(SshTab(name: n, command: newTabCmd.trimmingCharacters(in: .whitespaces)))
        store.upsert(m)
        newTabName = ""
        newTabCmd = ""
    }

    func removePreset(_ t: SshTab) {
        var m = machine
        m.sshTabs.removeAll { $0.id == t.id }
        store.upsert(m)
    }

    // MARK: Connection (route, key, auth)

    var authVerified: Bool { auth == .ok || machine.authVerifiedAt != nil }

    var connection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                field("HOST / IP", "100.x.y.z or dns name", $host)
                Button { copyText(ip) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).foregroundStyle(.dim).help("Copy")
            }
            if machine.usesSSH {
                field("SSH USER", NSUserName(), $sshUser)
                field("PORT", "22", $sshPort)
                HStack(spacing: 6) {
                    Text("KEY").font(.mono(9)).foregroundStyle(.dim).tracking(1).frame(width: 74, alignment: .leading)
                    let sshKey = machine.sshKey
                    Picker("", selection: live(\.sshKey)) {
                        Text("auto — agent + ~/.ssh/config").tag("")
                        ForEach(keyNames + (sshKey.isEmpty || keyNames.contains(sshKey) ? [] : [sshKey]), id: \.self) {
                            Text("~/.ssh/" + $0).tag($0)
                        }
                    }
                    .labelsHidden().font(.mono(11))
                }
                field("OPTIONS", "-J bastion -o ServerAliveInterval=30", $sshOptions)
                Text("$ ssh " + machine.sshArgs.map { $0.contains(" ") ? Remote.q($0) : $0 }.joined(separator: " ")
                        .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.mono(9)).foregroundStyle(.dim).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.bg, in: RoundedRectangle(cornerRadius: 5))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: authVerified ? "checkmark.seal.fill" : auth == .unknown ? "seal" : "xmark.seal.fill")
                        .foregroundStyle(authVerified ? Color.ok : authDot)
                    Text(authText).font(.mono(10)).foregroundStyle(authVerified ? Color.ok : Color.dim)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    Button { Task { await verifyAuth() } } label: {
                        Label(busy ? "Testing…" : "Test connection", systemImage: "bolt.horizontal")
                    }
                    .disabled(busy)
                    if !authVerified, let pub = installablePub {
                        Button { Remote.installKey(current, pub: pub) } label: {
                            Label("Install key…", systemImage: "square.and.arrow.down")
                        }
                        .help("ssh-copy-id \((pub as NSString).lastPathComponent) in Ghostty — asks for the password once")
                    }
                }
                .controlSize(.small)
                if !authVerified && installablePub == nil {
                    Text("no public key found — import or generate one in Keys").font(.mono(9)).foregroundStyle(.bad)
                }
            }
            if machine.usesRDP { field("RDP USER", "optional — client prompts", $rdpUser) }
        }
    }

    /// The chosen key's .pub, else the default one.
    var installablePub: String? {
        let key = machine.sshKey
        if !key.isEmpty { return FileManager.default.fileExists(atPath: SSHKeys.pubPath(key)) ? SSHKeys.pubPath(key) : nil }
        return SSHKeys.defaultPub()
    }

    var authDot: Color {
        switch auth {
        case .unknown: return Color.ledOff
        case .ok: return .ok
        case .fail: return .bad
        }
    }

    @State private var authDetail = ""

    var authText: String {
        if case .fail(let m) = auth { return m }
        if authVerified {
            let when = machine.authVerifiedAt.map { " · " + $0.formatted(.relative(presentation: .named)) } ?? ""
            return (authDetail.isEmpty ? "key auth verified" : authDetail) + when
        }
        return "not verified — Test tries key-only login (never a password prompt)"
    }

    // MARK: Specs

    var specsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let specs {
                ForEach(specs) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(r.label.uppercased()).font(.mono(9)).foregroundStyle(.dim)
                            .frame(width: 64, alignment: .leading).tracking(1)
                        Text(r.value).font(.mono(10)).textSelection(.enabled)
                            .foregroundStyle(r.label == "error" ? Color.bad : Color.primary)
                    }
                }
            } else {
                Text("uname / nproc / free / df / uptime over SSH").font(.mono(9)).foregroundStyle(.tertiary)
            }
            Button { Task { await fetchSpecs() } } label: {
                Label(busy ? "Fetching…" : "Fetch", systemImage: "arrow.clockwise")
            }
            .controlSize(.small).disabled(busy)
        }
    }

    // MARK: Helpers

    @MainActor func verifyAuth(silent: Bool = false) async {
        busy = true
        defer { busy = false }
        let target = current
        let t0 = Date()
        let (code, out) = await Shell.run(Remote.sshCommand(target, command: Remote.okCheck, verbose: true))
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let report = Remote.authReport(out, ok: code == 0)
        // re-read after the await — and if the route was edited mid-test, this result is about the old one
        guard var m = store.machines.first(where: { $0.id == target.id }), m.sshArgs == target.sshArgs else { return }
        if code == 0 {
            auth = .ok
            authDetail = report
            m.authVerifiedAt = Date()
            store.upsert(m)
            if !silent { store.log(.verify, machine: m, detail: report, user: target.sshLogin, durationMs: ms) }
        } else {
            auth = .fail("✗ " + report)
            if m.authVerifiedAt != nil {
                m.authVerifiedAt = nil   // failed re-verify → show the problem
                store.upsert(m)
            }
            if !silent { store.log(.verify, machine: m, detail: "failed: " + report, user: target.sshLogin, durationMs: ms) }
        }
    }

    @MainActor func fetchSpecs() async {
        busy = true
        defer { busy = false }
        let t0 = Date()
        let cmd = "uname -sr; echo ---; nproc; echo ---; free -h 2>/dev/null | sed -n 2p; echo ---; df -h / 2>/dev/null | sed -n 2p; echo ---; uptime"
        let (code, out) = await Shell.run(Remote.sshCommand(current, command: cmd))
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        store.log(.specs, machine: machine, detail: code == 0 ? "fetched" : "failed", user: sshUser, durationMs: ms)
        guard code == 0 else {
            specs = [SpecRow(label: "error", value: String(out.prefix(300)))]
            return
        }
        let parts = out.components(separatedBy: "---").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let labels = ["kernel", "cores", "memory", "disk /", "load"]
        specs = labels.enumerated().map { i, l in
            SpecRow(label: l, value: i < parts.count && !parts[i].isEmpty ? parts[i] : "—")
        }
    }

    @MainActor func copyText(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        note = "copied \(s)"
    }

    // MARK: Session history (encrypted log)

    static let sessionFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var sessionHistory: some View {
        let mine = store.sessions.filter { $0.machineId == machine.id }
        return Group {
            if mine.isEmpty {
                Text("no sessions yet — every SSH / RDP launch is recorded, encrypted at rest (AES-256-GCM)")
                    .font(.mono(9)).foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(mine.prefix(10)) { s in
                        HStack(spacing: 8) {
                            Text(Self.sessionFmt.string(from: s.at)).font(.mono(9)).foregroundStyle(.tertiary)
                            Text(s.kind.rawValue.uppercased())
                                .font(.mono(9)).foregroundStyle(Color.accent)
                                .frame(width: 52, alignment: .leading)
                            Text(s.detail).font(.mono(9)).foregroundStyle(.dim).lineLimit(1)
                            Spacer()
                            if let ms = s.durationMs { Text("\(ms)ms").font(.mono(8)).foregroundStyle(.tertiary) }
                        }
                    }
                    if mine.count > 10 {
                        Text("+\(mine.count - 10) older — last \(DB.maxSessions) kept app-wide")
                            .font(.mono(8)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

// MARK: - Machine strip: every connected machine as a tab above every page — click, ⌃1…⌃9 or ⌃Tab to hop

struct MachineStrip: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var terms: Terminals

    var body: some View {
        let live = terms.liveMachines.compactMap { id in store.machines.first { $0.id == id } }
        if !live.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(live.enumerated()), id: \.element.id) { i, m in
                    MachineTab(m: m, index: i, active: store.selection == .machine(m.id))
                }
                Spacer(minLength: 0)
                Text("⌃Tab").font(.mono(9)).foregroundStyle(.tertiary).padding(.horizontal, 12)
                    .help("⌃Tab / ⌃⇧Tab: next / previous machine · ⌃1…⌃9: jump to one — from any page")
            }
            .frame(height: 30)
            .background(Color.bg)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.ink.opacity(0.06)).frame(height: 1) }
        }
    }
}

private struct MachineTab: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var terms: Terminals
    let m: Machine
    let index: Int
    let active: Bool
    @State private var hover = false

    var body: some View {
        let reach = store.reach(m), tabs = terms.tabs(m.id).count
        HStack(spacing: 7) {
            Circle().fill(reach.color).frame(width: 6, height: 6)
                .shadow(color: reach == .online ? Color.ok.opacity(0.6) : .clear, radius: 3)
            Text(m.name.isEmpty ? m.host : m.name).font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.primary : Color.dim).lineLimit(1).truncationMode(.middle)
            if tabs > 1 { Text("\(tabs)").font(.mono(9)).foregroundStyle(.tertiary).help("\(tabs) tabs open") }
            Spacer(minLength: 4)
            if hover {
                Button { terms.disconnect(m.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 16, height: 16)
                        .background(Circle().fill(Color.ink.opacity(0.08)))
                }
                .buttonStyle(.plain).foregroundStyle(.dim).help("Disconnect — close every tab on this machine")
            } else if index < 9 {
                Text("⌃\(index + 1)").font(.mono(9)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 120, maxWidth: 220, maxHeight: .infinity)
        .background(active ? Color.panelDeep : hover ? Color.ink.opacity(0.03) : .clear)
        .overlay(alignment: .top) { if active { Rectangle().fill(Color.accent).frame(height: 2) } }
        .overlay(alignment: .trailing) { Rectangle().fill(Color.ink.opacity(0.07)).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture { store.selection = .machine(m.id) }
        .onHover { hover = $0 }
        .contextMenu { Button("Disconnect") { terms.disconnect(m.id) } }
        .help(m.host)
    }
}

// MARK: - Ghostty-style tab strip: equal-width tabs, ✕ on hover, + at the end

struct TermTabBar: View {
    @EnvironmentObject private var terms: Terminals
    let machine: Machine
    var managePresets: () -> Void

    var body: some View {
        let tabs = terms.tabs(machine.id)
        let current = terms.current(machine.id)?.id
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { i, s in
                if i > 0 { Rectangle().fill(Color.ink.opacity(0.07)).frame(width: 1, height: 16) }
                TermTab(s: s, index: i, active: s.id == current,
                        select: { terms.active[machine.id] = s.id },
                        close: { terms.close(s) })
            }
            if tabs.isEmpty { Spacer() }
            Rectangle().fill(Color.ink.opacity(0.07)).frame(width: 1, height: 16)
            PasswordMenu(machine: machine, session: terms.current(machine.id))
            Menu {
                Button("Shell") { terms.open(machine) }
                Button("htop") { terms.open(machine, preset: SshTab(name: "htop", command: "htop")) }
                // the old auto-added "shell" preset duplicates the Shell item above
                let saved = machine.sshTabs.filter { !($0.name == "shell" && $0.command.isEmpty) }
                if !saved.isEmpty {
                    Divider()
                    ForEach(saved) { t in Button(t.name) { terms.open(machine, preset: t) } }
                }
                Divider()
                Button("Manage presets…", action: managePresets)
            } label: {
                Image(systemName: "plus")
            } primaryAction: {
                terms.open(machine)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 12)
            .help("New tab ⌘T — click and hold for presets")
        }
        .frame(height: 32)
        .background(Color.panelDeep)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.ink.opacity(0.06)).frame(height: 1) }
    }
}

private struct TermTab: View {
    @ObservedObject var s: TermSession
    let index: Int
    let active: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.ink.opacity(0.08)))
            }
            .buttonStyle(.plain).foregroundStyle(.dim)
            .opacity(hover ? 1 : 0)
            .help("Close tab ⌘W")
            Spacer(minLength: 0)
            if s.ended { Circle().fill(Color.bad).frame(width: 5, height: 5) }
            Text(s.title).font(.mono(11)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(active ? Color.primary : Color.dim)
            Spacer(minLength: 0)
            Text(index < 9 ? "⌘\(index + 1)" : "").font(.mono(9)).foregroundStyle(.tertiary)
                .frame(width: 22, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(active ? Color.ink.opacity(0.07) : hover ? Color.ink.opacity(0.03) : .clear)
        .overlay(alignment: .top) { if active { Rectangle().fill(Color.accent).frame(height: 2) } }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hover = $0 }
    }
}

/// Non-zero exit keeps the tab so you can read ssh's error.
private struct EndedBanner: View {
    @ObservedObject var s: TermSession
    let reconnect: () -> Void
    let close: () -> Void

    var body: some View {
        if s.ended {
            HStack(spacing: 10) {
                Circle().fill(Color.bad).frame(width: 6, height: 6)
                Text("SESSION ENDED" + (s.exitCode.map { " · EXIT \($0)" } ?? ""))
                    .font(.mono(10)).foregroundStyle(.dim).tracking(1)
                Button("Reconnect", action: reconnect)   // click only — a stray ⏎ must never open a connection
                Button("Close", action: close)
            }
            .controlSize(.small)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.ink.opacity(0.08)))
            .padding(16)
        }
    }
}
