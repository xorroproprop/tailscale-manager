import SwiftUI
import AppKit

// MARK: - Orchestrate: an agent CLI on this Mac drives your machines over ssh — pick the supplier per run
// The agent runs here, on your login (Claude subscription, ChatGPT via `codex login`) or your z.ai key — nothing to
// install or log into on the servers. Every supplier gets the same lock: ssh to the machines you picked, nothing else.
// Claude: Bash is the only tool, allowed only for each machine's exact ssh line (dontAsk denies the rest).
// Codex: no shell at all — its one tool is SSHBridge (below), which can only run those same ssh lines.
// z.ai via Cline (ACP mode): Cline asks this app before every tool call; only those same ssh lines are approved.
// Your user settings, hooks, rules and MCP servers stay out of all of them.

enum Provider: String, CaseIterable, Identifiable {
    case claude, codex, zai
    var id: String { rawValue }
    var name: String { switch self { case .claude: "Claude"; case .codex: "Codex"; case .zai: "z.ai" } }
    var auth: String { switch self { case .claude: "Claude subscription login"; case .codex: "ChatGPT login"; case .zai: "Cline sign-in (z.ai)" } }
    var bin: String? { switch self { case .claude: ClaudeCLI.bin; case .codex: CodexCLI.bin; case .zai: ClineCLI.bin } }
    var missing: String {
        switch self {
        case .claude: "claude CLI not found — install Claude Code (brew install --cask claude-code), then re-run install.sh"
        case .codex: "codex CLI not found — brew install codex, `codex login`, then re-run install.sh"
        case .zai: "cline CLI not found — npm i -g cline, `cline auth` → Z.ai Coding Plan, then re-run install.sh"
        }
    }

    var models: [String] {
        switch self {
        case .claude: ["default", "fable", "opus", "sonnet", "haiku"]
        case .codex: CodexCLI.models.map(\.slug)
        // what Cline 3.0.69 offers for zai-coding-plan (2026-10-07) — "default" is the model you set in `cline auth`
        case .zai: ["default", "glm-5.3", "glm-5.3-flash", "glm-5.3-highspeed", "glm-5.2", "glm-5.2-highspeed", "glm-5-turbo", "glm-4.7"]
        }
    }

    func efforts(_ model: String) -> [String] {
        switch self {
        case .claude: ["default", "low", "medium", "high", "xhigh", "max"]
        case .codex: ["default"] + (CodexCLI.models.first { $0.slug == model }?.efforts ?? ["low", "medium", "high"])
        case .zai: ["default"]   // Cline only sends GLM thinking on/off, from your `cline auth` settings
        }
    }

    /// The larger context window this model can switch to, if it has one.
    func bigContext(_ model: String) -> Int? {
        switch self {
        case .claude: ["opus", "sonnet"].contains(model) ? 1_000_000 : nil
        case .codex: CodexCLI.models.first { $0.slug == model }.flatMap { $0.maxContext > $0.context ? $0.maxContext : nil }
        case .zai: nil
        }
    }
}

/// Which supplier, model, reasoning effort and context window a run uses. "default" = the CLI's own choice.
struct AgentConfig: Hashable {
    var provider = Provider.claude
    var model = "default"
    var effort = "default"
    var bigContext = false

    var label: String {
        ([provider.name, model == "default" ? nil : model, effort == "default" ? nil : effort, bigContext ? "1M" : nil] as [String?])
            .compactMap { $0 }.joined(separator: " · ")
    }
    var claudeModel: String? { model == "default" ? nil : model + (bigContext ? "[1m]" : "") }
}

enum ClaudeCLI {
    static let bin: String? = [
        ProcessInfo.processInfo.environment["CLAUDE_BIN"],
        "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        NSHomeDirectory() + "/.local/bin/claude", NSHomeDirectory() + "/.claude/local/claude",
    ].compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Working dir for runs — sessions resume from here.
    static let dir = NSHomeDirectory() + "/.tailnet-manager/claude"

    /// A shell word as Claude must type it: bare when safe, single-quoted otherwise.
    static func word(_ s: String) -> String { s.wholeMatch(of: #/[A-Za-z0-9@%+=:,.\/_-]+/#) != nil ? s : Remote.q(s) }

    /// Everything before the remote command. The trailing `--` ends ssh's option parsing, so whatever Claude
    /// appends is the remote command — never a local `-o ProxyCommand=…`.
    static func prefix(_ m: Machine) -> String { (Remote.batch + m.sshArgs + ["--"]).map(word).joined(separator: " ") }

    static func rule(_ m: Machine) -> String { "Bash(\(prefix(m)) *)" }

    static func args(_ targets: [Machine], resume: String?, config: AgentConfig = AgentConfig()) -> [String] {
        ["-p", "--output-format", "stream-json", "--verbose",
         "--tools", "Bash", "--permission-mode", "dontAsk",
         "--setting-sources", "project",   // the run dir has none: your user allow-rules, hooks and plugins can't widen this
         "--strict-mcp-config",            // and no MCP servers
         "--append-system-prompt", roster(targets)]
            + (resume.map { ["--resume", $0] } ?? [])
            + (config.claudeModel.map { ["--model", $0] } ?? [])
            + (config.provider == .claude && config.effort != "default" ? ["--effort", config.effort] : [])
            + ["--allowedTools"] + targets.map(rule)   // last: it takes every argument after it
    }

    /// Your login, not the API: an API key in the environment would silently switch billing to it.
    static var env: [String: String] {
        var e = ProcessInfo.processInfo.environment
        for k in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDECODE"] { e[k] = nil }
        return e
    }

    static func roster(_ targets: [Machine]) -> String {
        """
        You are running headless on the user's Mac, started from Tailnet Manager's Orchestrate page. You reach the \
        user's machines only over ssh: the one command you can run is one of these exact prefixes followed by a single \
        quoted remote command, e.g. `<prefix> 'uptime'`. Anything else is denied.

        \(targets.map { "- \(name($0)) (\($0.os.isEmpty ? "OS unknown" : $0.os)): \(prefix($0)) '<command>'" }.joined(separator: "\n"))

        - One ssh call per tool call; pipes, redirects and && go inside the quotes, never after them.
        \(rules)
        """
    }

    static let rules = """
        - Windows hosts usually land in cmd.exe or PowerShell — use `powershell -NoProfile -Command "…"` for PowerShell.
        - Nothing interactive (it hangs): no vim/less/top; use `top -bn1`, `journalctl --no-pager -n 200`, `sudo -n`.
        - Look before you change. Don't delete data, reboot, or stop services unless the task says to.
        - End with a short per-machine summary: what you ran, what you found or changed.
        """

    static func name(_ m: Machine) -> String { m.name.isEmpty ? m.host : m.name }
}

enum CodexCLI {
    static let bin: String? = [
        ProcessInfo.processInfo.environment["CODEX_BIN"],
        "/opt/homebrew/bin/codex", "/usr/local/bin/codex", NSHomeDirectory() + "/.local/bin/codex",
    ].compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }

    struct Model { let slug: String; let efforts: [String]; let context: Int; let maxContext: Int }

    /// What your ChatGPT plan offers, from the list codex keeps fresh in ~/.codex/models_cache.json.
    // ponytail: read once per app launch — a model codex learns about later shows up after a restart
    static let models: [Model] = {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.codex/models_cache.json")
        let list = ((try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["models"] as? [[String: Any]] ?? []
        let ms = list.filter { $0["visibility"] as? String == "list" }.compactMap { m -> Model? in
            guard let slug = m["slug"] as? String else { return nil }
            let ctx = m["context_window"] as? Int ?? 0
            return Model(slug: slug, efforts: (m["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { $0["effort"] as? String },
                         context: ctx, maxContext: m["max_context_window"] as? Int ?? ctx)
        }
        return ms.isEmpty ? [Model(slug: "gpt-5.5", efforts: ["low", "medium", "high", "xhigh"], context: 0, maxContext: 0)] : ms
    }()

    /// `codex exec --json`, prompt on stdin. Locked: no shell tools, read-only sandbox, never asks — its only way out
    /// is the `tailnet` MCP server (this app as SSHBridge), which runs nothing but the picked machines' ssh lines.
    static func args(_ targets: [Machine], resume: String?, config: AgentConfig, exe: String) -> [String] {
        func c(_ k: String, _ v: String) -> [String] { ["-c", "\(k)=\(v)"] }
        func str(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var a = ["exec"] + (resume.map { ["resume", $0] } ?? [])
        a += ["--json", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules"]
        for f in ["shell_tool", "unified_exec", "apps", "browser_use", "computer_use", "image_generation", "plugins", "multi_agent", "hooks", "goals"] {
            a += ["--disable", f]
        }
        a += c("sandbox_mode", str("read-only")) + c("approval_policy", str("never")) + c("web_search", str("disabled"))
        a += c("mcp_servers.tailnet.command", str(exe))
        a += c("mcp_servers.tailnet.args", "[\(str("--ssh-mcp")), \(str(SSHBridge.encode(targets)))]")
        a += c("mcp_servers.tailnet.tool_timeout_sec", "600")
        if let sock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] { a += c("mcp_servers.tailnet.env", "{ SSH_AUTH_SOCK = \(str(sock)) }") }
        if config.model != "default" { a += ["-m", config.model] }
        if config.effort != "default" { a += c("model_reasoning_effort", str(config.effort)) }
        if config.bigContext, let n = config.provider.bigContext(config.model) { a += c("model_context_window", String(n)) }
        return a + ["-"]
    }

    /// Your ChatGPT login, not an API key — a key in the environment would switch billing to it.
    static var env: [String: String] {
        var e = ProcessInfo.processInfo.environment
        for k in ["OPENAI_API_KEY", "CODEX_API_KEY"] { e[k] = nil }
        return e
    }

    static func roster(_ targets: [Machine]) -> String {
        """
        You are running headless on the user's Mac, started from Tailnet Manager's Orchestrate page. You have no local \
        shell. You reach the user's machines only through the `ssh` tool of the `tailnet` MCP server: give it `machine` \
        (one of the names below) and `command` (one non-interactive command line, run by that machine's login shell).

        \(zip(targets, SSHBridge.targets(targets)).map { "- \($1.name) (\($0.os.isEmpty ? "OS unknown" : $0.os))" }.joined(separator: "\n"))

        \(ClaudeCLI.rules)
        """
    }
}

/// `codex exec --json` → the same items the run card shows for Claude.
enum CodexStream {
    static func parse(_ line: String) -> [ClaudeStream.Item] {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // its stderr log ("2026-…Z ERROR codex_login…") repeats what the JSON `error` event says — keep the rest
            return t.isEmpty || t.prefixMatch(of: #/\d{4}-\d\d-\d\dT\S+Z\s+(ERROR|WARN|INFO|DEBUG|TRACE)\s/#) != nil ? [] : [.step(.error, t)]
        }
        let item = o["item"] as? [String: Any] ?? [:]
        switch (o["type"] as? String, item["type"] as? String) {
        case ("thread.started", _):
            return [.started(auth: Provider.codex.auth, session: o["thread_id"] as? String ?? "")]
        case ("item.started", "mcp_tool_call"):
            let a = item["arguments"] as? [String: Any] ?? [:]
            return [.step(.command, a["machine"].map { "\($0) › \(a["command"] ?? "")" } ?? "\(item["tool"] ?? "?") \(a)")]
        case ("item.completed", "mcp_tool_call"):
            let text = ((item["result"] as? [String: Any])?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
                ?? (item["error"] as? [String: Any])?["message"] as? String ?? ""
            let failed = item["status"] as? String == "failed" || item["error"] is [String: Any]
            return text.isEmpty ? [] : [.step(failed ? .error : .output, String(text.prefix(4000)))]
        case ("item.completed", "agent_message"):
            return (item["text"] as? String).flatMap { $0.isEmpty ? nil : [.step(.text, $0)] } ?? []
        case ("item.completed", "command_execution"):   // shell tools are disabled — if one ever runs, show it loudly
            return [.step(.error, "local command (should be impossible): \(item["command"] ?? "")")]
        case ("item.completed", "error"):
            return [.step(.error, item["message"] as? String ?? "error")]
        case ("turn.completed", _):
            return [.result("", isError: false, session: "")]   // codex has no result text: the last message is it
        case ("turn.failed", _):
            return [.result((o["error"] as? [String: Any])?["message"] as? String ?? "turn failed", isError: true, session: "")]
        case ("error", _):
            return [.step(.error, o["message"] as? String ?? "error")]
        default:
            return []
        }
    }
}

enum ClineCLI {
    static let bin: String? = [
        ProcessInfo.processInfo.environment["CLINE_BIN"],
        "/opt/homebrew/bin/cline", "/usr/local/bin/cline", NSHomeDirectory() + "/.local/bin/cline",
    ].compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }

    static let settings = NSHomeDirectory() + "/.cline/data/settings/providers.json"

    /// The z.ai key from your Cline sign-in (`cline auth`). ACP mode only restores OAuth logins by itself, so an API-key
    /// provider's key is handed over in the environment — never argv, where `ps` would show it.
    static func login(_ path: String = settings) -> (provider: String, key: String)? {
        let ps = ((try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["providers"] as? [String: Any]
        for id in ["zai-coding-plan", "zai"] {
            if let k = ((ps?[id] as? [String: Any])?["settings"] as? [String: Any])?["apiKey"] as? String, !k.isEmpty { return (id, k) }
        }
        return nil
    }

    static func env(provider: String, key: String, model: String) -> [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["CLINE_PROVIDER"] = provider
        e["CLINE_API_KEY"] = key
        e["CLINE_MODEL"] = model == "default" ? nil : model
        e["CLINE_NO_AUTO_UPDATE"] = "1"            // its updater reinstalls the global package mid-run; two at once broke it
        e["CLINE_SESSION_BACKEND_MODE"] = "local"  // never route through (or retire) the Cline hub your own sessions use
        return e
    }

    /// Approve only a picked machine's exact ssh line — the same shape Claude's hook enforces.
    static func allowed(_ cmd: String, _ targets: [Machine]) -> Bool { BashHook.allowed(cmd, prefixes: targets.map(ClaudeCLI.prefix)) }

    static func roster(_ targets: [Machine]) -> String {
        ClaudeCLI.roster(targets) + """

        - Use your command tool with exactly one command per call: the prefix, a space, then the remote command in \
        single quotes (write a literal ' as '\\''). Anything else — and every other tool — is rejected.
        """
    }
}

/// Claude's second lock. `--permission-mode dontAsk` still auto-approves Claude Code's built-in read-only commands
/// (cat, ls, grep, find…) on this Mac, so the run dir's project settings put a PreToolUse hook — this binary with
/// `--bash-hook` — in front of every tool call: anything but one picked machine's exact ssh line is denied (exit 2).
public enum BashHook {
    static let envKey = "TNM_SSH_PREFIXES"   // the picked machines' prefixes as JSON — set per run, read by the hook

    /// `<prefix> '<one single-quoted word>'` — the word may only be quoted runs and \' escapes, so no shell
    /// metacharacter, expansion or second command can sit outside the quotes.
    static func allowed(_ cmd: String, prefixes: [String]) -> Bool {
        prefixes.contains { p in
            cmd.hasPrefix(p + " ") && cmd.dropFirst(p.count + 1).wholeMatch(of: #/(?:'[^']*'|\\')+/#) != nil
        }
    }

    /// One PreToolUse event → nil (let it through; the allow rule still has to match) or why it's denied.
    static func verdict(_ event: Data, prefixes: [String]) -> String? {
        guard let o = (try? JSONSerialization.jsonObject(with: event)) as? [String: Any],
              o["tool_name"] as? String == "Bash", let cmd = (o["tool_input"] as? [String: Any])?["command"] as? String else {
            return "denied by Tailnet Manager: the only tool is Bash, for the listed ssh lines"
        }
        return allowed(cmd, prefixes: prefixes) ? nil
            : "denied by Tailnet Manager: run one listed ssh prefix, a space, then ONE single-quoted remote command ('\\'' for a quote)"
    }

    static func settings(exe: String) -> Data {
        let hook: [String: Any] = ["matcher": "*", "hooks": [["type": "command", "command": Remote.q(exe) + " --bash-hook"]]]
        return (try? JSONSerialization.data(withJSONObject: ["hooks": ["PreToolUse": [hook]]], options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// <run dir>/.claude/settings.json — false means the guard isn't in place and the run must not start.
    static func install(exe: String, dir: String = ClaudeCLI.dir) -> Bool {
        try? FileManager.default.createDirectory(atPath: dir + "/.claude", withIntermediateDirectories: true)
        return FileManager.default.createFile(atPath: dir + "/.claude/settings.json", contents: settings(exe: exe))
    }

    static func env(_ targets: [Machine]) -> String {
        String(decoding: (try? JSONEncoder().encode(targets.map(ClaudeCLI.prefix))) ?? Data("[]".utf8), as: UTF8.self)
    }

    /// `TailnetManager --bash-hook`: Claude Code pipes one PreToolUse event in. No prefixes in the env = deny all.
    public static func run() -> Never {
        let raw = ProcessInfo.processInfo.environment[envKey] ?? "[]"
        let prefixes = (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
        guard let why = verdict(FileHandle.standardInput.readDataToEndOfFile(), prefixes: prefixes) else { exit(0) }
        FileHandle.standardError.write(Data((why + "\n").utf8))
        exit(2)
    }
}

/// Cline in ACP mode (`cline --acp`): JSON-RPC both ways over stdio. Cline asks this app before every tool call; only
/// `run_commands` whose every command is an allowed ssh line gets "allow_once" — files, other commands, MCP and skills
/// are rejected. Thoughts aren't shown (same as Claude); message chunks are joined into one step per reply.
final class ClineACP {
    let targets: [Machine], cwd: String, prompt: String, resume: String?
    let send: ([String: Any]) -> Void
    private var session = "", text = "", ready = false
    private var blocked: Set<String> = [], shown: Set<String> = []

    init(targets: [Machine], cwd: String, prompt: String, resume: String?, send: @escaping ([String: Any]) -> Void) {
        self.targets = targets; self.cwd = cwd; self.prompt = prompt; self.resume = resume; self.send = send
    }

    func begin() {
        call(1, "initialize", ["protocolVersion": 1, "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false]])
    }

    private func call(_ id: Int, _ method: String, _ params: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func flush() -> [ClaudeStream.Item] {
        defer { text = "" }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? [] : [.step(.text, t)]
    }

    func receive(_ line: String) -> [ClaudeStream.Item] {
        guard let m = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)   // stderr: only startup trouble is worth showing
            return ready || t.isEmpty || t.hasPrefix("[acp]") ? [] : [.step(.error, t)]
        }
        let params = m["params"] as? [String: Any] ?? [:]
        if let err = m["error"] as? [String: Any] {
            let msg = err["message"] as? String ?? "cline error"
            return flush() + [.result(msg, isError: true, session: session)]
        }
        switch (m["id"] as? Int, m["method"] as? String) {
        case (1, nil):
            let p: [String: Any] = ["cwd": cwd, "mcpServers": [Any]()]
            if let r = resume { call(2, "session/load", p.merging(["sessionId": r]) { $1 }) } else { call(2, "session/new", p) }
            return []
        case (2, nil):
            session = (m["result"] as? [String: Any])?["sessionId"] as? String ?? resume ?? ""
            ready = true   // session/load replays history first — ignored until now
            let task = resume == nil ? ClineCLI.roster(targets) + "\n\n# Task\n\n" + prompt : prompt
            call(3, "session/prompt", ["sessionId": session, "prompt": [["type": "text", "text": task]]])
            return [.started(auth: Provider.zai.auth, session: session)]
        case (3, nil):
            return flush() + [.result("", isError: false, session: session)]
        case (_, "session/request_permission"):
            let tc = params["toolCall"] as? [String: Any] ?? [:]
            let input = tc["rawInput"] as? [String: Any] ?? [:]
            let cmds = input["commands"] as? [String] ?? []
            let ok = (tc["title"] as? String)?.hasPrefix("run_commands") == true && Set(input.keys) == ["commands"]
                && !cmds.isEmpty && cmds.allSatisfy { ClineCLI.allowed($0, targets) }
            send(["jsonrpc": "2.0", "id": m["id"] ?? NSNull(),
                  "result": ["outcome": ["outcome": "selected", "optionId": ok ? "allow_once" : "reject_once"]]])
            if !ok { blocked.insert(tc["toolCallId"] as? String ?? "") }
            return flush() + (ok ? cmds.map { .step(.command, $0) } : [.step(.error, "blocked: \(tc["title"] ?? "tool call")")])
        case (let id?, _?):   // fs/*, terminal/* — we offered neither
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "not supported"]])
            return []
        case (nil, "session/update"):
            guard ready, let u = params["update"] as? [String: Any] else { return [] }
            switch u["sessionUpdate"] as? String {
            case "agent_message_chunk":
                text += (u["content"] as? [String: Any])?["text"] as? String ?? ""
                return []
            case "tool_call_update":
                guard let id = u["toolCallId"] as? String, !blocked.contains(id), !shown.contains(id),
                      ["completed", "failed"].contains(u["status"] as? String), let raw = u["rawOutput"] else { return [] }
                shown.insert(id)
                let rows = raw as? [[String: Any]] ?? []
                let out = rows.isEmpty ? "\(raw)" : rows.map { $0["result"] as? String ?? "\($0["error"] ?? "")" }.joined(separator: "\n")
                let failed = u["status"] as? String == "failed" || rows.contains { $0["success"] as? Bool == false }
                return flush() + (out.isEmpty ? [] : [.step(failed ? .error : .output, String(out.prefix(4000)))])
            default:
                return []
            }
        default:
            return []
        }
    }
}

// MARK: - SSHBridge: Codex's only tool. Codex has no per-command allow-list, so instead of a shell it gets this MCP
// server — this same binary, run as `TailnetManager --ssh-mcp <targets>` — which can run the picked machines' ssh
// line (BatchMode, key auth) with one command appended, and nothing else.

public enum SSHBridge {
    struct Target: Codable, Equatable { let name: String; let argv: [String] }

    /// Names as the agent sees them; a name two machines share gets its host appended.
    static func targets(_ ms: [Machine]) -> [Target] {
        let names = ms.map(ClaudeCLI.name)
        return zip(ms, names).map { m, n in
            Target(name: names.filter { $0 == n }.count > 1 ? "\(n)@\(m.host)" : n, argv: Remote.batch + m.sshArgs + ["--"])
        }
    }

    static func encode(_ ms: [Machine]) -> String { (try? JSONEncoder().encode(targets(ms)))?.base64EncodedString() ?? "" }

    /// MCP over stdio: one JSON-RPC message per line. Serves until codex closes stdin.
    // ponytail: one call at a time — parallel calls from codex queue behind each other
    public static func serve(_ arg: String) -> Never {
        let targets = Data(base64Encoded: arg).flatMap { try? JSONDecoder().decode([Target].self, from: $0) } ?? []
        SSHKeys.prepare()
        while let line = readLine() {
            guard let req = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let reply = handle(req, targets: targets, run: run),
                  let data = try? JSONSerialization.data(withJSONObject: reply) else { continue }
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
        exit(0)
    }

    static func handle(_ req: [String: Any], targets: [Target], run: (Target, String) -> (out: String, ok: Bool)) -> [String: Any]? {
        guard let id = req["id"] else { return nil }   // notifications get no reply
        let params = req["params"] as? [String: Any] ?? [:]
        func reply(_ r: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": r] }
        func text(_ t: String, error: Bool) -> [String: Any] { reply(["content": [["type": "text", "text": t]], "isError": error]) }
        switch req["method"] as? String {
        case "initialize":
            return reply(["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                          "capabilities": ["tools": [String: Any]()], "serverInfo": ["name": "tailnet-ssh", "version": "1"]])
        case "ping":
            return reply([:])
        case "tools/list":
            return reply(["tools": [[
                "name": "ssh",
                "description": "Run one non-interactive command on one of the user's machines over ssh. Returns stdout+stderr.",
                "inputSchema": ["type": "object", "required": ["machine", "command"], "properties": [
                    "machine": ["type": "string", "enum": targets.map(\.name)],
                    "command": ["type": "string", "description": "one command line, run by the machine's login shell"],
                ]],
            ]]])
        case "tools/call":
            let a = params["arguments"] as? [String: Any] ?? [:]
            guard params["name"] as? String == "ssh", let t = targets.first(where: { $0.name == a["machine"] as? String }) else {
                return text("unknown tool or machine — machines: " + targets.map(\.name).joined(separator: ", "), error: true)
            }
            guard let cmd = a["command"] as? String, !cmd.isEmpty else { return text("command is required", error: true) }
            let r = run(t, cmd)
            return text(r.out, error: !r.ok)
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found"]]
        }
    }

    static func run(_ t: Target, _ cmd: String) -> (out: String, ok: Bool) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = t.argv + [cmd]   // argv ends in "--": the command can only ever be the remote command
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return ("couldn't start ssh: \(error.localizedDescription)", false) }
        let kill = DispatchWorkItem { p.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: kill)   // ponytail: fixed 5-minute cap per command
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile().prefix(30_000), as: UTF8.self)
        p.waitUntilExit()
        kill.cancel()
        let code = p.terminationStatus
        return ((out.isEmpty ? "(no output)" : out) + (code == 0 ? "" : "\n(exit \(code))"), code == 0)
    }
}

struct RunStep: Identifiable, Hashable {
    enum Kind: Hashable { case text, command, output, error }
    var id = UUID()
    let kind: Kind
    let text: String
}

enum ClaudeStream {
    enum Item: Equatable {
        case started(auth: String, session: String)
        case step(RunStep.Kind, String)
        case result(String, isError: Bool, session: String)
    }

    /// One line of `claude -p --output-format stream-json` → what the run card shows. Unknown lines are skipped.
    static func parse(_ line: String) -> [Item] {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? [] : [.step(.error, t)]   // stderr is merged in: warnings, auth errors
        }
        let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        switch o["type"] as? String {
        case "system" where o["subtype"] as? String == "init":
            let src = o["apiKeySource"] as? String ?? "none"
            let api = src.localizedCaseInsensitiveContains("key") || src.hasPrefix("ANTHROPIC")
            return [.started(auth: api ? "API key (\(src))" : "subscription login", session: o["session_id"] as? String ?? "")]
        case "assistant":
            return content.compactMap { c in
                switch c["type"] as? String {
                case "text": return (c["text"] as? String).flatMap { $0.isEmpty ? nil : .step(.text, $0) }
                case "tool_use":
                    return .step(.command, ((c["input"] as? [String: Any])?["command"] as? String) ?? (c["name"] as? String ?? "?"))
                default: return nil
                }
            }
        case "user":
            return content.compactMap { c in
                guard c["type"] as? String == "tool_result" else { return nil }
                let text = (c["content"] as? String)
                    ?? (c["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
                let failed = c["is_error"] as? Bool == true
                return text.isEmpty && !failed ? nil : .step(failed ? .error : .output, String(text.prefix(4000)))
            }
        case "result":
            return [.result(o["result"] as? String ?? "", isError: o["is_error"] as? Bool ?? true,
                            session: o["session_id"] as? String ?? "")]
        default:
            return []
        }
    }
}

@MainActor
final class ClaudeRun: ObservableObject, Identifiable {
    enum State: String { case running, done, failed, stopped }

    let id = UUID()
    let prompt: String
    let targets: [Machine]
    let resume: String?
    let config: AgentConfig
    let started = Date()
    @Published private(set) var steps: [RunStep] = []
    @Published private(set) var state = State.running
    @Published private(set) var result = ""
    @Published private(set) var session = ""
    @Published private(set) var auth = ""
    @Published private(set) var ended: Date?
    @Published var collapsed = false
    weak var store: Store?
    private var process: Process?
    private var resultError = false
    private var gotResult = false
    private var acp: ClineACP?

    init(prompt: String, targets: [Machine], resume: String?, config: AgentConfig) {
        self.prompt = prompt
        self.targets = targets
        self.resume = resume
        self.config = config
    }

    func start() {
        guard let bin = config.provider.bin else { return finish(1, note: config.provider.missing) }
        SSHKeys.prepare()
        try? FileManager.default.createDirectory(atPath: ClaudeCLI.dir, withIntermediateDirectories: true)
        let p = Process(), out = Pipe(), inp = Pipe()
        var prompt = prompt
        switch config.provider {
        case .claude:
            guard let exe = Bundle.main.executablePath, BashHook.install(exe: exe) else {
                return finish(1, note: "couldn't install the ssh-only command guard — not starting")
            }
            p.arguments = ClaudeCLI.args(targets, resume: resume, config: config)
            p.environment = ClaudeCLI.env.merging([BashHook.envKey: BashHook.env(targets)]) { $1 }
        case .zai:
            guard let login = ClineCLI.login() else { return finish(1, note: "no z.ai sign-in in Cline — run `cline auth` and pick Z.ai Coding Plan") }
            p.arguments = ["--acp"]
            p.environment = ClineCLI.env(provider: login.provider, key: login.key, model: config.model)
        case .codex:
            guard let exe = Bundle.main.executablePath else { return finish(1, note: "can't find this app's binary for the ssh tool") }
            p.arguments = CodexCLI.args(targets, resume: resume, config: config, exe: exe)
            p.environment = CodexCLI.env
            if resume == nil { prompt = CodexCLI.roster(targets) + "\n\n# Task\n\n" + prompt }   // codex has no append-system-prompt
        }
        p.executableURL = URL(fileURLWithPath: bin)
        p.currentDirectoryURL = URL(fileURLWithPath: ClaudeCLI.dir)
        p.standardOutput = out
        p.standardError = out
        p.standardInput = inp
        do { try p.run() } catch { return finish(1, note: "couldn't start \(config.provider.name): \(error.localizedDescription)") }
        process = p
        let input = inp.fileHandleForWriting
        if config.provider == .zai {   // a conversation, not a one-shot: stdin stays open until the prompt's reply
            acp = ClineACP(targets: targets, cwd: ClaudeCLI.dir, prompt: prompt, resume: resume) { msg in
                if let d = try? JSONSerialization.data(withJSONObject: msg) { try? input.write(contentsOf: d + Data("\n".utf8)) }
            }
            acp?.begin()
        } else {
            let data = Data(prompt.utf8)
            Task.detached { try? input.write(contentsOf: data); try? input.close() }   // stdin: no argv limits, not in `ps`
        }
        Task {
            let parse = config.provider == .codex ? CodexStream.parse : ClaudeStream.parse
            do {
                for try await line in out.fileHandleForReading.bytes.lines {
                    apply(acp?.receive(line) ?? parse(line))
                    if acp != nil, gotResult {   // ACP never exits by itself: hang up, then make sure
                        try? input.close()
                        Task { try? await Task.sleep(for: .seconds(3)); if p.isRunning { p.terminate() } }
                    }
                }
            } catch {}
            await Task.detached { p.waitUntilExit() }.value
            finish(p.terminationStatus)
        }
    }

    func stop() {
        guard state == .running else { return }
        state = .stopped
        process?.terminate()
    }

    private func apply(_ items: [ClaudeStream.Item]) {
        for i in items {
            switch i {
            case .started(let a, let s): auth = a; session = s
            case .step(let k, let t): steps.append(RunStep(kind: k, text: t))
            case .result(let t, let err, let s):
                result = t.isEmpty && !err ? steps.last { $0.kind == .text }?.text ?? "" : t
                resultError = err
                gotResult = true
                if !s.isEmpty { session = s }
            }
        }
    }

    private func finish(_ code: Int32, note: String? = nil) {
        if let note { steps.append(RunStep(kind: .error, text: note)) }
        if state == .running { state = (code == 0 || gotResult) && !resultError ? .done : .failed }
        ended = Date()
        process = nil
        store?.log(.claude, machine: targets.count == 1 ? targets[0] : nil,
                   detail: "\(state.rawValue) · \(config.label) · \(targets.map(ClaudeCLI.name).joined(separator: ", ")) · \(prompt.prefix(80))",
                   durationMs: Int(ended!.timeIntervalSince(started) * 1000))
    }
}

@MainActor
final class Orchestrator: ObservableObject {
    @Published private(set) var runs: [ClaudeRun] = []   // newest first, this app session only (the log keeps a line each)
    @Published var draft = ""
    @Published var picked: Set<String> = []
    weak var store: Store?

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.runs.forEach { $0.stop() } }   // nothing outlives the app
        }
    }

    /// SSH machines whose key auth you verified — BatchMode can't answer a password prompt.
    var eligible: [Machine] { store?.machines.filter { $0.usesSSH && $0.authVerifiedAt != nil } ?? [] }

    func run(_ prompt: String, on ids: Set<String>, config: AgentConfig, resume: String? = nil) {
        let targets = eligible.filter { ids.contains($0.id) }   // current settings, not a stale snapshot
        guard !targets.isEmpty else { return }
        let r = ClaudeRun(prompt: prompt, targets: targets, resume: resume, config: config)
        r.store = store
        for old in runs where old.state != .running { old.collapsed = true }   // finished ones fold up: less scrolling
        runs.insert(r, at: 0)
        r.start()
    }
}

// MARK: - Page

struct OrchestrateView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var claude: Orchestrator
    @AppStorage("agent.provider") private var provider = Provider.claude
    @AppStorage("agent.model") private var model = "default"
    @AppStorage("agent.effort") private var effort = "default"
    @AppStorage("agent.bigContext") private var bigContext = false

    /// What the pickers say, held to what the current supplier/model actually offers.
    var config: AgentConfig {
        let m = provider.models.contains(model) ? model : provider.models.first ?? "default"
        return AgentConfig(provider: provider, model: m, effort: provider.efforts(m).contains(effort) ? effort : "default",
                           bigContext: bigContext && provider.bigContext(m) != nil)
    }

    var picked: Set<String> { claude.picked.intersection(claude.eligible.map(\.id)) }
    var task: String { claude.draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Claude on your machines").font(.system(size: 22, weight: .bold))
                    Text(provider.bin.map { "runs \(provider.name) on this Mac (\($0)) with your \(provider.auth) — the servers need no AI install or login. Whichever supplier you pick can only ssh to the machines you pick, and every command it runs shows below." }
                         ?? provider.missing)
                        .font(.mono(10)).foregroundStyle(provider.bin == nil ? Color.bad : Color.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                section("TARGETS") { targets }
                section("MODEL") { modelBar }
                section("TASK") { editor }
                if !claude.runs.isEmpty {
                    section("RUNS") { ForEach(claude.runs) { RunCard(run: $0) } }
                }
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.bg)
        .navigationTitle("Orchestrate")
    }

    func section<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) { SectionLabel(t: t); c() }
    }

    @ViewBuilder var targets: some View {
        let ms = claude.eligible
        if ms.isEmpty {
            Text("no machines yet — run Test connection on a machine; once key auth is verified it shows up here")
                .font(.mono(10)).foregroundStyle(.tertiary)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(ms) { m in
                    let on = picked.contains(m.id)
                    let reach = store.reach(m)
                    Button {
                        if on { claude.picked.remove(m.id) } else { claude.picked.insert(m.id) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? Color.accent : Color.dim)
                            Circle().fill(reach.color).frame(width: 6, height: 6)
                            Text(ClaudeCLI.name(m)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(m.os.uppercased()).font(.mono(8)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(on ? Color.accent.opacity(0.14) : Color.panelDeep, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(on ? Color.accent.opacity(0.6) : Color.ink.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        let unverified = store.machines.filter { $0.usesSSH && $0.authVerifiedAt == nil }
        if !unverified.isEmpty {
            Text("not available until key auth is verified: " + unverified.map(ClaudeCLI.name).joined(separator: ", "))
                .font(.mono(9)).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder var modelBar: some View {
        let c = config
        HStack(spacing: 18) {
            menu("SUPPLIER", $provider, Provider.allCases.map { ($0, $0.name) })
            menu("MODEL", Binding(get: { c.model }, set: { model = $0 }), provider.models.map { ($0, $0) })
            menu("REASONING", Binding(get: { c.effort }, set: { effort = $0 }), provider.efforts(c.model).map { ($0, $0) })
            if let n = provider.bigContext(c.model) {
                menu("CONTEXT", $bigContext, [(false, "standard"), (true, n >= 1_000_000 ? "\(n / 1_000_000)M" : "\(n / 1000)K")])
            }
            Spacer()
        }
        if provider == .zai, ClineCLI.bin != nil, ClineCLI.login() == nil {
            Text("Cline has no z.ai sign-in — run `cline auth` and pick Z.ai Coding Plan").font(.mono(10)).foregroundStyle(Color.bad)
        }
    }

    func menu<T: Hashable>(_ label: String, _ sel: Binding<T>, _ options: [(T, String)]) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.mono(9)).foregroundStyle(.dim).tracking(1.5)
            Picker(label, selection: sel) { ForEach(options, id: \.0) { Text($0.1).tag($0.0) } }
                .labelsHidden().pickerStyle(.menu).fixedSize()
        }
    }

    var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $claude.draft)
                .font(.mono(12))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 90)
                .padding(8)
                .background(Color.panelDeep, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.ink.opacity(0.07)))
            HStack {
                Text("e.g. “check disk and the web service on all of them — restart it if it's down”")
                    .font(.mono(9)).foregroundStyle(.tertiary)
                Spacer()
                Button {
                    claude.run(task, on: picked, config: config)
                    claude.draft = ""
                } label: { Label("Run · \(config.provider.name)", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).tint(Color.accent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(task.isEmpty || picked.isEmpty || provider.bin == nil)
                .help("⌘↩ · \(config.label)")
            }
        }
    }
}

struct RunCard: View {
    @EnvironmentObject private var claude: Orchestrator
    @ObservedObject var run: ClaudeRun
    @State private var followUp = ""

    var tint: Color {
        switch run.state { case .running: .accent; case .done: .ok; case .failed: .bad; case .stopped: .dim }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.dim)
                    .rotationEffect(.degrees(run.collapsed ? 0 : 90))
                Text(run.state.rawValue.uppercased()).font(.mono(9).weight(.bold)).tracking(1.5)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(tint)
                Text(run.prompt).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                Spacer()
                Text(run.config.label).font(.mono(9)).foregroundStyle(Color.accent).lineLimit(1)
                Text(run.targets.map(ClaudeCLI.name).joined(separator: ", ")).font(.mono(9)).foregroundStyle(.dim).lineLimit(1)
                if let end = run.ended {
                    Text(duration(Int(end.timeIntervalSince(run.started)))).font(.mono(9)).foregroundStyle(.tertiary)
                } else {
                    Text(run.started, style: .timer).font(.mono(9)).foregroundStyle(.tertiary)
                    Button("Stop", role: .destructive) { run.stop() }.controlSize(.small)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { run.collapsed.toggle() } }
            .help(run.collapsed ? "Expand" : "Collapse")
            if !run.collapsed { details }
        }
        .padding(14)
        .background(Color.panelDeep, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.ink.opacity(0.07)))
    }

    @ViewBuilder var details: some View {
        if !run.auth.isEmpty {
            Text("auth: \(run.auth)" + (run.session.isEmpty ? "" : " · session \(run.session.prefix(8))"))
                .font(.mono(9)).foregroundStyle(run.config.provider == .claude && run.auth.hasPrefix("API") ? Color.bad : Color.dim)
        }
        // the final assistant message comes back again as `result` — show it once, in the result box
        ForEach(run.steps.suffix(120).filter { $0.kind != .text || $0.text != run.result }) { step($0) }
        if !run.result.isEmpty {
            MarkdownText(text: run.result)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.bg, in: RoundedRectangle(cornerRadius: 6))
        }
        if run.state != .running, !run.session.isEmpty {
            HStack(spacing: 8) {
                TextField("follow up in this session…", text: $followUp)
                    .textFieldStyle(.roundedBorder).font(.mono(11))
                    .onSubmit(send)
                Button("Send", action: send).disabled(followUp.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Copy resume") { copyString(resumeCommand) }
                    .help("Continue interactively in a terminal (your normal settings and permission prompts apply there)")
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder func step(_ s: RunStep) -> some View {
        switch s.kind {
        case .text:
            MarkdownText(text: s.text)
        case .command:
            Text("$ " + short(s.text)).font(.mono(10)).foregroundStyle(Color.accent).textSelection(.enabled)
        case .output:
            Text(s.text).font(.mono(9)).foregroundStyle(.dim).lineLimit(8).textSelection(.enabled).padding(.leading, 14)
        case .error:
            Text(s.text).font(.mono(9)).foregroundStyle(Color.bad).lineLimit(6).textSelection(.enabled).padding(.leading, 14)
        }
    }

    /// The long ssh prefix → "Box_One ›".
    func short(_ cmd: String) -> String {
        for m in run.targets {
            let p = ClaudeCLI.prefix(m)
            if cmd.hasPrefix(p) { return ClaudeCLI.name(m) + " ›" + cmd.dropFirst(p.count) }
        }
        return cmd
    }

    /// Continue in a terminal.
    var resumeCommand: String {
        let cd = "cd ~/.tailnet-manager/claude && "
        switch run.config.provider {
        case .claude: return cd + "claude --resume \(run.session)"
        case .codex: return cd + "codex resume \(run.session)"
        case .zai: return cd + "cline --id \(run.session) --auto-approve false"   // its CLI default is approve-everything
        }
    }

    func send() {
        let t = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        claude.run(t, on: Set(run.targets.map(\.id)), config: run.config, resume: run.session)
        followUp = ""
    }
}

// MARK: - Markdown: SwiftUI's Text only renders inline markdown, so headings, lists, fences and tables are split here

enum Markdown {
    enum Block: Equatable {
        case heading(Int, String)
        case paragraph(String)
        case item(marker: String, text: String, indent: Int)
        case code(String)
        case quote(String)
        case table([[String]])
        case rule
    }

    static func blocks(_ s: String) -> [Block] {
        var out: [Block] = [], para: [String] = [], table: [[String]] = [], code: [String]?
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] }
            if !table.isEmpty { out.append(.table(table)); table = [] }
        }
        for raw in s.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let c = code {
                if line.hasPrefix("```") { out.append(.code(c.joined(separator: "\n"))); code = nil } else { code = c + [raw] }
                continue
            }
            if line.hasPrefix("|") {
                if !para.isEmpty { flush() }
                if line.allSatisfy({ "|-: ".contains($0) }) { continue }   // |---|:--:| separator
                table.append(line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) })
                continue
            }
            let indent = (raw.prefix { $0 == " " }.count) / 2
            if line.hasPrefix("```") { flush(); code = [] }
            else if line.isEmpty { flush() }
            else if let m = line.wholeMatch(of: #/(#{1,6})\s+(.*)/#) { flush(); out.append(.heading(m.1.count, String(m.2))) }
            else if line.wholeMatch(of: #/(-{3,}|\*{3,}|_{3,})/#) != nil { flush(); out.append(.rule) }
            else if let m = line.wholeMatch(of: #/[-*+]\s+(.*)/#) { flush(); out.append(.item(marker: "•", text: String(m.1), indent: indent)) }
            else if let m = line.wholeMatch(of: #/(\d+)[.)]\s+(.*)/#) { flush(); out.append(.item(marker: m.1 + ".", text: String(m.2), indent: indent)) }
            else if let m = line.wholeMatch(of: #/>\s?(.*)/#) { flush(); out.append(.quote(String(m.1))) }
            else { if !table.isEmpty { flush() }; para.append(line) }
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }   // still streaming, or never closed
        flush()
        return out
    }

    /// **bold**, *italic*, `code`, [links](…) — plain text if it doesn't parse.
    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Markdown.blocks(text).enumerated()), id: \.offset) { block($0.element) }
        }
        .font(.system(size: 12))
        .textSelection(.enabled)
        // shaped by remote output: web links only — never file:, ssh: or another app's URL scheme
        .environment(\.openURL, OpenURLAction { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? .systemAction : .discarded })
    }

    @ViewBuilder func block(_ b: Markdown.Block) -> some View {
        switch b {
        case .heading(let n, let t):
            Text(Markdown.inline(t)).font(.system(size: [16, 14, 13][min(n, 3) - 1], weight: .bold)).padding(.top, 4)
        case .paragraph(let t):
            Text(Markdown.inline(t))
        case .item(let marker, let t, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).font(.mono(11)).foregroundStyle(Color.accent)
                Text(Markdown.inline(t))
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .code(let t):
            Text(t).font(.mono(11)).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
        case .quote(let t):
            Text(Markdown.inline(t)).foregroundStyle(.dim).padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Color.accent).frame(width: 2) }
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                GridRow { ForEach(rows[0].indices, id: \.self) { Text(Markdown.inline(rows[0][$0])).fontWeight(.semibold) } }
                Divider()
                ForEach(1..<rows.count, id: \.self) { i in
                    GridRow { ForEach(rows[i].indices, id: \.self) { Text(Markdown.inline(rows[i][$0])) } }
                }
            }
            .padding(8)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.ink.opacity(0.08)))
        case .rule:
            Divider()
        }
    }
}
