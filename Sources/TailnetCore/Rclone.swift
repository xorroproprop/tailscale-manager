import SwiftUI
import AppKit

// MARK: - rclone remotes: define once (secrets sealed in the vault), deploy to a machine when you choose
// Secrets reach the host as a script on ssh stdin — never argv (ps) — and rclone obscures passwords there.

struct RcloneField: Hashable, Identifiable {
    /// secret = sensitive, written as-is (rclone keeps it plain) · password = sensitive, rclone wants it obscured
    enum Kind: Hashable { case text, secret, password, bool, choice([String]), path }
    let key: String
    let label: String
    var kind: Kind = .text
    var required = false
    var placeholder = ""
    var initial = ""
    var help = ""
    var id: String { key }
    var sensitive: Bool { kind == .secret || kind == .password }
}

struct RcloneBackend: Identifiable {
    let type: String
    let label: String
    let fields: [RcloneField]
    var id: String { type }
}

struct RcloneRemote: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    var name = ""
    var type = "s3"
    var values: [String: String] = [:]   // non-secret options
    var sealed: Data? = nil              // AES-GCM JSON of the secret options ("rclone" domain)
    var secretKeys: [String] = []        // which secrets are saved — names only, for the UI
    var testPath = ""                    // e.g. bucket/prefix, for Test
    var deployed: [String: Date] = [:]   // machine id ("local" = this Mac) → when
}

enum Rclone {
    static let backends: [RcloneBackend] = [
        .init(type: "s3", label: "S3", fields: [
            .init(key: "provider", label: "PROVIDER", kind: .choice(["AWS", "Cloudflare", "Wasabi", "DigitalOcean", "Minio", "Ceph",
                                                                      "Scaleway", "Linode", "IDrive", "GCS", "Other"]),
                  required: true, initial: "AWS"),
            .init(key: "env_auth", label: "IAM ROLE", kind: .bool, help: "use the host's IAM role / env credentials instead of keys"),
            .init(key: "access_key_id", label: "ACCESS KEY"),
            .init(key: "secret_access_key", label: "SECRET KEY", kind: .secret),
            .init(key: "region", label: "REGION", placeholder: "us-east-1 · R2: auto"),
            .init(key: "endpoint", label: "ENDPOINT", placeholder: "non-AWS, e.g. https://<account>.r2.cloudflarestorage.com"),
        ]),
        .init(type: "sftp", label: "SFTP", fields: [
            .init(key: "host", label: "HOST", required: true, placeholder: "files.example.com"),
            .init(key: "user", label: "USER"),
            .init(key: "port", label: "PORT", placeholder: "22"),
            .init(key: "key_file", label: "KEY FILE", kind: .path, placeholder: "~/.ssh/id_ed25519 — path on the host"),
            .init(key: "pass", label: "PASSWORD", kind: .password, help: "leave empty when using a key"),
            .init(key: "known_hosts_file", label: "KNOWN HOSTS", kind: .path, initial: "~/.ssh/known_hosts",
                  help: "verifies the server's host key — without it rclone accepts any key"),
        ]),
        .init(type: "google cloud storage", label: "GCS", fields: [
            .init(key: "project_number", label: "PROJECT", placeholder: "project number or id"),
            .init(key: "env_auth", label: "VM / ADC", kind: .bool, help: "use the VM's service account / application default credentials"),
            .init(key: "service_account_file", label: "SA KEY FILE", kind: .path, placeholder: "/path/on/host/sa.json"),
            .init(key: "bucket_policy_only", label: "UNIFORM ACL", kind: .bool, help: "bucket uses uniform bucket-level access"),
        ]),
        .init(type: "b2", label: "Backblaze B2", fields: [
            .init(key: "account", label: "KEY ID", required: true),
            .init(key: "key", label: "APP KEY", kind: .secret, required: true),
            .init(key: "hard_delete", label: "HARD DELETE", kind: .bool, help: "delete instead of hide old versions"),
        ]),
        .init(type: "azureblob", label: "Azure Blob", fields: [
            .init(key: "account", label: "ACCOUNT"),
            .init(key: "key", label: "ACCOUNT KEY", kind: .secret),
            .init(key: "sas_url", label: "SAS URL", kind: .secret, help: "alternative to account + key"),
            .init(key: "env_auth", label: "MANAGED ID", kind: .bool, help: "use managed identity / env credentials"),
        ]),
        .init(type: "webdav", label: "WebDAV", fields: [
            .init(key: "url", label: "URL", required: true, placeholder: "https://cloud.example.com/remote.php/dav/files/me"),
            .init(key: "vendor", label: "VENDOR", kind: .choice(["nextcloud", "owncloud", "sharepoint", "sharepoint-ntlm", "fastmail", "rclone", "other"]),
                  initial: "other"),
            .init(key: "user", label: "USER"),
            .init(key: "pass", label: "PASSWORD", kind: .password),
            .init(key: "bearer_token", label: "TOKEN", kind: .secret, help: "instead of user + password"),
        ]),
        .init(type: "smb", label: "SMB", fields: [
            .init(key: "host", label: "HOST", required: true, placeholder: "nas.local"),
            .init(key: "user", label: "USER"),
            .init(key: "pass", label: "PASSWORD", kind: .password),
            .init(key: "port", label: "PORT", placeholder: "445"),
            .init(key: "domain", label: "DOMAIN", placeholder: "WORKGROUP"),
        ]),
        .init(type: "ftp", label: "FTP", fields: [
            .init(key: "host", label: "HOST", required: true),
            .init(key: "user", label: "USER"),
            .init(key: "pass", label: "PASSWORD", kind: .password),
            .init(key: "port", label: "PORT", placeholder: "21"),
            .init(key: "explicit_tls", label: "FTPS", kind: .bool, initial: "true", help: "explicit TLS — plain FTP sends your password in the clear"),
        ]),
        .init(type: "crypt", label: "Crypt", fields: [
            .init(key: "remote", label: "WRAPS", required: true, placeholder: "my-s3:bucket/encrypted"),
            .init(key: "password", label: "PASSWORD", kind: .password, required: true, help: "lose it and the data is gone — keep a copy"),
            .init(key: "password2", label: "SALT", kind: .password, help: "second password (recommended)"),
            .init(key: "filename_encryption", label: "FILENAMES", kind: .choice(["standard", "obfuscate", "off"]), initial: "standard"),
            .init(key: "directory_name_encryption", label: "ENCRYPT DIRS", kind: .bool, initial: "true"),
        ]),
    ]

    static func backend(_ type: String) -> RcloneBackend? { backends.first { $0.type == type } }

    static let nameRule = #/[A-Za-z0-9_][A-Za-z0-9_.-]*/#
    static let keyRule = #/[a-z0-9_]+/#

    /// The options in write order. Bools are always explicit (some rclone defaults are true);
    /// "Other" types carry everything sealed, written as given.
    static func entries(_ r: RcloneRemote, secrets: [String: String]) -> [(key: String, value: String, obscure: Bool)] {
        guard let b = backend(r.type) else {
            return secrets.sorted { $0.key < $1.key }.map { ($0.key, $0.value, false) }
        }
        return b.fields.compactMap { f in
            let v = (f.sensitive ? secrets[f.key] : r.values[f.key]) ?? ""
            if case .bool = f.kind { return (f.key, v == "true" ? "true" : "false", false) }
            return v.isEmpty ? nil : (f.key, v, f.kind == .password)
        }
    }

    /// rclone.conf section as it will land — secrets masked.
    static func preview(_ r: RcloneRemote, saved: Set<String>) -> String {
        let fake = Dictionary(uniqueKeysWithValues: saved.map { ($0, "••••••") })
        return (["[\(r.name.isEmpty ? "name" : r.name)]", "type = \(r.type)"]
                + entries(r, secrets: fake).map { "\($0.key) = \($0.obscure ? "•••••• (obscured on the host)" : $0.value)" })
            .joined(separator: "\n")
    }

    /// POSIX sh, run on the host with `sh -s` — the secrets live only in this stdin stream.
    static func deployScript(_ r: RcloneRemote, secrets: [String: String], replace: Bool) -> String {
        let q = Remote.q
        let header = q("[\(r.name)]")
        var s = #"""
        set -e
        command -v rclone >/dev/null 2>&1 || { echo 'TNM_ERR rclone is not installed on this host'; exit 3; }
        umask 077
        f=$(rclone config file 2>/dev/null | tail -n 1)
        case "$f" in /*) ;; *) echo 'TNM_ERR could not locate rclone.conf'; exit 3;; esac
        mkdir -p "$(dirname "$f")"
        touch "$f"
        if grep -q '^RCLONE_ENCRYPT_V0:' "$f"; then echo 'TNM_ERR rclone.conf is encrypted on this host — add this remote with rclone config there'; exit 3; fi

        """#
        s += "if grep -qxF \(header) \"$f\"; then\n"
        s += replace
            // one backup, the newest: older ones would keep rotated-out secrets on the host forever
            ? "  b=\"$f.tnm-$(date +%s)-$$.bak\"\n  cp \"$f\" \"$b\"\n"
              + "  for o in \"$f\".tnm-*.bak; do [ \"$o\" = \"$b\" ] || rm -f \"$o\"; done\n"
              + "  t=$(mktemp \"$f.XXXXXX\") || exit 3\n"   // unique: two deploys at once can't share a temp file
              + "  awk -v s=\(header) '/^\\[/{skip=($0==s)} !skip' \"$f\" > \"$t\"\n"
              + "  cat \"$t\" > \"$f\"\n  rm -f \"$t\"\n"
            : "  echo TNM_EXISTS\n  exit 4\n"
        s += "fi\n"
        let es = entries(r, secrets: secrets)
        for (i, e) in es.enumerated() where e.obscure {
            s += "o\(i)=$(printf '%s\\n' \(q(e.value)) | rclone obscure -)\n"   // printf is a builtin: never in ps
        }
        s += "{\n  printf '\\n[%s]\\ntype = %s\\n' \(q(r.name)) \(q(r.type))\n"
        for (i, e) in es.enumerated() {
            s += "  printf '%s = %s\\n' \(q(e.key)) \(e.obscure ? "\"$o\(i)\"" : q(e.value))\n"
        }
        s += "} >> \"$f\"\nchmod 600 \"$f\"\necho \"TNM_OK $f\"\n"
        return s
    }

    /// Run on a host: this Mac locally, otherwise key-only SSH (BatchMode, strict host keys).
    @MainActor
    static func run(_ m: Machine, _ command: String, input: Data? = nil) async -> (code: Int32, output: String) {
        m.id == Transfers.local.id
            ? await Shell.run("/bin/sh -c " + Remote.q(command), input: input)
            : await Shell.run(Remote.sshCommand(m, command: command), input: input)
    }
}

// MARK: - Store: definitions + actions

extension Store {
    func remoteSecrets(_ r: RcloneRemote) -> [String: String]? {
        guard let box = r.sealed else { return [:] }
        return unseal(box, "rclone").flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
    }

    /// Save a definition. Blank secret = keep the saved one; `cleared` drops saved ones. Returns an error message.
    func saveRemote(_ draft: RcloneRemote, newSecrets: [String: String], cleared: Set<String> = []) -> String? {
        var r = draft
        r.name = r.name.trimmingCharacters(in: .whitespaces)
        r.type = r.type.trimmingCharacters(in: .whitespaces)
        guard r.name.wholeMatch(of: Rclone.nameRule) != nil else { return "name: letters, digits, _ . - (no spaces)" }
        guard !remotes.contains(where: { $0.name == r.name && $0.id != r.id }) else { return "a remote named \(r.name) already exists" }
        guard r.type.wholeMatch(of: #/[a-z0-9][a-z0-9 ]*/#) != nil else { return "type: lowercase rclone backend name" }

        let old = remotes.first { $0.id == r.id }.flatMap { remoteSecrets($0) } ?? [:]
        var secrets = old.filter { !cleared.contains($0.key) }
        for (k, v) in newSecrets where !v.isEmpty { secrets[k] = v }
        if let b = Rclone.backend(r.type) {   // keep only this backend's options (type may have changed)
            let keys = Set(b.fields.map(\.key)), secretKeys = Set(b.fields.filter(\.sensitive).map(\.key))
            r.values = r.values.filter { keys.contains($0.key) && !secretKeys.contains($0.key) }.mapValues { $0.trimmingCharacters(in: .whitespaces) }
            secrets = secrets.filter { secretKeys.contains($0.key) }
            for f in b.fields where f.required && (f.sensitive ? secrets[f.key] : r.values[f.key]).map(\.isEmpty) ?? true {
                return "\(f.label.lowercased()) is required"
            }
        } else {
            r.values = [:]
            guard secrets.keys.allSatisfy({ $0.wholeMatch(of: Rclone.keyRule) != nil }) else { return "option names: lowercase letters, digits, _" }
        }
        guard (Array(r.values.values) + Array(secrets.values) + [r.testPath]).allSatisfy({ !$0.contains(where: \.isNewline) }) else {
            return "values can't contain line breaks"
        }
        if secrets.isEmpty {
            r.sealed = nil
        } else {
            guard let json = try? JSONEncoder().encode(secrets), let box = seal(json, "rclone") else {
                return "encrypted vault unavailable (Keychain) — not storing secrets in the clear"
            }
            r.sealed = box
        }
        r.secretKeys = secrets.keys.sorted()
        if let i = remotes.firstIndex(where: { $0.id == r.id }) { remotes[i] = r } else { remotes.append(r) }
        return nil
    }

    func deleteRemote(_ id: String) { remotes.removeAll { $0.id == id } }

    private func setDeployed(_ id: String, _ machineId: String, _ at: Date?) {
        if let i = remotes.firstIndex(where: { $0.id == id }) { remotes[i].deployed[machineId] = at }
    }

    enum DeployResult { case ok(String), exists, failed(String) }

    /// Explicit action only. Touch ID before any secret leaves the vault.
    func deploy(_ r: RcloneRemote, to m: Machine, replace: Bool) async -> DeployResult {
        var secrets: [String: String] = [:]
        if r.sealed != nil {
            guard await Gate.unlock("send the \(r.name) rclone credentials to \(m.name)") else { return .failed("not unlocked") }
            guard let s = remoteSecrets(r) else { return .failed("couldn't decrypt the saved secrets") }
            secrets = s
        }
        let (code, out) = await Rclone.run(m, "sh -s", input: Data(Rclone.deployScript(r, secrets: secrets, replace: replace).utf8))
        let lines = out.split(separator: "\n").map(String.init)
        if lines.contains("TNM_EXISTS") { return .exists }
        if code == 0, let ok = lines.last(where: { $0.hasPrefix("TNM_OK ") }) {
            setDeployed(r.id, m.id, Date())
            log(.rclone, machine: m, detail: "deployed remote \(r.name) (\(r.type))" + (replace ? " · replaced existing" : ""))
            return .ok(String(ok.dropFirst(7)))
        }
        let why = lines.last { $0.hasPrefix("TNM_ERR ") }.map { String($0.dropFirst(8)) } ?? Remote.authReport(out, ok: false)
        log(.rclone, machine: m, detail: "deploy \(r.name) failed: \(why)")
        return .failed(why)
    }

    func testRemote(_ r: RcloneRemote, on m: Machine) async -> (ok: Bool, detail: String) {
        let target = Remote.q(r.name + ":" + r.testPath.trimmingCharacters(in: .whitespaces))
        let cmd = "out=$(rclone lsf \(target) --max-depth 1 --contimeout 10s --timeout 20s --retries 1 --low-level-retries 1 2>&1); c=$?; "
            + "printf '%s\\n' \"$out\" | head -n 5; exit $c"
        let (code, out) = await Rclone.run(m, cmd)
        let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
        log(.rclone, machine: m, detail: "tested remote \(r.name): " + (code == 0 ? "ok" : "failed"))
        if code == 0 { return (true, text.isEmpty ? "reachable · empty" : "reachable · " + text.split(separator: "\n").prefix(3).joined(separator: ", ")) }
        return (false, text.split(separator: "\n").last.map(String.init) ?? "exit \(code)")
    }

    func removeRemote(_ r: RcloneRemote, from m: Machine) async -> String? {
        let (code, out) = await Rclone.run(m, "rclone config delete \(Remote.q(r.name))")
        guard code == 0 else { return out.trimmingCharacters(in: .whitespacesAndNewlines) }
        setDeployed(r.id, m.id, nil)
        log(.rclone, machine: m, detail: "removed remote \(r.name)")
        return nil
    }
}

// MARK: - Cloud page section

struct RemotesSection: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var cloud: Transfers
    @State private var editing: RcloneRemote?
    @State private var status: [String: (ok: Bool, text: String)] = [:]
    @State private var replaceAsk: (remote: RcloneRemote, machine: Machine)?
    @State private var deleteAsk: RcloneRemote?
    @State private var working: String?

    /// This Mac + machines you've verified key auth on (deploy uses key-only SSH).
    var targets: [Machine] { [Transfers.local] + store.machines.filter { $0.usesSSH && $0.authVerifiedAt != nil } }
    var unverified: [Machine] { store.machines.filter { $0.usesSSH && $0.authVerifiedAt == nil } }

    func name(_ id: String) -> String {
        id == Transfers.local.id ? "this mac" : store.machines.first { $0.id == id }.map { $0.name.isEmpty ? $0.host : $0.name } ?? "deleted"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.remotes.isEmpty {
                Text("no remotes yet — define S3, SFTP, GCS, B2, Azure, WebDAV, SMB, FTP or Crypt once, deploy to any machine")
                    .font(.mono(10)).foregroundStyle(.tertiary)
            }
            ForEach(store.remotes) { card($0) }
            Button { editing = RcloneRemote() } label: { Label("New remote", systemImage: "plus") }
                .controlSize(.small)
        }
        .sheet(item: $editing) { RemoteEditor(remote: $0) }
        .confirmationDialog("\(replaceAsk?.remote.name ?? "") already exists on \(replaceAsk.map { name($0.machine.id) } ?? "")",
                            isPresented: Binding(get: { replaceAsk != nil }, set: { if !$0 { replaceAsk = nil } })) {
            Button("Replace (backup kept next to rclone.conf)", role: .destructive) {
                if let a = replaceAsk { run(a.remote, a.machine, replace: true) }
                replaceAsk = nil
            }
        }
        .confirmationDialog("Delete the \(deleteAsk?.name ?? "") definition?", isPresented: Binding(get: { deleteAsk != nil }, set: { if !$0 { deleteAsk = nil } })) {
            Button("Delete definition", role: .destructive) { if let r = deleteAsk { store.deleteRemote(r.id) }; deleteAsk = nil }
        } message: { Text("Hosts it was deployed to keep their copy — use Remove from first if you want it gone there too.") }
    }

    func card(_ r: RcloneRemote) -> some View {
        let label = Rclone.backend(r.type)?.label ?? r.type
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(label.uppercased()).font(.mono(9).weight(.bold)).tracking(1.5)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(Color.accent)
                Text(r.name).font(.mono(12).weight(.semibold))
                Text(summary(r)).font(.mono(10)).foregroundStyle(.dim).lineLimit(1)
                Spacer()
                if working == r.id { ProgressView().controlSize(.small) }
                Menu("Deploy") {
                    ForEach(targets) { m in
                        Button(name(m.id) + (r.deployed[m.id] != nil ? "  (update)" : "")) { run(r, m, replace: r.deployed[m.id] != nil) }
                    }
                    if !unverified.isEmpty {
                        Divider()
                        ForEach(unverified) { m in Button("\(m.name) — Test connection first") {}.disabled(true) }
                    }
                }
                .fixedSize()
                Menu("Test") {
                    ForEach(targets.filter { r.deployed[$0.id] != nil }) { m in
                        Button(name(m.id)) { test(r, m) }
                    }
                }
                .fixedSize().disabled(r.deployed.isEmpty)
                Menu {
                    Button("Edit…") { editing = r }
                    Menu("Remove from") {
                        ForEach(targets.filter { r.deployed[$0.id] != nil }) { m in Button(name(m.id)) { remove(r, m) } }
                    }
                    .disabled(r.deployed.isEmpty)
                    Divider()
                    Button("Delete definition…", role: .destructive) { deleteAsk = r }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .controlSize(.small)
            HStack(spacing: 8) {
                Text("ON").font(.mono(8)).foregroundStyle(.dim).tracking(1.5)
                if r.deployed.isEmpty {
                    Text("not deployed yet").font(.mono(10)).foregroundStyle(.tertiary)
                }
                ForEach(r.deployed.sorted { $0.value > $1.value }, id: \.key) { id, at in
                    Text("\(name(id)) · \(at.formatted(.dateTime.month().day()))").font(.mono(9))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.ok.opacity(0.12), in: Capsule()).foregroundStyle(Color.ok)
                }
            }
            if let s = status[r.id] {
                Text((s.ok ? "✓ " : "✗ ") + s.text).font(.mono(9)).foregroundStyle(s.ok ? Color.ok : Color.bad)
                    .textSelection(.enabled).lineLimit(2)
            }
        }
        .padding(12)
        .background(Color.panelDeep, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.ink.opacity(0.07)))
    }

    func summary(_ r: RcloneRemote) -> String {
        let main = ["provider", "host", "url", "account", "project_number", "remote"].compactMap { r.values[$0] }.first ?? ""
        let secrets = r.secretKeys.isEmpty ? "" : "\(r.secretKeys.count) secret\(r.secretKeys.count == 1 ? "" : "s") sealed"
        return [main, secrets].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    func run(_ r: RcloneRemote, _ m: Machine, replace: Bool) {
        working = r.id
        Task {
            switch await store.deploy(r, to: m, replace: replace) {
            case .ok(let path): status[r.id] = (true, "deployed to \(name(m.id)) — \(path)")
            case .exists: replaceAsk = (r, m)
            case .failed(let why): status[r.id] = (false, "\(name(m.id)): \(why)")
            }
            working = nil
            await cloud.scan(remote: true, refreshIdentities: true)   // CLOUD ACCOUNTS shows the new remote
        }
    }

    func test(_ r: RcloneRemote, _ m: Machine) {
        working = r.id
        Task {
            let t = await store.testRemote(r, on: m)
            status[r.id] = (t.ok, "\(name(m.id)): \(t.detail)")
            working = nil
        }
    }

    func remove(_ r: RcloneRemote, _ m: Machine) {
        working = r.id
        Task {
            let e = await store.removeRemote(r, from: m)
            status[r.id] = e == nil ? (true, "removed from \(name(m.id))") : (false, "\(name(m.id)): \(e!)")
            working = nil
        }
    }
}

// MARK: - Editor sheet

struct RemoteEditor: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var remote: RcloneRemote
    @State private var choice = ""                         // backend type, or "" for Other
    @State private var secrets: [String: String] = [:]     // typed this time (blank = keep saved)
    @State private var cleared: Set<String> = []
    @State private var otherRaw = ""
    @State private var error: String?

    var backend: RcloneBackend? { Rclone.backend(choice) }
    var saved: Set<String> { Set(remote.secretKeys).subtracting(cleared) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.remotes.contains { $0.id == remote.id } ? "EDIT RCLONE REMOTE" : "NEW RCLONE REMOTE")
                .font(.mono(11)).foregroundStyle(.dim).tracking(2)
            Picker("", selection: $choice) {
                ForEach(Rclone.backends) { Text($0.label).tag($0.type) }
                Text("Other…").tag("")
            }
            .labelsHidden()
            row("NAME") { TextField("e.g. r2-backups", text: $remote.name) }
            if backend == nil {
                row("TYPE") { TextField("rclone backend, e.g. hdfs", text: $remote.type) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    if let b = backend {
                        ForEach(b.fields) { field($0) }
                    } else {
                        Text("options, one per line: key = value — all sealed as secrets, written as given (obscure passwords yourself with rclone obscure)")
                            .font(.mono(9)).foregroundStyle(.tertiary)
                        TextEditor(text: $otherRaw).font(.mono(11)).frame(height: 110)
                            .scrollContentBackground(.hidden).background(Color.panelDeep)
                        if !saved.isEmpty { Text("saved: \(saved.sorted().joined(separator: ", ")) — leave empty to keep").font(.mono(9)).foregroundStyle(.dim) }
                    }
                    row("TEST PATH") { TextField("optional — bucket/prefix used by Test", text: $remote.testPath) }
                }
            }
            .frame(maxHeight: 330)
            Text(Rclone.preview(remote, saved: saved.union(secrets.filter { !$0.value.isEmpty }.keys)))
                .font(.mono(10)).foregroundStyle(.dim).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.bg, in: RoundedRectangle(cornerRadius: 6))
            if let error { Text(error).font(.mono(10)).foregroundStyle(.bad) }
            HStack {
                Text("secrets sealed in the vault · sent only on Deploy, after Touch ID").font(.mono(9)).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 580)
        .preferredColorScheme(Theme.current.scheme)
        .onAppear {
            choice = Rclone.backend(remote.type) == nil && !remote.name.isEmpty ? "" : remote.type
            applyInitials()
        }
        .onChange(of: choice) { _, c in
            if !c.isEmpty { remote.type = c } else if Rclone.backend(remote.type) != nil { remote.type = "" }
            applyInitials()
        }
    }

    /// Defaults for a fresh form (FTPS on, known_hosts on, …) — never overrides what's there.
    func applyInitials() {
        for f in backend?.fields ?? [] where !f.initial.isEmpty && remote.values[f.key] == nil { remote.values[f.key] = f.initial }
    }

    func save() {
        var typed = secrets
        if backend == nil {
            for line in otherRaw.split(whereSeparator: \.isNewline) {
                let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2, !kv[0].isEmpty else { error = "can't read “\(line)” — use key = value"; return }
                typed[kv[0]] = kv[1]
            }
        }
        if let e = store.saveRemote(remote, newSecrets: typed, cleared: cleared) { error = e } else { dismiss() }
    }

    func row<C: View>(_ k: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 8) {
            Text(k).font(.mono(9)).foregroundStyle(.dim).tracking(1).frame(width: 96, alignment: .leading)
            c().textFieldStyle(.roundedBorder).font(.mono(11))
        }
    }

    func value(_ key: String) -> Binding<String> {
        Binding(get: { remote.values[key] ?? "" }, set: { remote.values[key] = $0 })
    }

    @ViewBuilder func field(_ f: RcloneField) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            row(f.label + (f.required ? " *" : "")) {
                switch f.kind {
                case .text, .path:
                    TextField(f.placeholder, text: value(f.key))
                case .secret, .password:
                    HStack(spacing: 6) {
                        SecureField(saved.contains(f.key) ? "saved — leave blank to keep" : f.placeholder,
                                    text: Binding(get: { secrets[f.key] ?? "" }, set: { secrets[f.key] = $0 }))
                        if saved.contains(f.key) {
                            Button("clear") { cleared.insert(f.key); secrets[f.key] = nil }.controlSize(.small)
                        }
                    }
                case .bool:
                    Toggle("", isOn: Binding(get: { remote.values[f.key] == "true" }, set: { remote.values[f.key] = $0 ? "true" : "false" }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                case .choice(let options):
                    Picker("", selection: value(f.key)) {
                        if !f.required { Text("—").tag("") }
                        ForEach(options, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            if !f.help.isEmpty {
                Text(f.help).font(.mono(8)).foregroundStyle(.tertiary).padding(.leading, 104)
            }
        }
    }
}
