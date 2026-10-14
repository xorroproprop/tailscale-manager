import SwiftUI

// MARK: - Overview: tailnet topology — Tailscale in the middle, your machines on the ring

struct OverviewView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var terms: Terminals
    @EnvironmentObject private var cloud: Transfers
    @State private var hover: String?

    struct Node: Identifiable {
        let id: String
        let name: String
        let host: String
        let os: String
        let online: Bool?
        let peer: DiscoveredPeer?
        var reach: Reach = .unknown
        let tabs: Int
        var isSelf = false
        var group: Folder? = nil   // top-level folder — one band per company
        var uploads: [Transfer] = []
        var point = CGPoint.zero
    }

    static let hubR: CGFloat = 46, nodeR: CGFloat = 26

    var nodes: [Node] {
        var out: [Node] = []
        if let me = store.me {
            out.append(Node(id: "self", name: "this mac", host: me.ip, os: "macos", online: true, peer: me, tabs: 0,
                            isSelf: true, uploads: cloud.on(Transfers.local.id)))
        }
        // sidebar tree order: each top-level folder's machines sit together on the ring, loose ones last
        for m in store.treeOrder() {
            let p = store.peer(m)
            out.append(Node(id: m.id, name: m.name.isEmpty ? m.host : m.name, host: m.host,
                            os: m.os.isEmpty ? p?.os ?? "" : m.os, online: p?.online, peer: p, reach: store.reach(m),
                            tabs: terms.tabs(m.id).count, group: store.path(m.folderId).first,
                            uploads: cloud.on(m.id)))
        }
        return out
    }

    func radii(_ size: CGSize) -> CGSize { CGSize(width: max(170, size.width / 2 - 140), height: max(130, size.height / 2 - 100)) }
    func angle(_ i: Int, of n: Int) -> Double { Double.pi / 2 + 2 * .pi * Double(i) / Double(max(n, 1)) }
    func cloudPoint(_ size: CGSize) -> CGPoint { CGPoint(x: size.width - 100, y: 92) }

    /// One ellipse, this Mac anchored at the bottom.
    // ponytail: single ring gets crowded past ~16 machines — add a second ring then
    func layout(_ ns: [Node], _ size: CGSize) -> [Node] {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = radii(size)
        return ns.enumerated().map { i, n in
            var n = n
            let a = angle(i, of: ns.count)
            n.point = CGPoint(x: c.x + r.width * cos(a), y: c.y + r.height * sin(a))
            return n
        }
    }

    var body: some View {
        GeometryReader { geo in
            let ns = layout(nodes, geo.size)
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let cp = cloudPoint(geo.size)
            ZStack {
                DotGrid()
                Canvas { ctx, size in drawGroups(&ctx, ns, size) }
                TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
                    Canvas { ctx, _ in
                        let t = tl.date.timeIntervalSinceReferenceDate
                        for n in ns { drawLink(&ctx, n, from: c, t: t) }
                        for n in ns where !n.uploads.isEmpty { drawUpload(&ctx, n, to: cp, t: t) }
                    }
                }
                Hub().position(c)
                if !cloud.active.isEmpty {
                    CloudNode(transfers: cloud.active).position(cp)
                        .onTapGesture { store.selection = .cloud }
                }
                ForEach(ns) { n in
                    NodeView(n: n, hovered: hover == n.id)
                        .position(n.point)
                        .zIndex(hover == n.id ? 1 : 0)
                        .onHover { hover = $0 ? n.id : (hover == n.id ? nil : hover) }
                        .onTapGesture { if !n.isSelf { store.selection = .machine(n.id) } }
                }
                if store.machines.isEmpty {
                    Text("add machines with + in the sidebar — only yours show here, never the Mullvad fleet")
                        .font(.mono(10)).foregroundStyle(.tertiary)
                        .position(x: c.x, y: c.y + Self.hubR + 40)
                }
            }
        }
        .overlay(alignment: .topLeading) { readout.padding(22) }
        .overlay(alignment: .bottomLeading) { legend.padding(22) }
        .background(Color.bg)
        .navigationTitle("Overview")
    }

    // MARK: Links

    struct LinkStyle { var color: Color; var dash: [CGFloat] = []; var label = ""; var flowing = false }

    func style(_ n: Node) -> LinkStyle {
        if n.isSelf { return LinkStyle(color: .accent, flowing: true) }
        guard let p = n.peer else { return LinkStyle(color: .external.opacity(0.7), dash: [1, 5], label: n.reach == .external ? "EXTERNAL" : "") }
        guard p.online else { return LinkStyle(color: .ledOff, dash: [3, 6]) }
        let busy = n.tabs > 0 || p.active
        return p.curAddr.isEmpty
            ? LinkStyle(color: .ok, dash: [6, 5], label: p.relay.isEmpty ? "RELAY" : "DERP·" + p.relay.uppercased(), flowing: busy)
            : LinkStyle(color: .ok, label: "DIRECT", flowing: busy)
    }

    func drawLink(_ ctx: inout GraphicsContext, _ n: Node, from c: CGPoint, t: Double) {
        let dx = n.point.x - c.x, dy = n.point.y - c.y
        let len = max(hypot(dx, dy), 1)
        let u = CGPoint(x: dx / len, y: dy / len)
        let a = CGPoint(x: c.x + u.x * Self.hubR, y: c.y + u.y * Self.hubR)
        let b = CGPoint(x: n.point.x - u.x * (Self.nodeR + 4), y: n.point.y - u.y * (Self.nodeR + 4))
        let s = style(n)
        let hot = hover == n.id
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        ctx.stroke(path, with: .color(s.color.opacity(hot ? 0.95 : s.flowing ? 0.6 : 0.32)),
                   style: StrokeStyle(lineWidth: hot || n.tabs > 0 ? 1.8 : 1.1, lineCap: .round,
                                      dash: s.dash, dashPhase: s.flowing ? -t * 14 : 0))
        if s.flowing {   // packets both ways; more when you have sessions open
            let count = n.tabs > 0 ? 4 : 2
            let seed = Double(abs(n.id.hashValue % 997)) / 997
            for k in 0..<count {
                var f = (t * 0.28 + seed + Double(k) / Double(count)).truncatingRemainder(dividingBy: 1)
                if k % 2 == 1 { f = 1 - f }
                let p = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
                let fade = min(f, 1 - f) * 6   // fade in/out at the ends
                ctx.fill(Circle().path(in: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                         with: .color(s.color.opacity(0.18 * min(fade, 1))))
                ctx.fill(Circle().path(in: CGRect(x: p.x - 1.8, y: p.y - 1.8, width: 3.6, height: 3.6)),
                         with: .color(s.color.opacity(min(fade, 1))))
            }
        }
        if !s.label.isEmpty {
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let label = ctx.resolve(Text(s.label).font(.mono(8)).foregroundStyle(s.color.opacity(hot ? 1 : 0.6)))
            let sz = label.measure(in: CGSize(width: 200, height: 20))
            ctx.fill(Path(roundedRect: CGRect(x: mid.x - sz.width / 2 - 5, y: mid.y - sz.height / 2 - 2,
                                              width: sz.width + 10, height: sz.height + 4), cornerRadius: 3),
                     with: .color(.bg))
            ctx.draw(label, at: mid)
        }
    }

    // MARK: Groups — a soft band behind each top-level folder's run of machines

    func drawGroups(_ ctx: inout GraphicsContext, _ ns: [Node], _ size: CGSize) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = radii(size)
        let step = 2 * Double.pi / Double(max(ns.count, 1))
        let pad = min(step * 0.42, 0.34)
        func pt(_ a: Double, _ grow: CGFloat = 0) -> CGPoint {
            CGPoint(x: c.x + (r.width + grow) * cos(a), y: c.y + (r.height + grow) * sin(a))
        }
        var i = 0
        while i < ns.count {
            let g = ns[i].group
            var j = i
            while j + 1 < ns.count, ns[j + 1].group?.id == g?.id { j += 1 }
            defer { i = j + 1 }
            guard let g else { continue }
            let a0 = angle(i, of: ns.count) - pad, a1 = angle(j, of: ns.count) + pad
            var band = Path(), edge = Path()
            for a in stride(from: a0, through: a1, by: 0.01) {
                if a == a0 { band.move(to: pt(a)); edge.move(to: pt(a, 38)) } else { band.addLine(to: pt(a)); edge.addLine(to: pt(a, 38)) }
            }
            let col = g.tint
            ctx.stroke(band, with: .color(col.opacity(0.08)), style: StrokeStyle(lineWidth: 76, lineCap: .round))
            ctx.stroke(edge, with: .color(col.opacity(0.35)), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 4]))
            let label = ctx.resolve(Text("\(g.name.uppercased()) · \(j - i + 1)").font(.mono(9)).tracking(1.5).foregroundStyle(col))
            let mid = (a0 + a1) / 2
            let at = pt(mid, sin(mid) < -0.5 ? 58 : -66)   // top of ring: above the band; elsewhere: inside, clear of node labels
            let sz = label.measure(in: CGSize(width: 300, height: 20))
            ctx.fill(Path(roundedRect: CGRect(x: at.x - sz.width / 2 - 6, y: at.y - sz.height / 2 - 3,
                                              width: sz.width + 12, height: sz.height + 6), cornerRadius: 4),
                     with: .color(Color.bg.opacity(0.9)))
            ctx.draw(label, at: at)
        }
    }

    // MARK: Uploads — curved links from a machine to the cloud, packets flowing out

    func drawUpload(_ ctx: inout GraphicsContext, _ n: Node, to cp: CGPoint, t: Double) {
        let p0 = n.point
        let ctrl = CGPoint(x: (p0.x + cp.x) / 2, y: min(p0.y, cp.y) - 70)
        let col = toolColor(n.uploads.first?.parsed.tool ?? "")
        var path = Path()
        path.move(to: p0)
        path.addQuadCurve(to: cp, control: ctrl)
        ctx.stroke(path, with: .color(col.opacity(0.55)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [5, 5], dashPhase: -t * 18))
        for k in 0..<3 {
            let f = (t * 0.35 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
            let u = 1 - f
            let x = u * u * p0.x + 2 * u * f * ctrl.x + f * f * cp.x
            let y = u * u * p0.y + 2 * u * f * ctrl.y + f * f * cp.y
            ctx.fill(Circle().path(in: CGRect(x: x - 5, y: y - 5, width: 10, height: 10)), with: .color(col.opacity(0.2)))
            ctx.fill(Circle().path(in: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)), with: .color(col))
        }
    }

    // MARK: Chrome

    var readout: some View {
        let online = store.machines.filter { store.online($0) == true }.count
        let open = terms.sessions.count
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            readoutRow("TAILNET", store.tailnetName.isEmpty ? "—" : store.tailnetName)
            readoutRow("STATE", store.backendState.isEmpty ? "—" : store.backendState.uppercased(),
                       store.backendState == "Running" ? .ok : .accent)
            readoutRow("EXIT", store.exitNode.map { e in
                e.location.map { "\(flag($0.CountryCode)) \($0.City ?? e.hostName)" } ?? e.hostName
            } ?? "DIRECT", store.exitNode == nil ? .primary : .ok)
            readoutRow("NODES", "\(online) / \(store.machines.count) ONLINE")
            readoutRow("SESSIONS", open == 0 ? "NONE OPEN" : "\(open) LIVE", open == 0 ? .primary : .accent)
            readoutRow("UPLOADS", cloud.active.isEmpty ? "NONE" : "\(cloud.active.count) ACTIVE", cloud.active.isEmpty ? .primary : .gcloud)
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) { Rectangle().fill(Color.accent).frame(width: 2) }
    }

    func readoutRow(_ k: String, _ v: String, _ color: Color = .primary) -> some View {
        GridRow {
            Text(k).font(.mono(9)).foregroundStyle(.dim).tracking(2)
            Text(v).font(.mono(11)).foregroundStyle(color)
        }
    }

    var legend: some View {
        HStack(spacing: 16) {
            legendItem("DIRECT", .ok, [])
            legendItem("RELAYED", .ok, [4, 3])
            legendItem("OFFLINE", .ledOff, [2, 3])
            HStack(spacing: 6) {
                Circle().fill(Color.ok).frame(width: 4, height: 4).shadow(color: .ok, radius: 3)
                Text("TRAFFIC").font(.mono(8)).foregroundStyle(.dim).tracking(1.5)
            }
        }
    }

    func legendItem(_ t: String, _ c: Color, _ dash: [CGFloat]) -> some View {
        HStack(spacing: 6) {
            Path { p in p.move(to: .init(x: 0, y: 1)); p.addLine(to: .init(x: 18, y: 1)) }
                .stroke(c.opacity(0.8), style: StrokeStyle(lineWidth: 1.2, dash: dash))
                .frame(width: 18, height: 2)
            Text(t).font(.mono(8)).foregroundStyle(.dim).tracking(1.5)
        }
    }
}

// MARK: - Pieces

func osIcon(_ os: String) -> String {
    switch os.lowercased() {
    case let o where o.contains("win"): return "pc"
    case let o where o.contains("linux"): return "server.rack"
    case let o where o.contains("mac"), let o where o.contains("ios"): return "laptopcomputer"
    default: return "cpu"
    }
}

private struct DotGrid: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 22
            for x in stride(from: step / 2, to: size.width, by: step) {
                for y in stride(from: step / 2, to: size.height, by: step) {
                    ctx.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(Color.ink.opacity(0.07)))
                }
            }
        }
        .overlay(RadialGradient(colors: [Color.accent.opacity(0.07), .clear], center: .center, startRadius: 0, endRadius: 420))
    }
}

/// The tailnet itself — Tailscale's nine-dot mark inside a slowly turning ring.
private struct Hub: View {
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color.accent.opacity(0.22), .clear], center: .center,
                                         startRadius: 0, endRadius: 90))
                .frame(width: 180, height: 180)
            TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
                let deg = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 72) * 5
                ZStack {
                    Circle().strokeBorder(Color.accent.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 7]))
                        .frame(width: 118, height: 118).rotationEffect(.degrees(deg))
                    Circle().strokeBorder(Color.ink.opacity(0.06), style: StrokeStyle(lineWidth: 1, dash: [14, 10]))
                        .frame(width: 140, height: 140).rotationEffect(.degrees(-deg * 0.6))
                }
            }
            Circle().fill(Color.panelDeep).frame(width: OverviewView.hubR * 2, height: OverviewView.hubR * 2)
                .overlay(Circle().strokeBorder(Color.accent.opacity(0.7), lineWidth: 1.2))
                .shadow(color: Color.accent.opacity(0.35), radius: 14)
            VStack(spacing: 7) {
                Grid(horizontalSpacing: 5, verticalSpacing: 5) {
                    ForEach(0..<3) { r in
                        GridRow {
                            ForEach(0..<3) { col in
                                Circle().fill(Color.ink.opacity(r == 1 || (r == 2 && col == 1) ? 0.95 : 0.22))
                                    .frame(width: 6, height: 6)
                            }
                        }
                    }
                }
                Text("TAILSCALE").font(.mono(7)).tracking(1.5).foregroundStyle(.dim)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct CloudNode: View {
    let transfers: [Transfer]
    var speed: Double { transfers.compactMap(\.speed).reduce(0, +) }

    var body: some View {
        Image(systemName: "icloud.and.arrow.up")
            .font(.system(size: 18, weight: .medium))
            .frame(width: 56, height: 56)
            .background(Circle().fill(Color.panelDeep))
            .overlay(Circle().strokeBorder(Color.gcloud.opacity(0.9), lineWidth: 1.2))
            .shadow(color: Color.gcloud.opacity(0.45), radius: 12)
            .overlay(alignment: .top) {
                VStack(spacing: 2) {
                    Text("CLOUD").font(.mono(10).weight(.semibold)).tracking(1.5).foregroundStyle(Color.gcloud)
                    Text("\(transfers.count) upload\(transfers.count == 1 ? "" : "s")" + (speed > 0 ? " · \(bytes(Int64(speed)))/s" : ""))
                        .font(.mono(9)).foregroundStyle(.dim)
                }
                .fixedSize().offset(y: 64)
            }
            .contentShape(Circle())
            .help("Open Cloud transfers")
    }
}

private struct NodeView: View {
    let n: OverviewView.Node
    let hovered: Bool

    var ring: Color { n.isSelf ? .accent : n.reach.color }

    var body: some View {
        Image(systemName: osIcon(n.os))
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(n.online == false ? Color.dim : Color.ink)
            .frame(width: OverviewView.nodeR * 2, height: OverviewView.nodeR * 2)
            .background(Circle().fill(Color.panelDeep))
            .overlay(Circle().strokeBorder(ring.opacity(n.online == false ? 0.5 : 0.9), lineWidth: hovered ? 2 : 1.2))
            .shadow(color: ring.opacity(n.online == true ? (hovered ? 0.7 : 0.35) : 0), radius: hovered ? 16 : 9)
            .overlay(alignment: .topTrailing) {
                if n.tabs > 0 {
                    Text("\(n.tabs)").font(.mono(9).weight(.bold)).foregroundStyle(Color.bg)
                        .frame(minWidth: 16, minHeight: 16).background(Color.accent, in: Circle())
                        .offset(x: 4, y: -4)
                        .help("\(n.tabs) open terminal session\(n.tabs == 1 ? "" : "s")")
                }
            }
            .overlay(alignment: .top) {
                VStack(spacing: 2) {
                    Text(n.isSelf ? "THIS MAC" : n.name)
                        .font(n.isSelf ? .mono(10).weight(.semibold) : .system(size: 12, weight: .semibold))
                        .tracking(n.isSelf ? 1.5 : 0)
                        .foregroundStyle(n.isSelf ? Color.accent : n.online == false ? Color.dim : .primary)
                    Text(n.host).font(.mono(9)).foregroundStyle(.dim)
                    if hovered, !n.isSelf { card.padding(.top, 6) }
                }
                .lineLimit(1).fixedSize()
                .offset(y: OverviewView.nodeR * 2 + 8)
            }
            .scaleEffect(hovered ? 1.08 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovered)
            .contentShape(Circle())
            .help(n.isSelf ? "This Mac" : "Open \(n.name)")
    }

    var card: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("PATH", n.peer.map { p in
                !p.online ? "offline" : p.curAddr.isEmpty ? "relay · DERP \(p.relay.uppercased())" : "direct · \(p.curAddr)"
            } ?? "external — not on your tailnet")
            if let p = n.peer, p.rx + p.tx > 0 {
                row("RX / TX", "\(bytes(p.rx)) / \(bytes(p.tx))")
            }
            if !n.os.isEmpty { row("OS", n.os.lowercased()) }
            row("SESSIONS", n.tabs == 0 ? "none" : "\(n.tabs) live")
            if !n.uploads.isEmpty { row("UPLOADS", n.uploads.map { "\($0.parsed.tool) \($0.parsed.op)" }.joined(separator: ", ")) }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.ink.opacity(0.08)))
    }

    func row(_ k: String, _ v: String) -> some View {
        HStack(spacing: 10) {
            Text(k).font(.mono(8)).foregroundStyle(.dim).tracking(1.5).frame(width: 58, alignment: .leading)
            Text(v).font(.mono(10))
        }
    }

    func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .binary) }
}
