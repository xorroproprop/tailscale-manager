import SwiftUI
import AppKit

// MARK: - Snippets: code you reuse, named like files, highlighted, searchable — kept in the encrypted vault

struct Snippet: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name = "untitled.sh"
    var language = ""          // Syntax.Lang id; "" = from the name's extension (or a #! line)
    var code = ""
    var updatedAt = Date()

    static let maxBytes = 256 * 1024   // dropped files bigger than this aren't snippets

    var lang: Syntax.Lang { Syntax.lang(language) ?? Syntax.detect(name, code) }
    var lines: Int { code.isEmpty ? 0 : code.split(separator: "\n", omittingEmptySubsequences: false).count }

    /// Name hits first — the text in order, then its letters in order like ⌘P ("dcy" → docker-compose.yml) — then
    /// snippets whose code contains it. A–Z within each.
    static func search(_ all: [Snippet], _ query: String) -> [Snippet] {
        let sorted = all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return sorted }
        let letters = q.filter { $0 != " " }
        func rank(_ s: Snippet) -> Int? {
            let n = s.name.lowercased()
            if n.contains(q) { return 0 }
            var it = n.makeIterator()
            if letters.allSatisfy({ c in while let x = it.next() { if x == c { return true } }; return false }) { return 1 }
            return s.code.localizedCaseInsensitiveContains(q) ? 2 : nil
        }
        let ranked = sorted.compactMap { s in rank(s).map { (s, $0) } }
        return (0...2).flatMap { r in ranked.filter { $0.1 == r }.map(\.0) }
    }
}

extension Store {
    @discardableResult
    func addSnippet(_ s: Snippet = Snippet()) -> Snippet { snippets.append(s); return s }

    /// Writes only real changes (and stamps them) — the editor calls this on every pause in typing.
    func saveSnippet(_ s: Snippet) {
        guard let i = snippets.firstIndex(where: { $0.id == s.id }) else { return }   // deleted meanwhile: don't resurrect
        var s = s
        s.updatedAt = snippets[i].updatedAt
        guard s != snippets[i] else { return }
        s.updatedAt = Date()
        snippets[i] = s
    }

    func deleteSnippet(_ id: String) { snippets.removeAll { $0.id == id } }

    /// A dropped file becomes a snippet named after it. UTF-8 text only, ≤ 256 KB.
    func importSnippet(_ url: URL) -> Snippet? {
        guard url.isFileURL, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap({ $0 }).map({ $0 <= Snippet.maxBytes }) == true,
              let data = try? Data(contentsOf: url), let code = String(data: data, encoding: .utf8), !code.contains("\0") else { return nil }
        return addSnippet(Snippet(name: url.lastPathComponent, code: code))
    }
}

// MARK: - Page: library on the left (search + list), editor on the right

struct SnippetsView: View {
    @EnvironmentObject private var store: Store
    @AppStorage("selectedSnippet") private var selected = ""
    @State private var query = ""
    @State private var deleting: Snippet?
    @State private var dropNote: String?
    @State private var dropTargeted = false
    @FocusState private var searchFocused: Bool

    var results: [Snippet] { Snippet.search(store.snippets, query) }

    var body: some View {
        HSplitView {
            library.frame(minWidth: 230, idealWidth: 280, maxWidth: 420)
            Group {
                if let s = store.snippets.first(where: { $0.id == selected }) {
                    SnippetEditor(draft: s) { deleting = s }.id(s.id)
                } else {
                    empty
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.bg)
        .navigationTitle("Snippets")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { new() } label: { Label("New snippet", systemImage: "plus") }.help("New snippet")
            }
        }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let d = deleting {
                    store.deleteSnippet(d.id)
                    if selected == d.id { selected = results.first?.id ?? "" }
                }
                deleting = nil
            }
        } message: { Text("This can't be undone.") }
        .onAppear { if store.snippets.first(where: { $0.id == selected }) == nil { selected = results.first?.id ?? "" } }
        .onChange(of: query) { if !results.contains(where: { $0.id == selected }) { selected = results.first?.id ?? "" } }
        .background { Button("") { searchFocused = true }.keyboardShortcut("k").hidden() }   // ⌘K: jump to search
    }

    var library: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.dim)
                TextField("Search names and code  ⌘K", text: $query).textFieldStyle(.plain).font(.mono(11))
                    .focused($searchFocused)
                    .onSubmit { selected = results.first?.id ?? selected }
                    .onExitCommand { query = "" }
                if !query.isEmpty {
                    Text("\(results.count)/\(store.snippets.count)").font(.mono(9)).foregroundStyle(.tertiary)
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.dim)
                }
            }
            .padding(8)
            .background(Color.panelDeep, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(searchFocused ? Color.accent.opacity(0.6) : Color.ink.opacity(0.08)))
            .padding(10)
            List(results, selection: Binding(get: { selected.isEmpty ? nil : selected }, set: { selected = $0 ?? "" })) { s in
                SnippetRow(s: s).tag(s.id)
                    .contextMenu {
                        Button("Copy code") { copyString(s.code) }
                        Divider()
                        Button("Delete…", role: .destructive) { deleting = s }
                    }
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if results.isEmpty && !store.snippets.isEmpty {
                    Text("no snippet matches “\(query)”").font(.mono(10)).foregroundStyle(.tertiary)
                }
            }
            if let dropNote {
                Text(dropNote).font(.mono(9)).foregroundStyle(Color.accent).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(dropTargeted ? Color.accent.opacity(0.08) : Color.panelDeep.opacity(0.5))
        .dropDestination(for: URL.self) { urls, _ in
            let added = urls.compactMap { store.importSnippet($0) }
            dropNote = added.count < urls.count ? "skipped \(urls.count - added.count) — text files up to 256 KB only" : nil
            if let last = added.last { query = ""; selected = last.id }
            return !added.isEmpty
        } isTargeted: { dropTargeted = $0 }
    }

    var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "curlybraces").font(.system(size: 38, weight: .light)).foregroundStyle(.dim)
            Text(store.snippets.isEmpty ? "No snippets yet" : "Pick a snippet").font(.system(size: 15, weight: .semibold))
            Text("+ in the toolbar, or drop files on the list — the file name becomes the snippet's name and picks its language")
                .font(.mono(10)).foregroundStyle(.dim).multilineTextAlignment(.center).frame(maxWidth: 360)
            Button { new() } label: { Label("New snippet", systemImage: "plus") }.controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func new() {
        query = ""
        selected = store.addSnippet().id
    }
}

struct SnippetRow: View {
    let s: Snippet

    var body: some View {
        let lang = s.lang
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2).fill(tagColor(lang.name)).frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(s.name).font(.mono(12).weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text("\(lang.name) · \(s.lines) line\(s.lines == 1 ? "" : "s")").font(.mono(9)).foregroundStyle(.dim).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

struct SnippetEditor: View {
    @EnvironmentObject private var store: Store
    @State var draft: Snippet
    let delete: () -> Void
    @State private var copied = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let lang = draft.lang
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(tagColor(lang.name)).frame(width: 4, height: 22)
                TextField("name.ext — the extension picks the language", text: $draft.name)
                    .textFieldStyle(.plain).font(.mono(15).weight(.semibold)).focused($nameFocused)
                Picker("", selection: $draft.language) {
                    Text("Auto · \(Syntax.detect(draft.name, draft.code).name)").tag("")
                    Divider()
                    ForEach(Syntax.langs) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().fixedSize().help("Language — Auto reads the file extension or a #! line")
                Button { copy() } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.borderedProminent).tint(Color.accent)
                    .keyboardShortcut("c", modifiers: [.command, .shift]).help("Copy the whole snippet (⇧⌘C)")
                Menu {
                    Button("Delete snippet…", role: .destructive, action: delete)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            Divider()
            CodeEditor(text: $draft.code, lang: lang)
            Divider()
            HStack(spacing: 14) {
                Text("\(draft.lines) lines · \(draft.code.count) chars · \(lang.name)")
                Spacer()
                Text("⌘F find · ⇧⌘C copy")
                Text("encrypted vault · edited \(draft.updatedAt.formatted(.relative(presentation: .named)))")
            }
            .font(.mono(9)).foregroundStyle(.tertiary)
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
        .onAppear { if draft.code.isEmpty { nameFocused = true } }
        .task(id: draft) {   // save after a pause in typing — each save reseals the vault
            do { try await Task.sleep(for: .milliseconds(600)); store.saveSnippet(draft) } catch {}
        }
        .onDisappear { store.saveSnippet(draft) }   // switching snippets or tabs mid-pause
    }

    func copy() {
        copyString(draft.code)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }
}
