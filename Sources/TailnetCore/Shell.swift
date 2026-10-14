import Foundation
import AppKit
import SwiftUI

// MARK: - Shell

enum Shell {
    static let maxOutput = 8 << 20
    /// `input` goes to stdin — the way to hand a process secrets without putting them in argv (`ps`).
    // ponytail: input is written before output is read — fine for small scripts (< pipe buffer); stream both if that grows
    @discardableResult
    static func run(_ command: String, input: Data? = nil) -> (code: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let stdin = input.map { _ in Pipe() }
        if let stdin { p.standardInput = stdin }
        do { try p.run() } catch { return (-1, "failed to launch: \(error.localizedDescription)") }
        if let stdin, let input {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
        var data = Data()   // keep the first 8 MB, drain the rest — a hostile host can't balloon our memory
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if data.count < maxOutput { data += chunk.prefix(maxOutput - data.count) }
        }
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func run(_ command: String, input: Data? = nil) async -> (code: Int32, output: String) {
        await Task.detached(priority: .userInitiated) { run(command, input: input) }.value
    }
}

// MARK: - Your environment, as install.sh recorded it

/// A Finder-launched app gets launchd's bare environment, not your shell's: no Homebrew PATH, no 1Password/Secretive
/// SSH_AUTH_SOCK, no TAILSCALE_BIN. install.sh writes what your shell has to a file only you can write; at launch it
/// becomes this process's environment, so every tool lookup and every child process (ssh, claude, …) sees it.
/// Nothing about your Mac is built into the app.
public enum UserEnvironment {
    static var file: String { AppInfo.supportDir + "/environment" }
    static let keys: Set = ["PATH", "SSH_AUTH_SOCK", "TAILSCALE_BIN", "CLAUDE_BIN", "CODEX_BIN", "CLINE_BIN", "GHOSTTY_APP"]

    public static func load() { for (k, v) in read(file) { setenv(k, v, 1) } }

    /// KEY=VALUE lines, known keys only, and only from a file you own that nobody else can write (ssh's rule for its
    /// config) — anyone who could edit it could otherwise choose which `ssh` the app runs.
    static func read(_ path: String) -> [(String, String)] {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((a[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o022 == 0,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line -> (String, String)? in
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            return kv.count == 2 && keys.contains(kv[0]) ? (kv[0], kv[1]) : nil
        }
    }
}

// MARK: - Tailscale

enum Tailscale {
    static let bin: String? = [
        ProcessInfo.processInfo.environment["TAILSCALE_BIN"],
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
        "/usr/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }
}

// MARK: - Remote actions (SSH / RDP / Terminal)

enum Remote {
    /// ssh-copy-id with the machine's chosen key (or the default one) — asks for the password once.
    static func installKey(_ m: Machine, pub: String) {
        let port = Int(m.sshPort.trimmingCharacters(in: .whitespaces)).map { "-p \($0) " } ?? ""
        terminal("ssh-copy-id -i \(q(pub)) \(port)\(q(m.sshLogin))@\(q(m.host))")
    }

    /// Non-interactive SSH: key auth only, never prompts for a password.
    /// strict: a background check never trusts a new host key — you accept it in a real session first
    static let batch = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=yes"]

    /// A remote no-op to prove key auth, exit 0 everywhere: POSIX sh runs it, and Windows cmd.exe does too —
    /// `true` is a POSIX builtin that cmd.exe doesn't have, so it returned exit 1 and failed verify on Windows hosts.
    static let okCheck = "exit 0"

    static func sshCommand(_ m: Machine, command: String, verbose: Bool = false) -> String {
        SSHKeys.prepare()  // tighten key perms before any ssh use (no process — < 1 ms)
        return (batch + (verbose ? ["-v"] : []) + m.sshArgs).map(q).joined(separator: " ") + " " + q(command)
    }

    /// Which key got us in (or what was tried) — from `ssh -v` output.
    static func authReport(_ out: String, ok: Bool) -> String {
        let lines = out.split(whereSeparator: \.isNewline).map(String.init)
        func key(after marker: String) -> [String] {
            lines.compactMap { l in
                guard let r = l.range(of: marker) else { return nil }
                let k = l[r.upperBound...].split(separator: " ").first.map(String.init) ?? ""
                return k.hasPrefix("/") ? (k as NSString).lastPathComponent : k
            }
        }
        if ok {
            return key(after: "Server accepts key: ").first.map { "authenticated with \($0)" } ?? "authenticated"
        }
        if out.contains("Host key verification failed") || out.contains("host key is known") {
            return "host key not trusted yet — Connect once and check the fingerprint ssh shows you"
        }
        if out.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            return "HOST KEY CHANGED — possible man-in-the-middle; verify before touching ~/.ssh/known_hosts"
        }
        let errors = lines.filter { !$0.hasPrefix("debug") && !$0.hasPrefix("OpenSSH") && !$0.isEmpty }
        let tried = key(after: "Offering public key: ").reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return (errors.last ?? "connection or key auth failed")
            + (tried.isEmpty ? "" : " · tried: " + tried.joined(separator: ", "))
    }

    static func rdp(ip: String, user: String) {
        let dir = NSHomeDirectory() + "/.tailnet-manager"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = dir + "/" + ip + ".rdp"
        var body = "full address:s:\(ip)\n"
        if !user.isEmpty { body += "username:s:\(user)\n" }
        try? body.write(toFile: file, atomically: true, encoding: .utf8)
        proc("/usr/bin/open", [file])
    }

    static var ghostty: String? {
        [ProcessInfo.processInfo.environment["GHOSTTY_APP"], "/Applications/Ghostty.app", NSHomeDirectory() + "/Applications/Ghostty.app"]
            .compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }
    }

    static func terminal(_ command: String) {
        SSHKeys.prepare()  // tighten key perms before any interactive ssh use
        if let g = ghostty {
            // new Ghostty window running the command — user's own theme/background
            proc("/usr/bin/open", ["-na", g, "--args", "-e", command])
            return
        }
        let esc = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        proc("/usr/bin/osascript", ["-e", "tell application \"Terminal\" to do script \"\(esc)\""])
    }
    private static func proc(_ bin: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        try? p.run()
    }
    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

// MARK: - SSH keys (private keys stay OpenSSH-encrypted at rest)

enum SSHKeys {
    struct KeyInfo: Identifiable, Hashable {
        var name: String
        var hasPrivate: Bool
        var hasPublic: Bool
        var keyType: String = ""
        var id: String { name }
    }

    static var dir: String { NSHomeDirectory() + "/.ssh" }
    static func privPath(_ name: String) -> String { dir + "/" + name }
    static func pubPath(_ name: String) -> String { dir + "/" + name + ".pub" }

    /// mkdir -p + chmod 700, without a shell: spawning zsh here cost ~100 ms on the main thread on every machine
    /// switch and every new tab.
    static func prepare() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        fixPerms(in: dir)
    }

    /// ssh refuses private keys looser than 0600 ("UNPROTECTED PRIVATE KEY FILE!") — tighten them.
    static func fixPerms(in dir: String) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        for f in files where isPrivateKey(dir + "/" + f) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir + "/" + f)
        }
    }

    static func list() -> [KeyInfo] {
        prepare()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var out: [KeyInfo] = []
        for f in files.sorted() where !f.hasPrefix(".") {
            let p = dir + "/" + f
            if f.hasSuffix(".pub") {
                let name = String(f.dropLast(4))
                let pub = (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
                out.append(KeyInfo(name: name,
                                   hasPrivate: FileManager.default.fileExists(atPath: privPath(name)),
                                   hasPublic: true,
                                   keyType: pub.split(separator: " ").first.map(String.init) ?? ""))
            } else if isPrivateKey(p) {
                out.append(KeyInfo(name: f, hasPrivate: true,
                                   hasPublic: FileManager.default.fileExists(atPath: pubPath(f))))
            }
        }
        return out
    }

    static func isPrivateKey(_ path: String) -> Bool {
        guard let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        return String(decoding: h.readData(ofLength: 64), as: UTF8.self).contains("PRIVATE KEY")
    }

    /// true = passphrase-protected (encrypted at rest), false = plaintext, nil = unknown
    static func isEncrypted(_ priv: String) async -> Bool? {
        let (code, out) = await Shell.run("ssh-keygen -y -P '' -f \(Remote.q(priv)) 2>&1")
        if code == 0 { return false }
        return out.lowercased().contains("passphrase") ? true : nil
    }

    /// ssh-keygen with the passphrase on stdin, never in argv (macOS `ps` shows every user's argv, and EDR tools log it).
    /// ssh-keygen asks through SSH_ASKPASS; the helper answers each ask with the next line of ssh-keygen's own stdin.
    static func keygen(_ args: String, passphrase: String) -> (code: Int32, output: String) {
        guard !passphrase.contains(where: \.isNewline) else { return (1, "a passphrase can't contain a line break") }
        let askpass = NSTemporaryDirectory() + "tnm-askpass"   // per-user 0700 dir; the script holds no secret
        FileManager.default.createFile(atPath: askpass, contents: Data("#!/bin/sh\nIFS= read -r p && printf '%s\\n' \"$p\"\n".utf8),
                                       attributes: [.posixPermissions: 0o700])
        let line = Data((passphrase + "\n").utf8)
        return Shell.run("SSH_ASKPASS=\(Remote.q(askpass)) SSH_ASKPASS_REQUIRE=force ssh-keygen \(args)",
                         input: line + line + line)   // new + confirm; a spare is harmless
    }

    static func validName(_ name: String) -> Bool { !name.isEmpty && !name.contains("/") && !name.hasPrefix(".") }

    @discardableResult
    static func generate(name: String, passphrase: String) -> (code: Int32, output: String) {
        guard validName(name) else { return (1, "invalid key name") }
        prepare()
        return keygen("-t ed25519 -C tailnet-manager -f \(Remote.q(privPath(name))) 2>&1", passphrase: passphrase)
    }

    static func importPrivate(name: String, text: String, passphrase: String) -> String? {
        guard validName(name) else { return "invalid key name" }
        guard !FileManager.default.fileExists(atPath: privPath(name)),
              !FileManager.default.fileExists(atPath: pubPath(name)) else { return "~/.ssh/\(name) already exists" }
        guard !passphrase.isEmpty else { return "passphrase required — private keys are stored encrypted at rest, always" }
        // staged inside ~/.ssh (0700), created 0600 — never in a world-traversable temp dir, never readable by others
        prepare()
        let tmp = dir + "/.tnm-import-\(UUID().uuidString)"
        guard FileManager.default.createFile(atPath: tmp, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            return "write failed"
        }
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (plainCode, _) = Shell.run("ssh-keygen -y -P '' -f \(Remote.q(tmp)) 2>/dev/null")
        if plainCode == 0 {
            // plaintext key: encrypt in place (OpenSSH bcrypt KDF + AES-256-CTR) before it gets its real name
            let (c, o) = keygen("-p -P '' -f \(Remote.q(tmp)) 2>&1", passphrase: passphrase)
            if c != 0 { return "encryption failed: \(String(o.prefix(200)))" }
        }
        let (vCode, vOut) = keygen("-y -f \(Remote.q(tmp)) 2>/dev/null", passphrase: passphrase)
        guard vCode == 0, let pub = vOut.split(separator: "\n").last, !pub.isEmpty else {
            let (_, vErr) = keygen("-y -f \(Remote.q(tmp)) 2>&1", passphrase: passphrase)
            return vErr.isEmpty ? "not a valid private key (or wrong passphrase)" : String(vErr.prefix(200))
        }
        do { try FileManager.default.moveItem(atPath: tmp, toPath: privPath(name)) } catch { return "install failed: \(error.localizedDescription)" }
        Shell.run("chmod 600 \(Remote.q(privPath(name)))")
        try? (String(pub) + "\n").write(toFile: pubPath(name), atomically: true, encoding: .utf8)
        Shell.run("chmod 644 \(Remote.q(pubPath(name)))")
        return nil
    }

    static func importPublic(name: String, text: String) -> String? {
        guard validName(name) else { return "invalid key name" }
        guard !FileManager.default.fileExists(atPath: pubPath(name)) else { return "~/.ssh/\(name).pub already exists" }
        guard text.hasPrefix("ssh-") || text.hasPrefix("ecdsa-") || text.hasPrefix("sk-") else {
            return "doesn't look like a public key — expected `ssh-ed25519 AAAA… comment`"
        }
        prepare()
        do { try (text + "\n").write(toFile: pubPath(name), atomically: true, encoding: .utf8) } catch { return "write failed: \(error.localizedDescription)" }
        Shell.run("chmod 644 \(Remote.q(pubPath(name)))")
        return nil
    }

    /// Re-encrypt a currently-plaintext key in place.
    @discardableResult
    static func encryptExisting(name: String, passphrase: String) -> (code: Int32, output: String) {
        keygen("-p -P '' -f \(Remote.q(privPath(name))) 2>&1", passphrase: passphrase)
    }

    static func defaultPub() -> String? {
        let ks = list()
        if let e = ks.first(where: { $0.name == "id_ed25519" && $0.hasPublic }) { return pubPath(e.name) }
        return ks.first(where: { $0.hasPublic }).map { pubPath($0.name) }
    }

    static func addToAgent(name: String) {
        Remote.terminal("ssh-add --apple-use-keychain \(Remote.q(privPath(name)))")
    }

    @discardableResult
    static func delete(name: String) -> Bool {
        var ok = true
        for p in [privPath(name), pubPath(name)] where FileManager.default.fileExists(atPath: p) {
            do { try FileManager.default.removeItem(atPath: p) } catch { ok = false }
        }
        return ok
    }
}


// MARK: - Themes — the colors below are read at render time; ContentView rebuilds its tree (`.id`) when you pick one

public enum Theme: String, CaseIterable, Identifiable {
    case graphite, black, light, navy, coffee
    public var id: String { rawValue }
    var name: String { rawValue.capitalized }
    static var current: Theme { Theme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .graphite }
    var scheme: ColorScheme { self == .light ? .light : .dark }

    var palette: (bg: UInt32, panel: UInt32, accent: UInt32, dim: UInt32, ledOff: UInt32, ok: UInt32, bad: UInt32) {
        switch self {
        case .graphite: (0x0B0C0E, 0x101215, 0xFF9F0A, 0x8E9199, 0x3A3D44, 0x30D158, 0xFF453A)
        case .black:    (0x000000, 0x0A0A0A, 0xFF9F0A, 0x8A8A8A, 0x333333, 0x30D158, 0xFF453A)
        case .light:    (0xF2F1ED, 0xFFFFFF, 0xD9600B, 0x6A6D74, 0xC8CACF, 0x1E9E46, 0xD92D20)
        case .navy:     (0x0A1426, 0x0F1C33, 0x3D8BFF, 0x8696B0, 0x2A3A56, 0x30D158, 0xFF5A4F)
        case .coffee:   (0x17110D, 0x201812, 0xC4813F, 0xA39383, 0x4A3B2F, 0x7BC47F, 0xE5604F)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255,
                       green: Double((hex >> 8) & 0xFF) / 255,
                       blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
    static var bg: Color { Color(hex: Theme.current.palette.bg) }
    static var panelDeep: Color { Color(hex: Theme.current.palette.panel) }
    static var accent: Color { Color(hex: Theme.current.palette.accent) }
    static var ok: Color { Color(hex: Theme.current.palette.ok) }
    static var bad: Color { Color(hex: Theme.current.palette.bad) }
    static var dim: Color { Color(hex: Theme.current.palette.dim) }
    static var ledOff: Color { Color(hex: Theme.current.palette.ledOff) }
    /// Hairlines and washes: white on the dark themes, black on Light.
    static var ink: Color { Theme.current.scheme == .light ? .black : .white }
}

extension Font {
    static func mono(_ size: CGFloat = 12) -> Font { .system(size: size, design: .monospaced) }
}

extension ShapeStyle where Self == Color {
    static var dim: Color { Color.dim }
    static var accent: Color { Color.accent }
    static var ok: Color { Color.ok }
    static var bad: Color { Color.bad }
}
