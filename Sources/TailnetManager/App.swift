import SwiftUI
import AppKit
import TailnetCore

@main
struct TailnetManagerApp: App {
    @StateObject private var store = Store()

    init() {
        // Codex's ssh tool: this binary, run headless as an MCP server (SSHBridge) — before anything AppKit or single-instance
        UserEnvironment.load()   // what install.sh recorded about this Mac — before any tool path is looked up
        let argv = CommandLine.arguments
        if let i = argv.firstIndex(of: "--ssh-mcp"), i + 1 < argv.count { SSHBridge.serve(argv[i + 1]) }
        // Claude's PreToolUse guard (BashHook) — must exit before the single-instance check, which would exit 0 = allow
        if argv.contains("--bash-hook") { BashHook.run() }
        // ponytail: single instance — two open copies each hold their own vault snapshot
        // and clobber each other's writes (last-writer-wins corrupted the fleet once already)
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: AppInfo.bundleID)
            .filter { $0 != NSRunningApplication.current }
        if let other = others.first {
            other.activate()
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("Tailnet Manager") {
            ContentView().environmentObject(store)
        }
    }
}
