import SwiftUI
import AppKit

struct KeysView: View {
    @EnvironmentObject private var store: Store
    @State private var keys: [SSHKeys.KeyInfo] = []
    @State private var encrypted: [String: Bool] = [:]
    @State private var showSheet = false
    @State private var encryptTarget: String?
    @State private var encryptPass = ""
    @State private var encryptError: String?
    @State private var confirmDelete: String?

    var body: some View {
        VStack(spacing: 0) {
            if keys.isEmpty { empty } else {
                List { ForEach(keys) { row($0) } }.listStyle(.inset)
            }
            footer
        }
        .background(Color.bg)
        .navigationTitle("SSH Keys")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 10) {
                    Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Rescan ~/.ssh")
                    Button { showSheet = true } label: { Image(systemName: "plus") }
                        .help("Import or generate a key")
                }
            }
        }
        .task { await reload() }
        .sheet(isPresented: $showSheet, onDismiss: { Task { await reload() } }) {
            ImportKeySheet()
        }
        .sheet(isPresented: Binding(
            get: { encryptTarget != nil },
            set: { if !$0 { encryptTarget = nil; encryptPass = ""; encryptError = nil } }
        )) { encryptSheet }
        .confirmationDialog(
            "Delete ~/.ssh/\(confirmDelete ?? "") (+.pub)?",
            isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete key files", role: .destructive) {
                if let n = confirmDelete {
                    SSHKeys.delete(name: n)
                    store.log(.keyDelete, detail: n)
                    Task { await reload() }
                }
                confirmDelete = nil
            }
        }
    }

    func row(_ k: SSHKeys.KeyInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "key.horizontal").foregroundStyle(Color.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("~/.ssh/" + k.name).font(.mono(13))
                HStack(spacing: 10) {
                    if !k.keyType.isEmpty { Text(k.keyType).font(.mono(10)).foregroundStyle(.dim) }
                    Text(k.hasPrivate ? "private + public" : "public only").font(.mono(10)).foregroundStyle(.tertiary)
                    if let r = store.keys.first(where: { $0.name == k.name }) {
                        Text("· since \(r.addedAt.formatted(.dateTime.month().day()))")
                            .font(.mono(10)).foregroundStyle(.tertiary)
                    }
                    if k.hasPrivate { badge(k) }
                }
            }
            Spacer()
            HStack(spacing: 8) {
                if k.hasPublic {
                    Button("Copy") { copyPub(k) }.controlSize(.small).help("Copy public key")
                }
                if k.hasPrivate {
                    Button("Agent") { SSHKeys.addToAgent(name: k.name) }.controlSize(.small)
                        .help("ssh-add --apple-use-keychain — prompts once, Keychain remembers")
                    if encrypted[k.name] == false {
                        Button("Encrypt…") { encryptTarget = k.name; encryptError = nil }
                            .controlSize(.small).tint(.bad)
                    }
                }
                Button { confirmDelete = k.name } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.dim).help("Delete key files")
            }
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder func badge(_ k: SSHKeys.KeyInfo) -> some View {
        switch encrypted[k.name] {
        case .some(true): Text("ENCRYPTED ✓").font(.mono(9)).foregroundStyle(.ok)
        case .some(false): Text("PLAINTEXT ⚠").font(.mono(9)).foregroundStyle(.bad)
        default: Text("…").font(.mono(9)).foregroundStyle(.tertiary)
        }
    }

    var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "key.slash").font(.system(size: 40)).foregroundStyle(.dim)
            Text("No keys in ~/.ssh").font(.system(size: 15, weight: .semibold))
            Text("Hit + to import or generate — private keys are stored encrypted at rest.")
                .font(.mono(10)).foregroundStyle(.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var footer: some View {
        Text("Private keys stay OpenSSH-encrypted at rest (bcrypt KDF + AES-256-CTR) · the app never stores passphrases · Agent loads a key into ssh-agent with your macOS Keychain")
            .font(.mono(9)).foregroundStyle(.tertiary)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.panelDeep)
    }

    var encryptSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ENCRYPT ~/.ssh/\(encryptTarget ?? "")").font(.mono(11)).foregroundStyle(.dim).tracking(2)
            Text("This key file is currently PLAINTEXT. It will be re-encrypted in place with OpenSSH (bcrypt KDF + AES-256-CTR).")
                .font(.mono(10)).foregroundStyle(.bad)
            SecureField("new passphrase", text: $encryptPass).textFieldStyle(.roundedBorder)
            if let encryptError { Text(encryptError).font(.mono(10)).foregroundStyle(.bad) }
            HStack {
                Spacer()
                Button("Cancel") { encryptTarget = nil; encryptPass = ""; encryptError = nil }
                Button("Encrypt") { Task { await doEncrypt() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(encryptPass.isEmpty)
            }
        }
        .padding(20).frame(width: 460)
        .preferredColorScheme(Theme.current.scheme)
    }

    @MainActor func doEncrypt() async {
        guard let t = encryptTarget else { return }
        let (c, o) = SSHKeys.encryptExisting(name: t, passphrase: encryptPass)
        if c == 0 {
            encryptTarget = nil; encryptPass = ""; encryptError = nil
            await reload()
        } else {
            encryptError = String(o.prefix(200))
        }
    }

    @MainActor func reload() async {
        keys = SSHKeys.list()
        for k in keys where k.hasPrivate {
            encrypted[k.name] = await SSHKeys.isEncrypted(SSHKeys.privPath(k.name))
        }
        store.syncKeys(keys)
    }

    func copyPub(_ k: SSHKeys.KeyInfo) {
        let p = (try? String(contentsOfFile: SSHKeys.pubPath(k.name), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(p, forType: .string)
    }
}

struct ImportKeySheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case priv = "Private Key", pub = "Public Key", gen = "Generate"
        var id: String { rawValue }
    }
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: Store
    @State private var mode: Mode = .priv
    @State private var name = ""
    @State private var pass1 = ""
    @State private var pass2 = ""
    @State private var text = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SSH KEY").font(.mono(11)).foregroundStyle(.dim).tracking(2)
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            field("NAME", mode == .gen ? "id_ed25519" : "my-key", $name)

            if mode != .pub {
                secureField("PASSPHRASE", "required — key is encrypted at rest", $pass1)
                secureField("CONFIRM", "", $pass2)
            }
            if mode != .gen {
                TextEditor(text: $text)
                    .font(.mono(11))
                    .frame(height: 130)
                    .scrollContentBackground(.hidden)
                    .background(Color.panelDeep)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(mode == .priv
                                 ? "paste private key — it will be stored ENCRYPTED (plaintext keys are encrypted on import)"
                                 : "paste public key — ssh-ed25519 AAAA… comment")
                                .font(.mono(10)).foregroundStyle(.tertiary)
                                .padding(8).allowsHitTesting(false)
                        }
                    }
            }
            if let errorText { Text(errorText).font(.mono(10)).foregroundStyle(.bad) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(mode == .gen ? "Generate" : "Import") { submit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
        .preferredColorScheme(Theme.current.scheme)
    }

    func submit() {
        let n = name.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .gen:
            guard passOK() else { return }
            let nm = n.isEmpty ? "id_ed25519" : n
            let (c, o) = SSHKeys.generate(name: nm, passphrase: pass1)
            if c == 0 { store.log(.keyAdd, detail: nm); dismiss() } else { fail(String(o.prefix(200))) }
        case .priv:
            guard !n.isEmpty else { fail("name required"); return }
            guard passOK() else { return }
            if let e = SSHKeys.importPrivate(name: n, text: text, passphrase: pass1) { fail(e) } else {
                store.log(.keyAdd, detail: n)
                dismiss()
            }
        case .pub:
            guard !n.isEmpty else { fail("name required"); return }
            if let e = SSHKeys.importPublic(name: n, text: text.trimmingCharacters(in: .whitespacesAndNewlines)) { fail(e) } else {
                store.log(.keyAdd, detail: n)
                dismiss()
            }
        }
    }

    func passOK() -> Bool {
        guard !pass1.isEmpty else { fail("passphrase required — private keys are encrypted at rest, always"); return false }
        guard pass1 == pass2 else { fail("passphrases don't match"); return false }
        return true
    }

    func fail(_ m: String) { errorText = m }

    func field(_ label: String, _ prompt: String, _ b: Binding<String>) -> some View {
        HStack(spacing: 0) {
            Text(label).font(.mono(10)).foregroundStyle(.dim).frame(width: 100, alignment: .leading).tracking(1)
            TextField(prompt, text: b).textFieldStyle(.roundedBorder).font(.mono(11))
        }
    }

    func secureField(_ label: String, _ prompt: String, _ b: Binding<String>) -> some View {
        HStack(spacing: 0) {
            Text(label).font(.mono(10)).foregroundStyle(.dim).frame(width: 100, alignment: .leading).tracking(1)
            SecureField(prompt, text: b).textFieldStyle(.roundedBorder).font(.mono(11))
        }
    }
}
