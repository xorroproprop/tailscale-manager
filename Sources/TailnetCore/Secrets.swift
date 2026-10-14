import SwiftUI
import AppKit
import LocalAuthentication

// MARK: - Server passwords for sudo / su — you add them, Touch ID (or your Mac password) releases them

struct Credential: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    var machineId: String
    var user: String        // whose password: "root", "deploy"…
    var sealed: Data        // AES-GCM box (see Store.saveCredential) — never stored or held in the clear
    var addedAt = Date()
}

/// Touch ID / login-password gate. One unlock covers a short burst of sudo prompts, then it shuts.
@MainActor
enum Gate {
    static let grace: TimeInterval = 60
    private static var until = Date.distantPast

    static func unlock(_ reason: String) async -> Bool {
        if Date() < until { return true }
        do {
            guard try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else { return false }
            until = Date().addingTimeInterval(grace)
            return true
        } catch { return false }
    }

    static func lock() { until = .distantPast }

    /// Screen lock, display sleep or system sleep → locked again.
    static func lockOnSleep() {
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { _ in MainActor.assumeIsolated { lock() } }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { lock() }
        }
    }
}

enum PasswordPrompt {
    /// The text left of the cursor is asking for a password ("[sudo] password for x: ", "Password:", "x@h's password:",
    /// "Enter passphrase for key …:"). A shell prompt sigil ($ # % > and starship/oh-my-zsh/fish ❯ ➜ λ » ›) before the
    /// word means it's a command line someone typed "password:" on — refuse, or the secret would land in the shell's history.
    static func matches(_ line: String) -> Bool {
        line.wholeMatch(of: #/(?i)[^$#%>❯➜λ»›\n]*(password|passphrase)[^:\n]*:\s*/#) != nil
    }

    /// Which saved password this prompt wants. Ambiguous → nil (you pick from the menu) — a wrong guess
    /// costs a failed sudo attempt on the server, so we never guess between users.
    static func pick(_ line: String, from creds: [Credential]) -> Credential? {
        if let m = line.firstMatch(of: #/(?i)password for ([^\s:]+)/#) {
            return creds.first { $0.user == String(m.1) }
        }
        return creds.count == 1 ? creds[0] : nil
    }
}

/// Clipboard fallback: this Mac only (no Universal Clipboard), hidden from clipboard managers, gone in 30 s.
enum SecretPasteboard {
    static let clearAfter: TimeInterval = 30

    static func copy(_ bytes: [UInt8]) {
        let pb = NSPasteboard.general
        pb.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        item.setString(String(decoding: bytes, as: UTF8.self), forType: .string)
        item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
        pb.writeObjects([item])
        let mine = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter) {
            if pb.changeCount == mine { pb.clearContents() }   // only if nothing else was copied since
        }
    }
}

/// ponytail: best-effort wipe — Swift may have copied the bytes; the OS-level guarantees are the seal + gate
private func wipe(_ b: inout [UInt8]) { for i in b.indices { b[i] = 0 } }

extension Store {
    /// Type a saved password at the prompt in `s`. Checks the prompt before *and* after Touch ID,
    /// so a password can never be typed into a shell (and its history) by mistake.
    func fill(_ s: TermSession, with chosen: Credential? = nil) async {
        let creds = credentials(for: s.machineId)
        guard !s.ended else { return }
        guard PasswordPrompt.matches(s.promptLine) else {
            s.flash("no password prompt at the cursor — nothing typed")
            return
        }
        guard let c = chosen ?? PasswordPrompt.pick(s.promptLine, from: creds) else {
            s.flash(creds.isEmpty ? "no saved passwords for this machine — add one in the inspector"
                                  : "which one? pick it from the 🔑 menu")
            return
        }
        guard await Gate.unlock("type the \(c.user) password for \(s.machine.name)") else {
            s.flash("not unlocked — nothing typed")
            return
        }
        guard !s.ended, PasswordPrompt.matches(s.promptLine) else {
            s.flash("the prompt went away — nothing typed")
            return
        }
        guard var secret = openCredential(c) else { s.flash("couldn't decrypt that password"); return }
        secret.append(13)   // ⏎
        s.type(secret)
        wipe(&secret)
        log(.password, machine: s.machine, detail: "typed \(c.user) password · tab \(s.name)")
    }

    @discardableResult
    func copyCredential(_ c: Credential, machine: Machine) async -> Bool {
        guard await Gate.unlock("copy the \(c.user) password for \(machine.name)"),
              var secret = openCredential(c) else { return false }
        SecretPasteboard.copy(secret)
        wipe(&secret)
        log(.password, machine: machine, detail: "copied \(c.user) password (clears in \(Int(SecretPasteboard.clearAfter))s)")
        return true
    }
}

// MARK: - Inspector: add / copy / delete

struct PasswordsSection: View {
    @EnvironmentObject private var store: Store
    let machine: Machine
    @State private var user = ""
    @State private var pass1 = ""
    @State private var pass2 = ""
    @State private var error: String?
    @State private var confirmDelete: Credential?
    @State private var copied: String?

    var body: some View {
        let creds = store.credentials(for: machine.id)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(creds) { c in
                HStack(spacing: 8) {
                    Image(systemName: "key.fill").foregroundStyle(Color.accent).font(.system(size: 10))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.user).font(.mono(11))
                        Text(copied == c.id && error == nil ? "copied — clears in \(Int(SecretPasteboard.clearAfter)) s"
                             : "•••••••• · added \(c.addedAt.formatted(.dateTime.month().day()))")
                            .font(.mono(9)).foregroundStyle(copied == c.id && error == nil ? Color.ok : Color.dim)
                    }
                    Spacer()
                    Button("Copy") {
                        Task { error = await store.copyCredential(c, machine: machine) ? nil : "not unlocked"; copied = c.id }
                    }
                        .controlSize(.small).help("Touch ID, then copied for \(Int(SecretPasteboard.clearAfter)) s — this Mac only")
                    Button { confirmDelete = c } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).foregroundStyle(.dim).help("Delete")
                }
            }
            field("USER", TextField(machine.sshLogin, text: $user))
            field("PASSWORD", SecureField("", text: $pass1))
            field("CONFIRM", SecureField("", text: $pass2))
            HStack {
                if let error { Text(error).font(.mono(9)).foregroundStyle(.bad) }
                Spacer()
                Button(creds.contains { $0.user == effectiveUser } ? "Replace" : "Save") { save() }
                    .controlSize(.small).disabled(pass1.isEmpty)
            }
            Text("sealed with AES-256-GCM (key from your Keychain) · Touch ID or Mac password to use · ⌘⇧P types it at a sudo prompt · no reveal")
                .font(.mono(8)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog("Delete the saved \(confirmDelete?.user ?? "") password?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let c = confirmDelete {
                    store.deleteCredential(c.id)
                    store.log(.password, machine: machine, detail: "deleted \(c.user) password")
                }
                confirmDelete = nil
            }
        }
    }

    var effectiveUser: String { user.trimmingCharacters(in: .whitespaces).isEmpty ? machine.sshLogin : user.trimmingCharacters(in: .whitespaces) }

    func save() {
        guard pass1 == pass2 else { error = "passwords don't match"; return }
        if let e = store.saveCredential(machine: machine.id, user: effectiveUser, password: pass1) { error = e; return }
        store.log(.password, machine: machine, detail: "saved \(effectiveUser) password")
        user = ""; pass1 = ""; pass2 = ""; error = nil
    }

    func field<F: View>(_ k: String, _ f: F) -> some View {
        HStack(spacing: 6) {
            Text(k).font(.mono(9)).foregroundStyle(.dim).tracking(1).frame(width: 74, alignment: .leading)
            f.textFieldStyle(.roundedBorder).font(.mono(11))
        }
    }
}

// MARK: - Tab bar 🔑 menu

struct PasswordMenu: View {
    @EnvironmentObject private var store: Store
    let machine: Machine
    let session: TermSession?

    var body: some View {
        let creds = store.credentials(for: machine.id)
        if !creds.isEmpty {
            Menu {
                Section("Type at the prompt") {
                    ForEach(creds) { c in
                        Button("\(c.user)") { if let s = session { Task { await store.fill(s, with: c) } } }
                    }
                }
                Section("Copy (clears in \(Int(SecretPasteboard.clearAfter)) s)") {
                    ForEach(creds) { c in
                        Button("\(c.user)") {
                            Task {
                                if await store.copyCredential(c, machine: machine) {
                                    session?.flash("copied \(c.user) password — clears in \(Int(SecretPasteboard.clearAfter)) s")
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Lock now") { Gate.lock() }
            } label: {
                Image(systemName: "key.fill")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .padding(.horizontal, 10)
            .help("Saved passwords — ⌘⇧P types the matching one at a sudo prompt")
        }
    }
}

/// Short-lived message over the terminal (fill refused, nothing typed, …).
struct NoticeBanner: View {
    @ObservedObject var s: TermSession

    var body: some View {
        if let n = s.notice {
            Text(n).font(.mono(10)).padding(.horizontal, 12).padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.accent.opacity(0.4)))
                .padding(12)
                .transition(.opacity)
        }
    }
}
