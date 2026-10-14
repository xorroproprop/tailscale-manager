import AppKit
import SwiftUI
import SwiftTerm

// MARK: - Ghostty look (theme, font, padding, wallpaper read from the user's Ghostty config)
// ponytail: libghostty has no embeddable macOS API yet — SwiftTerm renders, Ghostty's config styles it.

struct GhosttyLook {
    var background = NSColor(hex: "#282c34")!   // Ghostty defaults
    var foreground = NSColor.white
    var palette: [NSColor?] = Array(repeating: nil, count: 16)
    var cursor: NSColor?
    var selection: NSColor?
    var fontFamily: String?
    var fontSize: CGFloat = 13
    var padding = NSSize(width: 2, height: 2)
    var backgroundImage: String?
    var backgroundImageOpacity: CGFloat = 1
    var optionAsAlt = false
    var copyOnSelect = false   // Ghostty's `copy-on-select = clipboard`

    static let user: GhosttyLook = {
        let home = NSHomeDirectory()
        let config = ["/.config/ghostty/config", "/.config/ghostty/config.ghostty",
                      "/Library/Application Support/com.mitchellh.ghostty/config",
                      "/Library/Application Support/com.mitchellh.ghostty/config.ghostty"]
            .compactMap { try? String(contentsOfFile: home + $0, encoding: .utf8) }
            .joined(separator: "\n")
        return resolve(config: config) { name in
            [home + "/.config/ghostty/themes/" + name,
             "/Applications/Ghostty.app/Contents/Resources/ghostty/themes/" + name]
                .lazy.compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }.first
        }
    }()
    static let wallpaper: NSImage? = user.backgroundImage.flatMap(NSImage.init(contentsOfFile:))

    /// Theme first, then the config on top — same precedence as Ghostty.
    static func resolve(config: String, theme: (String) -> String?) -> GhosttyLook {
        let pairs = parse(config)
        var look = GhosttyLook()
        if let t = pairs.last(where: { $0.0 == "theme" })?.1, let text = theme(darkVariant(t)) {
            look.apply(parse(text))
        }
        look.apply(pairs)
        return look
    }

    /// The app is dark-only: "light:A,dark:B" → "B", plain "A" → "A".
    static func darkVariant(_ v: String) -> String {
        let parts = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if let d = parts.first(where: { $0.hasPrefix("dark:") }) { return String(d.dropFirst(5)) }
        return parts.first.map { $0.hasPrefix("light:") ? String($0.dropFirst(6)) : $0 } ?? v
    }

    static func parse(_ text: String) -> [(String, String)] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
            var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
            return (line[..<eq].trimmingCharacters(in: .whitespaces), v)
        }
    }

    mutating func apply(_ pairs: [(String, String)]) {
        /// nan / inf / 1e999 / a negative padding would give SwiftTerm a NaN frame, which traps — clamp to sane values.
        func num(_ v: String, _ r: ClosedRange<CGFloat>) -> CGFloat? {
            Double(v.split(separator: ",").first?.trimmingCharacters(in: .whitespaces) ?? "")
                .flatMap { $0.isFinite ? min(max(CGFloat($0), r.lowerBound), r.upperBound) : nil }
        }
        for (k, v) in pairs {
            switch k {
            case "background": background = NSColor(hex: v) ?? background
            case "foreground": foreground = NSColor(hex: v) ?? foreground
            case "cursor-color": cursor = NSColor(hex: v) ?? cursor
            case "selection-background": selection = NSColor(hex: v) ?? selection
            case "palette":
                let kv = v.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2, let i = Int(kv[0]), palette.indices.contains(i) { palette[i] = NSColor(hex: kv[1]) }
            case "font-family": if fontFamily == nil, !v.isEmpty { fontFamily = v }
            case "font-size": fontSize = num(v, 4...96) ?? fontSize
            case "window-padding-x": padding.width = num(v, 0...200) ?? padding.width
            case "window-padding-y": padding.height = num(v, 0...200) ?? padding.height
            case "background-image": backgroundImage = v.isEmpty ? nil : (v as NSString).expandingTildeInPath
            case "background-image-opacity": backgroundImageOpacity = num(v, 0...1) ?? backgroundImageOpacity
            case "macos-option-as-alt": optionAsAlt = v != "false"
            // ponytail: `true` means Ghostty's private selection pasteboard on macOS — only `clipboard` maps here
            case "copy-on-select": copyOnSelect = v == "clipboard"
            default: break
            }
        }
    }

    var font: NSFont {
        fontFamily.flatMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: fontSize) }
            ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    func style(_ t: TerminalView) {
        t.font = font
        t.nativeForegroundColor = foreground
        t.nativeBackgroundColor = background
        if let cursor { t.caretColor = cursor }
        if let selection { t.selectedTextBackgroundColor = selection }
        // ponytail: partial palettes keep SwiftTerm's defaults — every Ghostty theme ships all 16
        let p = palette.compactMap { $0?.usingColorSpace(.sRGB) }
        if p.count == 16 {
            t.installColors(p.map {
                SwiftTerm.Color(red: UInt16($0.redComponent * 65535), green: UInt16($0.greenComponent * 65535),
                                blue: UInt16($0.blueComponent * 65535))
            })
        }
        t.optionAsMetaKey = optionAsAlt
        if Self.wallpaper != nil { t.backgroundOpacity = 0 }   // let the wallpaper through, like Ghostty
    }
}

extension NSColor {
    convenience init?(hex s: String) {
        let h = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// SwiftTerm with Mac-style copying. A drag always selects, even when the remote app has grabbed the mouse
/// (tmux, htop, vim, Windows' ConPTY): ⌥-click/drag hands the mouse to the app, and the wheel still goes to it.
/// Output no longer wipes a selection, right-click has Copy/Paste, and copy-on-select follows your Ghostty config.
final class SSHTerminalView: LocalProcessTerminalView {
    var copyOnSelect = GhosttyLook.user.copyOnSelect
    var onCopy: ((String) -> Void)?

    /// OSC 52 off: SwiftTerm would answer a remote `ESC]52;c;?` with this Mac's clipboard (a password copied for another
    /// machine included) and let any host overwrite it. The parser is built once, so this survives terminal resets.
    override init(frame: CGRect) {
        super.init(frame: frame)
        getTerminal().registerOscHandler(code: 52) { _ in }
    }
    required init?(coder: NSCoder) { nil }

    /// ⌘-click on a link the remote printed: web links only — never file://, ssh:// or another app's URL scheme.
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let u = URL(string: link), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(u)
    }

    /// ⌥ held = this click is for the remote app; otherwise it's ours to select with.
    private func mouse(_ e: NSEvent, _ handle: () -> Void) {
        allowMouseReporting = e.modifierFlags.contains(.option)
        handle()
        allowMouseReporting = true   // the wheel keeps scrolling tmux / less / htop
    }
    override func mouseDown(with e: NSEvent) { mouse(e) { super.mouseDown(with: e) } }
    override func mouseDragged(with e: NSEvent) { mouse(e) { super.mouseDragged(with: e) } }
    override func mouseUp(with e: NSEvent) {
        mouse(e) { super.mouseUp(with: e) }
        if copyOnSelect && !e.modifierFlags.contains(.option) && getSelection()?.isEmpty == false { copy(self) }
    }

    /// SwiftTerm drops the selection on every chunk of output while mouse reporting is on — feed with it off.
    // ponytail: keeps the selection while output streams; once 10k lines of scrollback roll over it can drift
    override func dataReceived(slice: ArraySlice<UInt8>) {
        allowMouseReporting = false
        super.dataReceived(slice: slice)
        allowMouseReporting = true
    }

    override func copy(_ sender: Any) {
        guard let s = getSelection(), !s.isEmpty else { return }
        super.copy(sender)
        onCopy?(s)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        for (title, action, key) in [("Copy", #selector(copy(_:)), "c"), ("Paste", #selector(paste(_:)), "v"),
                                     ("Select All", #selector(selectAll(_:)), "a")] {
            if title == "Select All" { m.addItem(.separator()) }
            m.addItem(withTitle: title, action: action, keyEquivalent: key).target = self
        }
        return m
    }
}

/// Ghostty-style surface: background colour → wallpaper → padded terminal.
final class TermContainer: NSView {
    let term: LocalProcessTerminalView
    weak var slot: TermSlot?   // the newest page showing this session — the only one allowed to hold it
    private let art = NSView()

    init(term: LocalProcessTerminalView) {
        self.term = term
        super.init(frame: .zero)
        let look = GhosttyLook.user
        wantsLayer = true
        layer?.backgroundColor = look.background.cgColor
        if let img = GhosttyLook.wallpaper {
            art.wantsLayer = true
            art.layer?.contents = img
            art.layer?.contentsGravity = .resizeAspectFill
            art.layer?.masksToBounds = true
            art.alphaValue = look.backgroundImageOpacity
            addSubview(art)
        }
        addSubview(term)
    }
    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        art.frame = bounds
        let p = GhosttyLook.user.padding
        term.frame = bounds.insetBy(dx: p.width, dy: p.height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(term)   // switching tabs lands the cursor in the terminal
    }
}

// MARK: - One SSH session = one tab

@MainActor
final class TermSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let started = Date()
    let machine: Machine
    let preset: SshTab?
    let user: String
    let args: [String]
    @Published var title: String
    @Published var notice: String?
    @Published var ended = false
    @Published var exitCode: Int32?
    let term: SSHTerminalView
    let container: TermContainer
    var onExit: ((TermSession) -> Void)?

    var machineId: String { machine.id }
    var name: String { preset?.name ?? "shell" }
    /// Same session as a shell command — for "pop out to Ghostty".
    var command: String { (["ssh"] + args).map(Remote.q).joined(separator: " ") }

    static let env: [String] = {
        var e = ProcessInfo.processInfo.environment   // keeps SSH_AUTH_SOCK → agent / Keychain keys work
        e["TERM"] = "xterm-256color"
        e["COLORTERM"] = "truecolor"
        if e["LANG"] == nil { e["LANG"] = "en_US.UTF-8" }
        return e.map { "\($0.key)=\($0.value)" }
    }()

    /// Exactly what a tab dials.
    static func args(_ m: Machine, preset: SshTab? = nil) -> [String] {
        let cmd = preset?.command.trimmingCharacters(in: .whitespaces) ?? ""
        return ["-t", "-o", "ConnectTimeout=10"] + m.sshArgs + (cmd.isEmpty ? [] : [cmd])
    }

    init(machine m: Machine, preset: SshTab?) {
        machine = m
        self.preset = preset
        user = m.sshLogin
        args = Self.args(m, preset: preset)
        title = preset?.name ?? "shell"
        term = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        container = TermContainer(term: term)
        super.init()
        GhosttyLook.user.style(term)
        term.getTerminal().changeScrollback(10_000)
        term.processDelegate = self
        term.onCopy = { [weak self] s in self?.flash("copied · \(s.count) characters") }
        SSHKeys.prepare()
        term.startProcess(executable: "/usr/bin/ssh", args: args, environment: Self.env)
    }

    /// What's on the cursor's line, left of the cursor — i.e. the prompt currently waiting for input.
    // ponytail: reads the visible screen; scrolled back it misreads, and the fill then refuses (fails safe)
    var promptLine: String {
        let t = term.getTerminal()
        let c = t.getCursorLocation()
        return t.getLine(row: c.y)?.translateToString(trimRight: false, startCol: 0, endCol: c.x) ?? ""
    }

    /// Bytes straight into the pty — never via the clipboard, never echoed by a password prompt.
    func type(_ bytes: [UInt8]) { term.send(bytes) }

    func flash(_ message: String) {
        notice = message
        Task { try? await Task.sleep(for: .seconds(4)); if notice == message { notice = nil } }
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor in if !title.isEmpty { self.title = title } }
    }
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            self.ended = true
            self.exitCode = exitCode
            self.onExit?(self)
        }
    }
}

// MARK: - All live sessions, grouped per machine (they survive navigation)

@MainActor
final class Terminals: ObservableObject {
    @Published private(set) var sessions: [TermSession] = []
    @Published var active: [String: UUID] = [:]   // machine id → focused tab
    var lastMachine: String?                      // where ⌃Tab returns to from Pipelines, Snippets, …
    weak var store: Store?
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.shortcut(e) ?? e
        }
        // quitting the app ends every session — nothing outlives the window
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.disconnectAll(); self?.store?.flushVault() }   // the closing log lines too
        }
    }

    func tabs(_ machineId: String) -> [TermSession] { sessions.filter { $0.machineId == machineId } }

    /// Machines with a tab open, in the order you connected them — the machine strip and ⌃Tab / ⌃1…⌃9.
    var liveMachines: [String] { sessions.reduce(into: []) { if !$0.contains($1.machineId) { $0.append($1.machineId) } } }

    enum Hop: Equatable { case next, previous, number(Int) }

    /// Which connected machine a hop lands on (nil = no such machine). Off a connected machine, ⌃Tab goes back to
    /// the one you last used.
    nonisolated static func hop(_ h: Hop, live: [String], current: String?, last: String?) -> String? {
        guard !live.isEmpty else { return nil }
        switch h {
        case .number(let n):
            return n == 9 ? live.last : n <= live.count ? live[n - 1] : nil   // ⌃9 = last, like a browser
        case .next, .previous:
            let back = h == .previous
            guard let i = current.flatMap({ live.firstIndex(of: $0) }) else {
                return last.flatMap { live.contains($0) ? $0 : nil } ?? (back ? live.last : live.first)
            }
            return live[(i + (back ? live.count - 1 : 1)) % live.count]
        }
    }

    func current(_ machineId: String) -> TermSession? {
        let t = tabs(machineId)
        return t.first { $0.id == active[machineId] } ?? t.last
    }

    @discardableResult
    func open(_ m: Machine, preset: SshTab? = nil, at index: Int? = nil) -> TermSession {
        let s = TermSession(machine: m, preset: preset)
        s.onExit = { [weak self] s in if s.exitCode == 0 { self?.close(s) } }   // clean exit closes the tab, like Ghostty
        sessions.insert(s, at: min(index ?? sessions.count, sessions.count))
        active[m.id] = s.id
        store?.log(.ssh, machine: m, detail: "opened tab: \(s.name)", user: s.user)
        return s
    }

    func close(_ s: TermSession) {
        let siblings = tabs(s.machineId)
        guard let i = sessions.firstIndex(where: { $0 === s }), let k = siblings.firstIndex(where: { $0 === s }) else { return }
        s.onExit = nil
        if !s.ended { s.term.terminate() }
        sessions.remove(at: i)
        store?.log(.ssh, machine: s.machine, detail: "closed tab: \(s.name)", user: s.user,
                   durationMs: Int(Date().timeIntervalSince(s.started) * 1000))
        if active[s.machineId] == s.id {   // focus the tab to the left, like Ghostty
            let rest = siblings.filter { $0 !== s }
            active[s.machineId] = rest.isEmpty ? nil : rest[max(0, k - 1)].id
        }
    }

    func reconnect(_ s: TermSession) {
        let i = sessions.firstIndex { $0 === s }
        close(s)
        // current settings, not the tab's snapshot — an IP/key edit must apply on reconnect
        open(store?.machines.first { $0.id == s.machineId } ?? s.machine, preset: s.preset, at: i)
    }

    func disconnect(_ machineId: String) { for s in tabs(machineId) { close(s) } }
    func disconnectAll() { for s in sessions { close(s) } }

    /// From any page: ⌃Tab / ⌃⇧Tab cycle connected machines, ⌃1…⌃9 jump to one.
    /// ⌘⇧P types the matching saved password at a sudo/su prompt.
    /// Ghostty bindings while connected: ⌘T new tab · ⌘W close tab · ⌘1…⌘9 jump · ⌘⇧[ / ⌘⇧] cycle.
    private func shortcut(_ e: NSEvent) -> NSEvent? {
        guard e.window?.sheetParent == nil, let store else { return e }
        let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let hop: Hop? = e.keyCode == 48 && (flags == .control || flags == [.control, .shift]) ? (flags.contains(.shift) ? .previous : .next)
            : flags == .control ? Int(key).flatMap { (1...9).contains($0) ? .number($0) : nil } : nil
        var here: String? { if case .machine(let id)? = store.selection { id } else { nil } }
        if let hop, let to = Self.hop(hop, live: liveMachines, current: here, last: lastMachine) {
            store.selection = .machine(to)
            return nil
        }
        guard let id = here, let m = store.machines.first(where: { $0.id == id }), m.usesSSH else { return e }
        let t = tabs(id)
        if flags == .command, key == "t" {
            guard !t.isEmpty else { return e }   // ⌘T adds tabs to a live session; it never starts one
            open(m)
        } else if flags == .command, key == "w" {
            guard let s = current(id) else { return e }   // no tabs → ⌘W closes the window as usual
            close(s)
        } else if flags == .command, let n = Int(key), (1...9).contains(n), !t.isEmpty {
            active[id] = (n == 9 || n > t.count ? t.last : t[n - 1])?.id
        } else if flags == [.command, .shift], key == "p", let s = current(id) {   // type the saved password at a prompt
            Task { await store.fill(s) }
        } else if flags == [.command, .shift], e.keyCode == 30 || e.keyCode == 33, !t.isEmpty {   // ] / [
            let i = t.firstIndex { $0.id == current(id)?.id } ?? 0
            active[id] = t[(i + (e.keyCode == 30 ? 1 : t.count - 1)) % t.count].id
        } else {
            return e
        }
        return nil
    }
}

// MARK: - SwiftUI host — the session's long-lived view, so tabs survive navigation

/// A fresh wrapper per SwiftUI instance that adopts the session's view. SwiftUI tears old wrappers down whenever it
/// gets to it; when it owned the terminal itself, a late teardown after a fast switch pulled the terminal out of the
/// new page (blank until you navigated away and back). Now only the newest wrapper may hold it.
final class TermSlot: NSView {
    let container: TermContainer

    init(_ c: TermContainer) {
        container = c
        super.init(frame: .zero)
        c.slot = self
        adopt()
    }
    required init?(coder: NSCoder) { nil }

    func adopt() {
        guard container.slot === self else { return }   // a newer page has it — never take it back
        if container.superview !== self {
            container.removeFromSuperview()
            addSubview(container)
        }
        container.frame = bounds
    }

    override func layout() { super.layout(); adopt() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, container.slot === self else { return }
        adopt()
        window?.makeFirstResponder(container.term)   // switching lands the cursor in the terminal
    }
}

struct TerminalHost: NSViewRepresentable {
    let session: TermSession
    func makeNSView(context: Context) -> TermSlot { TermSlot(session.container) }
    func updateNSView(_ v: TermSlot, context: Context) { v.adopt() }
}
