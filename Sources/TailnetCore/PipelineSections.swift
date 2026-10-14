import SwiftUI

// MARK: - Sections: one per service (or, for events that name none, per sender), sub-sections by resource type

/// Your name for a section. Vaults from older builds also stored an `apiBase` here — ignored when decoded.
struct ServiceSettings: Codable, Hashable {
    var label = ""
}

struct PipelineSection: Identifiable {
    let id: String               // service id; the sender's name for events without one; "" = pipelines with no runs
    var isService = false
    var source = ""              // the machine it comes from
    var lanes: [PipelineLane] = []
    var loose: [PipelineJob] = []

    var current: [PipelineJob] { lanes.compactMap(\.runs.first) + loose }
    var lastEvent: Date? { (lanes.flatMap(\.runs) + loose).map(\.latest.receivedAt).max() }
    func attention(_ now: Date) -> Bool { lanes.contains { $0.attention(now) } || loose.contains { $0.attention(now) } }

    /// Loose runs by what they are (resource.type) — A–Z so sub-sections don't shuffle as events arrive; untyped last.
    var kinds: [(name: String, runs: [PipelineJob])] {
        Dictionary(grouping: loose) { $0.kind ?? "" }
            .sorted { ($0.key.isEmpty ? 1 : 0, $0.key) < ($1.key.isEmpty ? 1 : 0, $1.key) }
            .map { ($0.key, $0.value) }
    }

    /// "deploy_job" → "DEPLOY JOBS"; nothing → "RUNS".
    static func title(_ kind: String) -> String {
        kind.isEmpty ? "RUNS" : kind.replacingOccurrences(of: "_", with: " ").uppercased() + (kind.hasSuffix("s") ? "" : "S")
    }

    /// Attention first, then services, then name.
    static func build(_ lanes: [PipelineLane], _ loose: [PipelineJob], now: Date) -> [PipelineSection] {
        var by: [String: PipelineSection] = [:]
        func key(_ j: PipelineJob) -> String { j.service ?? j.latest.source }
        for l in lanes { let k = l.runs.first.map(key) ?? ""; by[k, default: PipelineSection(id: k)].lanes.append(l) }
        for j in loose { by[key(j), default: PipelineSection(id: key(j))].loose.append(j) }
        let all = by.values.map { s -> PipelineSection in
            var s = s
            let runs = s.lanes.flatMap(\.runs) + s.loose
            s.isService = runs.contains { $0.service != nil }
            s.source = runs.max { $0.latest.receivedAt < $1.latest.receivedAt }?.latest.source ?? ""
            return s
        }
        .sorted { ($0.id.isEmpty ? 1 : 0, $0.isService ? 0 : 1, $0.id.lowercased()) < ($1.id.isEmpty ? 1 : 0, $1.isService ? 0 : 1, $1.id.lowercased()) }
        return all.filter { $0.attention(now) } + all.filter { !$0.attention(now) }
    }
}

struct ServiceSection: View {
    @EnvironmentObject private var store: Store
    @AppStorage("collapsedSections") private var collapsedRaw = ""
    let section: PipelineSection
    let now: Date
    let editPipeline: (PipelineGroup) -> Void
    let rename: () -> Void

    @State private var expanded: Set<String> = []   // sub-sections showing every run
    static let cap = 8                                // runs drawn per sub-section until you ask for all

    var body: some View {
        let s = section, open = !collapsedRaw.split(separator: " ").contains(Substring(s.id.isEmpty ? "-" : s.id))
        VStack(alignment: .leading, spacing: 16) {
            header(open)
            if open {
                if !s.lanes.isEmpty {
                    sub("PIPELINES", s.lanes.count) {
                        ForEach(s.lanes) { l in PipelineCard(lane: l, now: now) { editPipeline(l.group) } }
                    }
                }
                ForEach(s.kinds, id: \.name) { k in
                    sub(PipelineSection.title(k.name), k.runs.count) {
                        let all = expanded.contains(k.name)
                        ForEach(all ? k.runs : Array(k.runs.prefix(Self.cap))) {
                            JobCard(job: $0, now: now, group: { editPipeline(PipelineGroup(like: $0)) })
                        }
                        if k.runs.count > Self.cap {
                            Button(all ? "show the latest \(Self.cap)" : "show all \(k.runs.count)") {
                                if all { expanded.remove(k.name) } else { expanded.insert(k.name) }
                            }
                            .buttonStyle(.borderless).font(.mono(10))
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color.ink.opacity(0.02), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(s.attention(now) ? Color.accent.opacity(0.35) : Color.ink.opacity(0.06)))
    }

    func header(_ open: Bool) -> some View {
        let s = section, current = s.current, custom = store.services[s.id]?.label ?? ""
        let failed = current.filter(\.latest.failed).count, stale = current.filter { $0.stale(now) }.count
        let running = current.filter { $0.latest.running && !$0.stale(now) }.count
        let label = !custom.isEmpty ? custom : s.id.isEmpty ? "Pipelines waiting for a first run" : s.id
        return HStack(spacing: 10) {
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.dim)
                .rotationEffect(.degrees(open ? 90 : 0))
            Image(systemName: s.isService ? "shippingbox.fill" : "desktopcomputer").foregroundStyle(tagColor(s.id))
            Text(label).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            if label != s.id && !s.id.isEmpty { Text(s.id).font(.mono(10)).foregroundStyle(.dim) }
            if s.isService && !s.source.isEmpty { Text("· from \(s.source)").font(.mono(10)).foregroundStyle(.dim).lineLimit(1) }
            Spacer()
            if running > 0 { chip("\(running) running", .accent) }
            if stale > 0 { chip("\(stale) stale", .accent) }
            if failed > 0 { chip("\(failed) failed", .bad) }
            if let t = s.lastEvent { Text(t.formatted(.relative(presentation: .named))).font(.mono(9)).foregroundStyle(.tertiary) }
            if !s.id.isEmpty {
                Menu { Button("Rename…", action: rename) } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(s.id.isEmpty ? "-" : s.id, open) }
    }

    func chip(_ t: LocalizedStringKey, _ c: Color) -> some View {
        Text(t).font(.mono(9).weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 3)
            .background(c.opacity(0.14), in: Capsule()).foregroundStyle(c)
    }

    func sub<C: View>(_ title: String, _ n: Int, @ViewBuilder _ c: () -> C) -> some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            SectionLabel(t: "\(title) · \(n)")
            c()
        }
        .padding(.leading, 20)
    }

    func toggle(_ id: String, _ open: Bool) {
        var c = Set(collapsedRaw.split(separator: " ").map(String.init))
        if open { c.insert(id) } else { c.remove(id) }
        collapsedRaw = c.sorted().joined(separator: " ")
    }
}

/// Your own label for a section — the sender's service id (or machine name) stays underneath it.
struct SectionNameSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var label = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SECTION · \(id)").font(.mono(11)).foregroundStyle(.dim).tracking(2)
            TextField(id, text: $label).textFieldStyle(.roundedBorder).font(.mono(11))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    store.services[id] = ServiceSettings(label: label.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 420)
        .preferredColorScheme(Theme.current.scheme)
        .onAppear { label = store.services[id]?.label ?? "" }
    }
}

/// Which section's name sheet is open (`.sheet(item:)` wants something Identifiable).
struct SectionRef: Identifiable { let id: String }
