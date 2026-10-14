import SwiftUI

struct SectionLabel: View {
    let t: String
    var body: some View { Text(t).font(.mono(10)).foregroundStyle(Color.dim).tracking(2) }
}

public struct ContentView: View {
    @EnvironmentObject private var store: Store
    @State private var query = ""
    @State private var addIn: String?          // folder for the Add sheet ("" = top level)
    @State private var prompt: FolderPrompt?
    @State private var promptText = ""
    @AppStorage("theme") private var theme = Theme.graphite

    public init() {}

    var filtered: [Machine] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.machines }
        return store.machines.filter {
            [$0.name, $0.host, $0.os, $0.tags.joined()].joined().lowercased().contains(q)
        }
    }

    public var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            VStack(spacing: 0) {
                MachineStrip()
                detail
            }
        }
        .id(theme)   // colors are read at render time — rebuild everything under the new palette
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ExitNodeMenu()
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help(store.lastUpdated.map { "Refresh tailnet · updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "Refresh tailnet")
                Menu {
                    Picker("Theme", selection: $theme) { ForEach(Theme.allCases) { Text($0.name).tag($0) } }
                        .pickerStyle(.inline)
                } label: { Label("Theme", systemImage: "paintpalette") }
                .help("Theme · \(theme.name)")
            }
        }
        .toolbarBackground(Color.bg, for: .windowToolbar)
        .frame(minWidth: 1040, minHeight: 640)
        .background(Color.bg)
        .preferredColorScheme(theme.scheme)
        .environmentObject(store.terms)
        .environmentObject(store.cloud)
        .environmentObject(store.inbox)
        .environmentObject(store.claude)
        .environmentObject(store.board)
        .task { store.updateBadge(); await pollLoop() }
        .task { await store.cloud.run() }
        .sheet(isPresented: Binding(get: { addIn != nil }, set: { if !$0 { addIn = nil } })) {
            AddMachineSheet(folder: addIn ?? "")
        }
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField("folder name", text: $promptText)
            Button(prompt?.action ?? "OK") { applyPrompt() }
            Button("Cancel", role: .cancel) { prompt = nil }
        }
    }

    func ask(_ p: FolderPrompt) {
        if case .rename(let f) = p { promptText = f.name } else { promptText = "" }
        prompt = p
    }

    func applyPrompt() {
        switch prompt {
        case .new(let parent, let machine):
            if let f = store.addFolder(promptText, in: parent), let m = machine { store.move(machine: m, to: f.id) }
        case .rename(let f):
            store.renameFolder(f.id, to: promptText)
        case nil: break
        }
        prompt = nil
    }

    @ViewBuilder var detail: some View {
        switch store.selection {
        case .keys:
            KeysView()
        case .cloud:
            CloudView()
        case .pipelines:
            PipelinesView()
        case .orchestrate:
            OrchestrateView()
        case .snippets:
            SnippetsView()
        case .docs:
            DocsView()
        case .machine(let id):
            if let m = store.machines.first(where: { $0.id == id }) { MachineDetailView(machine: m) } else { OverviewView() }
        default:
            OverviewView()
        }
    }

    var sidebar: some View {
        List(selection: $store.selection) {
            Section {
                Label("Overview", systemImage: "point.3.filled.connected.trianglepath.dotted").tag(Route.overview)
                PipelinesSidebarLabel().tag(Route.pipelines)
                Label("Orchestrate", systemImage: "sparkles").tag(Route.orchestrate)
                CloudSidebarLabel().tag(Route.cloud)
                Label("Keys", systemImage: "key.horizontal").tag(Route.keys)
                Label("Snippets", systemImage: "curlybraces").tag(Route.snippets)
                Label("Docs", systemImage: "book.closed").tag(Route.docs)
            }
            Section {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    FolderTree(parent: "", ask: ask, addMachine: { addIn = $0 })
                    if store.machines.isEmpty && store.folders.isEmpty {
                        Text("add a machine below, or a folder with ⊕").font(.mono(10)).foregroundStyle(.tertiary)
                    }
                } else {
                    ForEach(filtered) { m in MachineRow(m: m, ask: ask, showPath: true).tag(Route.machine(m.id)) }
                }
            } header: {
                MachinesHeader { ask(.new(parent: "", machine: nil)) }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.panelDeep)
        .searchable(text: $query, placement: .sidebar, prompt: "Filter machines")
        .safeAreaInset(edge: .top) { topBanner.padding(.horizontal, 10) }
        .safeAreaInset(edge: .bottom) { SidebarFooter { addIn = "" } }
    }

    @ViewBuilder var topBanner: some View {
        if store.binMissing {
            banner("TAILSCALE CLI NOT FOUND — install Tailscale, then re-run install.sh", .bad)
        } else if let e = store.error {
            banner(e, .bad)
        } else if !store.backendState.isEmpty && store.backendState != "Running" {
            banner("TAILSCALE STATE: \(store.backendState) — run `tailscale up`", .accent)
        } else if !store.health.isEmpty {
            banner(store.health.joined(separator: " · "), .accent)
        }
    }

    func banner(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(color)
            Text(text).font(.mono(10)).foregroundStyle(color).lineLimit(3)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    func pollLoop() async {
        while !Task.isCancelled {
            await store.refresh()
            store.inbox.start()               // no-op once listening; retries a busy port
            await store.inbox.refreshHTTPS()
            try? await Task.sleep(for: .seconds(15))
        }
    }
}

enum FolderPrompt {
    case new(parent: String, machine: String?)   // machine: move it into the new folder
    case rename(Folder)
    var title: String { if case .rename = self { return "Rename folder" } else { return "New folder" } }
    var action: String { if case .rename = self { return "Rename" } else { return "Create" } }
}

/// "MACHINES" header — also the drop zone for moving things back to the top level.
struct MachinesHeader: View {
    @EnvironmentObject private var store: Store
    let newFolder: () -> Void
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 6) {
            Text("MACHINES").font(.mono(10)).tracking(2)
            if targeted { Text("→ top level").font(.mono(9)).foregroundStyle(Color.accent) }
            Spacer()
            Button(action: newFolder) { Image(systemName: "folder.badge.plus") }
                .buttonStyle(.borderless).help("New folder")
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in store.drop(items, into: "") } isTargeted: { targeted = $0 }
    }
}

/// VMware-style library tree: folders (sorted by name) then machines (your drag order), recursively.
struct FolderTree: View {
    @EnvironmentObject private var store: Store
    @AppStorage("collapsedFolders") private var collapsedRaw = ""
    let parent: String
    let ask: (FolderPrompt) -> Void
    let addMachine: (String) -> Void

    var body: some View {
        ForEach(store.folders(in: parent)) { f in
            DisclosureGroup(isExpanded: expanded(f.id)) {
                FolderTree(parent: f.id, ask: ask, addMachine: addMachine)
            } label: {
                FolderRow(folder: f, ask: ask, addMachine: addMachine, reveal: { expanded(f.id).wrappedValue = true })
            }
        }
        ForEach(store.machines(in: parent)) { m in
            MachineRow(m: m, ask: ask).tag(Route.machine(m.id))
        }
        if !parent.isEmpty && store.folders(in: parent).isEmpty && store.machines(in: parent).isEmpty {
            Text("empty — drag machines here").font(.mono(9)).foregroundStyle(.tertiary)
                .dropDestination(for: String.self) { items, _ in store.drop(items, into: parent) }
        }
    }

    var collapsed: Set<String> { Set(collapsedRaw.split(separator: " ").map(String.init)) }

    func expanded(_ id: String) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(id) }, set: { open in
            var c = collapsed
            if open { c.remove(id) } else { c.insert(id) }
            collapsedRaw = c.sorted().joined(separator: " ")
        })
    }
}

struct FolderRow: View {
    @EnvironmentObject private var store: Store
    let folder: Folder
    let ask: (FolderPrompt) -> Void
    let addMachine: (String) -> Void
    let reveal: () -> Void
    @State private var targeted = false

    var body: some View {
        let ms = store.allMachines(under: folder.id)
        HStack(spacing: 7) {
            Image(systemName: targeted ? "folder.fill.badge.plus" : "folder.fill")
                .foregroundStyle(folder.tint)
            Text(folder.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer()
            if !ms.isEmpty {
                Text("\(ms.filter { store.online($0) == true }.count)/\(ms.count)").font(.mono(9)).foregroundStyle(.tertiary)
                    .help("online / machines in this folder")
            }
        }
        .padding(.vertical, 2).padding(.horizontal, 4)
        .background(targeted ? Color.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .draggable("f:" + folder.id) {
            Label(folder.name, systemImage: "folder.fill").padding(6).background(Color.panelDeep, in: RoundedRectangle(cornerRadius: 6))
        }
        .dropDestination(for: String.self) { items, _ in
            let ok = store.drop(items, into: folder.id)
            if ok { reveal() }
            return ok
        } isTargeted: { targeted = $0 }
        .contextMenu {
            Button("Add machine here…") { addMachine(folder.id) }
            Button("New subfolder…") { ask(.new(parent: folder.id, machine: nil)) }
            Button("Rename…") { ask(.rename(folder)) }
            Menu("Color") {
                ForEach(Folder.palette, id: \.hex) { c in
                    Toggle(c.name, isOn: Binding(get: { folder.color == c.hex }, set: { _ in store.setColor(folder.id, c.hex) }))
                }
                Divider()
                Toggle("Automatic", isOn: Binding(get: { folder.color.isEmpty }, set: { _ in store.setColor(folder.id, "") }))
            }
            Menu("Move to") {
                if !folder.parent.isEmpty { Button("Top level") { store.move(folder: folder.id, into: "") } }
                FolderPicker(parent: "", exclude: folder.id) { store.move(folder: folder.id, into: $0) }
            }
            Divider()
            Button("Delete folder (keeps machines)", role: .destructive) { store.deleteFolder(folder.id) }
        }
    }
}

/// Folder tree as nested menus; `exclude` hides a folder's own subtree (you can't move it into itself).
struct FolderPicker: View {
    @EnvironmentObject private var store: Store
    let parent: String
    var exclude: String? = nil
    let pick: (String) -> Void

    var body: some View {
        ForEach(store.folders(in: parent).filter { $0.id != exclude }) { f in
            if store.folders(in: f.id).contains(where: { $0.id != exclude }) {
                Menu(f.name) {
                    Button("Into \(f.name)") { pick(f.id) }
                    Divider()
                    FolderPicker(parent: f.id, exclude: exclude, pick: pick)
                }
            } else {
                Button(f.name) { pick(f.id) }
            }
        }
    }
}

struct CloudSidebarLabel: View {
    @EnvironmentObject private var cloud: Transfers
    var body: some View {
        Label("Cloud", systemImage: "icloud.and.arrow.up").badge(cloud.active.count)
    }
}

/// Add machine + the kill switch: every live session, one click.
struct SidebarFooter: View {
    @EnvironmentObject private var terms: Terminals
    let add: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: add) { Label("Add machine", systemImage: "plus") }
                .buttonStyle(.borderless)
            Spacer()
            if !terms.sessions.isEmpty {
                Button { terms.disconnectAll() } label: {
                    HStack(spacing: 5) {
                        Circle().fill(Color.accent).frame(width: 6, height: 6).shadow(color: .accent, radius: 3)
                        Text("\(terms.sessions.count) LIVE").font(.mono(9).weight(.semibold)).tracking(1)
                        Image(systemName: "power").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.bad)
                    }
                }
                .buttonStyle(.borderless)
                .help("Disconnect all — close every SSH tab on every machine")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12).padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(Color.ink.opacity(0.06)).frame(height: 1) }
    }
}

/// Own view so it observes Terminals — the live badge stays current.
struct MachineRow: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var terms: Terminals
    let m: Machine
    let ask: (FolderPrompt) -> Void
    var showPath = false
    @State private var targeted = false

    var body: some View {
        let reach = store.reach(m)
        let tabs = terms.tabs(m.id).count
        return HStack(spacing: 10) {
            Circle().fill(reach.color).frame(width: 7, height: 7)
                .shadow(color: reach == .online ? Color.ok.opacity(0.6) : .clear, radius: 3)
                .help(reach == .external ? "external — not on your tailnet" : reach.label.lowercased())
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name.isEmpty ? m.host : m.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(showPath && !store.path(m.folderId).isEmpty
                     ? store.path(m.folderId).map(\.name).joined(separator: " › ") : m.host)
                    .font(.mono(10)).foregroundStyle(.dim).lineLimit(1)
            }
            Spacer()
            if tabs > 0 {
                Text("LIVE \(tabs)").font(.mono(8).weight(.bold)).tracking(0.5).foregroundStyle(Color.bg)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.accent, in: Capsule())
                    .help("connected — \(tabs) tab\(tabs == 1 ? "" : "s") open")
            } else {
                Text(m.kind == .both ? "SSH+RDP" : m.kind.rawValue.uppercased()).font(.mono(9)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
        .overlay(alignment: .top) {   // drop indicator: lands just above this machine
            if targeted { Rectangle().fill(Color.accent).frame(height: 2).offset(y: -3) }
        }
        .draggable("m:" + m.id) {
            Label(m.name.isEmpty ? m.host : m.name, systemImage: osIcon(m.os))
                .padding(6).background(Color.panelDeep, in: RoundedRectangle(cornerRadius: 6))
        }
        .dropDestination(for: String.self) { items, _ in
            store.drop(items, into: m.folderId, before: m.id)
        } isTargeted: { targeted = $0 }
        .contextMenu {
            if tabs > 0 { Button("Disconnect") { terms.disconnect(m.id) } }
            Menu("Move to") {
                if !m.folderId.isEmpty { Button("Top level") { store.move(machine: m.id, to: "") } }
                FolderPicker(parent: "") { store.move(machine: m.id, to: $0) }
                Divider()
                Button("New folder…") { ask(.new(parent: m.folderId, machine: m.id)) }
            }
            Divider()
            Button("Delete", role: .destructive) { store.remove(m) }
        }
    }
}

/// Toolbar dropdown: route through your own exit nodes or any Mullvad city.
struct ExitNodeMenu: View {
    @EnvironmentObject private var store: Store

    var own: [DiscoveredPeer] { store.exitNodes.filter { !$0.isMullvad } }
    /// country → city → best node (online, highest Mullvad priority)
    var mullvad: [(country: String, code: String, cities: [(city: String, node: DiscoveredPeer)])] {
        let byCountry = Dictionary(grouping: store.exitNodes.filter(\.isMullvad)) { $0.location?.Country ?? "?" }
        return byCountry.map { country, nodes in
            let byCity = Dictionary(grouping: nodes) { $0.location?.City ?? "?" }
            let cities = byCity.compactMap { city, ns -> (String, DiscoveredPeer)? in
                let best = ns.filter(\.online).max { ($0.location?.Priority ?? 0) < ($1.location?.Priority ?? 0) }
                return best.map { (city, $0) }
            }.sorted { $0.0 < $1.0 }
            return (country, nodes.first?.location?.CountryCode ?? "", cities.map { (city: $0.0, node: $0.1) })
        }
        .filter { !$0.cities.isEmpty }
        .sorted { $0.country < $1.country }
    }

    var label: String {
        guard let e = store.exitNode else { return "DIRECT" }
        if let l = e.location { return "\(flag(l.CountryCode)) \(l.City ?? e.hostName)" }
        return e.hostName
    }

    var body: some View {
        Menu {
            pick("Direct — no exit node", nil)
            if !own.isEmpty {
                Section("Your exit nodes") { ForEach(own) { pick($0.hostName + ($0.online ? "" : " · offline"), $0) } }
            }
            if !mullvad.isEmpty {
                Section("Mullvad") {
                    ForEach(mullvad, id: \.country) { c in
                        Menu("\(flag(c.code))  \(c.country)") {
                            ForEach(c.cities, id: \.city) { pick($0.city, $0.node) }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: store.exitNode == nil ? "globe" : "lock.shield.fill")
                    .foregroundStyle(store.exitNode == nil ? Color.dim : Color.ok)
                Text("EXIT").font(.mono(9)).foregroundStyle(.dim).tracking(1.5)
                Text(store.switchingExit ? "switching…" : label).font(.mono(11))
            }
        }
        .disabled(store.binMissing || store.switchingExit)
        .help("Exit node — route this Mac's internet traffic through a tailnet node or Mullvad")
    }

    /// Toggle renders a native checkmark on the active choice.
    func pick(_ title: String, _ node: DiscoveredPeer?) -> some View {
        let isOn = node.map { n in store.exitNode?.ip == n.ip || (n.isMullvad && store.exitNode?.location?.City == n.location?.City && store.exitNode?.location?.Country == n.location?.Country) } ?? (store.exitNode == nil)
        return Toggle(title, isOn: Binding(get: { isOn }, set: { _ in Task { await store.setExitNode(node) } }))
    }
}

struct AddMachineSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var folder = ""
    @State private var name = ""
    @State private var host = ""
    @State private var os = ""
    @State private var sshUser = NSUserName()
    @State private var rdpUser = ""
    @State private var tagsStr = ""
    @State private var kind: Machine.Kind = .both
    @State private var pick: DiscoveredPeer?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ADD MACHINE").font(.mono(11)).foregroundStyle(.dim).tracking(2)
            if !store.discovered.isEmpty {
                Picker("Prefill from tailnet", selection: $pick) {
                    Text("— manual entry —").tag(DiscoveredPeer?.none)
                    ForEach(store.discovered) { p in
                        Text("\(p.hostName) · \(p.ip) · \(p.os ?? "?")\(p.online ? "" : " · offline")")
                            .tag(DiscoveredPeer?.some(p))
                    }
                }
                .onChange(of: pick) { _, v in
                    if let v {
                        name = v.hostName
                        host = v.ip
                        os = v.os ?? ""
                        pick = nil
                    }
                }
            }
            field("NAME", "e.g. AI Dev Box", $name)
            field("HOST / IP", "100.x.y.z or dns name", $host)
            field("OS", "windows / linux / macos", $os)
            Picker("TYPE", selection: $kind) {
                Text("SSH").tag(Machine.Kind.ssh)
                Text("RDP").tag(Machine.Kind.rdp)
                Text("SSH + RDP").tag(Machine.Kind.both)
            }
            .pickerStyle(.segmented)
            field("SSH USER", NSUserName(), $sshUser)
            field("RDP USER", "optional", $rdpUser)
            HStack(spacing: 0) {
                Text("FOLDER").font(.mono(10)).foregroundStyle(.dim).frame(width: 100, alignment: .leading).tracking(1)
                FolderSelect(selection: $folder)
            }
            field("TAGS", "comma separated", $tagsStr)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 480)
        .preferredColorScheme(Theme.current.scheme)
    }

    func add() {
        var m = Machine(id: UUID().uuidString)
        let n = name.trimmingCharacters(in: .whitespaces)
        m.name = n.isEmpty ? host.trimmingCharacters(in: .whitespaces) : n
        m.host = host.trimmingCharacters(in: .whitespaces)
        m.os = os.trimmingCharacters(in: .whitespaces)
        m.kind = kind
        m.sshUser = sshUser.trimmingCharacters(in: .whitespaces)
        m.rdpUser = rdpUser.trimmingCharacters(in: .whitespaces)
        m.folderId = folder
        m.tags = tagsStr.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        store.machines.append(m)
        store.selection = .machine(m.id)
        store.log(.machineAdd, machine: m)
        dismiss()
    }

    func field(_ label: String, _ prompt: String, _ b: Binding<String>) -> some View {
        HStack(spacing: 0) {
            Text(label).font(.mono(10)).foregroundStyle(.dim).frame(width: 100, alignment: .leading).tracking(1)
            TextField(prompt, text: b).textFieldStyle(.roundedBorder).font(.mono(11))
        }
    }
}

/// Flat folder picker with indented paths — for forms (Add sheet, inspector).
struct FolderSelect: View {
    @EnvironmentObject private var store: Store
    @Binding var selection: String

    var body: some View {
        Picker("", selection: $selection) {
            Text("— top level —").tag("")
            ForEach(store.flatTree(), id: \.folder.id) { row in
                Text(String(repeating: "    ", count: row.depth) + row.folder.name).tag(row.folder.id)
            }
        }
        .labelsHidden()
    }
}
