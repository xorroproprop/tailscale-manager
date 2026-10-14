import AppKit
import SwiftUI

// MARK: - Syntax highlighting: one small scanner + a language table, coloured with your Ghostty palette
// ponytail: a single-pass scanner (comments, strings, numbers, keywords, $vars, calls) — not a parser. Plenty to read
// a snippet at a glance; swap in tree-sitter if you ever need real grammars.

enum Syntax {
    enum Token: Hashable { case keyword, string, comment, number, type, variable, function }

    struct Lang: Identifiable, Hashable {
        let id: String
        let name: String
        var exts: [String] = []
        var line: [String] = []                // line-comment openers
        var block: [String] = []               // [open, close]
        var keywords: Set<String> = []
        var quotes = "\"'"
        var escape: Character? = "\\"          // PowerShell escapes with a backtick, so C:\temp\ stays a closed string
        var caseless = false                   // keywords in any case (SQL, PowerShell, batch, Dockerfile)
        var vars = false                       // $name, ${name}
        var types = false                      // Capitalised identifiers are types
        var keyBefore: Character? = nil        // `key:` / `key=` (YAML, INI, CSS, HTML attributes)
        var tags = false                       // <tag> names
    }

    private static func kw(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }
    private static let cLike = ["//"], cBlock = ["/*", "*/"]

    static let plain = Lang(id: "text", name: "Plain text", exts: ["txt", "md", "log"])
    static let langs: [Lang] = [
        Lang(id: "bash", name: "Shell", exts: ["sh", "bash", "zsh"], line: ["#"],
             keywords: kw("if then else elif fi for while until do done case esac in function return local export readonly declare unset source exit break continue select"),
             quotes: "\"'`", vars: true),
        Lang(id: "powershell", name: "PowerShell", exts: ["ps1", "psm1", "psd1"], line: ["#"], block: ["<#", "#>"],
             keywords: kw("function param if elseif else foreach for while do until switch return try catch finally throw begin process end in trap break continue exit filter class using"),
             escape: "`", caseless: true, vars: true),
        Lang(id: "batch", name: "Batch", exts: ["bat", "cmd"], line: ["::", "rem ", "REM ", "@rem ", "@REM "],
             keywords: kw("echo set if else for in do goto call exit not exist defined errorlevel setlocal endlocal off on start pushd popd shift"),
             quotes: "\"", escape: nil, caseless: true),
        Lang(id: "python", name: "Python", exts: ["py", "pyw"], line: ["#"],
             keywords: kw("def class if elif else for while in not and or is None True False return import from as try except finally raise with lambda yield pass break continue global nonlocal assert async await del match case self"),
             types: true),
        Lang(id: "swift", name: "Swift", exts: ["swift"], line: cLike, block: cBlock,
             keywords: kw("let var func if else guard return struct class enum case switch default for in while repeat import protocol extension static private public internal fileprivate init self Self nil true false throws throw try catch async await some any where defer break continue inout mutating override final weak lazy typealias do is as"),
             types: true),
        Lang(id: "js", name: "JavaScript · TypeScript", exts: ["js", "mjs", "cjs", "jsx", "ts", "tsx"], line: cLike, block: cBlock,
             keywords: kw("const let var function return if else for while do switch case default break continue new delete typeof instanceof in of class extends super this null undefined true false import export from as async await try catch finally throw yield interface type enum implements public private protected readonly static void"),
             quotes: "\"'`", types: true),
        Lang(id: "go", name: "Go", exts: ["go"], line: cLike, block: cBlock,
             keywords: kw("package import func var const type struct interface map chan go defer return if else for range switch case default break continue select fallthrough goto nil true false"),
             quotes: "\"'`", types: true),
        Lang(id: "rust", name: "Rust", exts: ["rs"], line: cLike, block: cBlock,
             keywords: kw("fn let mut const static struct enum impl trait pub use mod crate self Self super match if else loop while for in return break continue as ref move where unsafe async await dyn true false type"),
             quotes: "\"", types: true),
        Lang(id: "c", name: "C · C++", exts: ["c", "h", "cpp", "cc", "hpp"], line: cLike, block: cBlock,
             keywords: kw("int char float double void long short unsigned signed struct union enum typedef static const extern return if else for while do switch case default break continue sizeof goto auto volatile inline class public private protected namespace using template typename new delete this true false nullptr"),
             types: true),
        Lang(id: "jvm", name: "Java · Kotlin · C#", exts: ["java", "kt", "kts", "cs"], line: cLike, block: cBlock,
             keywords: kw("class interface enum extends implements public private protected internal static final abstract void int long boolean bool double float char byte short string return if else for foreach while do switch case default break continue new this super null true false try catch finally throw throws import package namespace using fun val var when object companion data override async await is as in"),
             types: true),
        Lang(id: "sql", name: "SQL", exts: ["sql"], line: ["--"], block: cBlock,
             keywords: kw("select from where and or not insert into values update set delete create table drop alter index join left right inner outer on as group by order having limit offset union all distinct null is in like between case when then else end primary key foreign references default exists count sum avg min max begin commit rollback with returning"),
             escape: nil, caseless: true),
        Lang(id: "json", name: "JSON", exts: ["json", "jsonc"], line: cLike, keywords: kw("true false null"), quotes: "\""),
        Lang(id: "yaml", name: "YAML", exts: ["yml", "yaml"], line: ["#"], keywords: kw("true false null yes no on off"), keyBefore: ":"),
        Lang(id: "ini", name: "INI · TOML · env", exts: ["ini", "toml", "conf", "cfg", "env", "properties"], line: ["#", ";"],
             keywords: kw("true false"), keyBefore: "="),
        Lang(id: "dockerfile", name: "Dockerfile", exts: ["dockerfile"], line: ["#"],
             keywords: kw("from run cmd copy add env arg workdir expose entrypoint user volume label healthcheck shell onbuild stopsignal as"),
             caseless: true, vars: true),
        Lang(id: "html", name: "HTML · XML", exts: ["html", "htm", "xml", "svg", "plist", "xaml", "csproj"], block: ["<!--", "-->"],
             quotes: "\"", keyBefore: "=", tags: true),
        Lang(id: "css", name: "CSS", exts: ["css", "scss", "less"], line: cLike, block: cBlock, keywords: kw("important media import"),
             keyBefore: ":"),
        plain,
    ]

    static func lang(_ id: String) -> Lang? { langs.first { $0.id == id } }

    /// From the name (extension, Dockerfile, .env), else a #! line, else plain text.
    static func detect(_ name: String, _ code: String = "") -> Lang {
        let n = name.lowercased()
        if n.hasPrefix("dockerfile") { return lang("dockerfile")! }
        let ext = n.contains(".") ? String(n.split(separator: ".").last ?? "") : ""
        if let l = langs.first(where: { $0.exts.contains(ext) }) { return l }
        guard code.hasPrefix("#!") else { return plain }
        let bang = code.prefix { $0 != "\n" }
        return lang(bang.contains("python") ? "python" : bang.contains("pwsh") ? "powershell" : bang.contains("node") ? "js" : "bash")!
    }

    /// (range, token) pairs in UTF-16 offsets — what NSTextStorage wants.
    static func tokens(_ code: String, _ l: Lang) -> [(NSRange, Token)] {
        let u = Array(code.utf16), n = u.count
        let lines = l.line.map { Array($0.utf16) }
        let block = l.block.count == 2 ? (Array(l.block[0].utf16), Array(l.block[1].utf16)) : nil
        let quotes = Set(l.quotes.utf16), esc = l.escape?.utf16.first, keySep = l.keyBefore?.utf16.first
        func word(_ c: UInt16) -> Bool { c == 95 || (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) }
        func at(_ i: Int, _ s: [UInt16]) -> Bool { i + s.count <= n && u[i..<i + s.count].elementsEqual(s) }
        var out: [(NSRange, Token)] = [], i = 0
        func emit(_ s: Int, _ t: Token) { out.append((NSRange(location: s, length: i - s), t)) }

        while i < n {
            let s = i, c = u[i]
            if let b = block, at(i, b.0) {
                i += b.0.count
                while i < n && !at(i, b.1) { i += 1 }
                i = min(n, i + b.1.count)
                emit(s, .comment)
            } else if lines.contains(where: { at(i, $0) }) {
                while i < n && u[i] != 10 { i += 1 }
                emit(s, .comment)
            } else if quotes.contains(c) {
                let triple = at(i, [c, c, c])   // """docstrings""" and Swift multi-line strings
                i += triple ? 3 : 1
                while i < n {
                    if u[i] == esc { i += 2; continue }
                    if triple ? at(i, [c, c, c]) : u[i] == c { i += triple ? 3 : 1; break }
                    if u[i] == 10 && !triple && c != 96 { break }   // an unclosed quote only colours its own line
                    i += 1
                }
                i = min(i, n)
                emit(s, .string)
            } else if l.vars && c == 36 && i + 1 < n {   // $name ${name} $? $#
                i += 1
                if u[i] == 123 { while i < n && u[i] != 125 { i += 1 }; i = min(n, i + 1) }
                else if word(u[i]) { while i < n && word(u[i]) { i += 1 } }
                else if "#?@$!*-".utf16.contains(u[i]) { i += 1 }
                if i - s > 1 { emit(s, .variable) }
            } else if (48...57).contains(c) {
                while i < n && (word(u[i]) || u[i] == 46) { i += 1 }
                emit(s, .number)
            } else if word(c) {
                while i < n && word(u[i]) { i += 1 }
                let w = String(decoding: u[s..<i], as: UTF16.self)
                let after = u[i...].first { $0 != 32 && $0 != 9 }
                if l.keywords.contains(l.caseless ? w.lowercased() : w) { emit(s, .keyword) }
                else if l.tags && s > 0 && (u[s - 1] == 60 || (u[s - 1] == 47 && s > 1 && u[s - 2] == 60)) { emit(s, .keyword) }   // <tag </tag
                else if keySep != nil && after == keySep { emit(s, .function) }
                else if after == 40 { emit(s, .function) }   // call(
                else if l.types && (65...90).contains(c) { emit(s, .type) }
            } else {
                i += 1
            }
        }
        return out
    }

    /// Your Ghostty palette (ANSI slots) so code looks like your terminal; One Dark where the config has none.
    static let colors: [Token: NSColor] = {
        let p = GhosttyLook.user.palette
        func c(_ i: Int, _ hex: String) -> NSColor { p[i] ?? NSColor(hex: hex)! }
        return [.keyword: c(5, "c678dd"), .string: c(2, "98c379"), .comment: c(8, "5c6370"), .number: c(3, "d19a66"),
                .type: c(6, "56b6c2"), .variable: c(1, "e06c75"), .function: c(4, "61afef")]
    }()
}

// MARK: - Code editor: NSTextView (SwiftUI's TextEditor can't colour text on macOS 14), re-highlighted on every edit
// ponytail: re-highlights the whole text per keystroke — instant for snippets; go incremental past ~5k lines

struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let lang: Syntax.Lang

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        let look = GhosttyLook.user
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.usesFindBar = true                   // ⌘F inside the snippet
        tv.isIncrementalSearchingEnabled = true
        // code, not prose: no smart quotes, dashes, autocorrect or spellcheck
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.backgroundColor = look.background
        tv.insertionPointColor = look.cursor ?? look.foreground
        if let sel = look.selection { tv.selectedTextAttributes = [.backgroundColor: sel] }
        tv.textContainerInset = NSSize(width: 12, height: 12)
        // no wrapping — long lines scroll sideways, like an editor
        tv.isHorizontallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.hasHorizontalScroller = true
        scroll.backgroundColor = look.background
        tv.string = text
        context.coordinator.highlight(tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text; c.highlight(tv) }
        else if c.lang != lang.id { c.highlight(tv) }   // language picked by hand
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        var lang = ""
        init(_ p: CodeEditor) { parent = p }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            highlight(tv)
        }

        func highlight(_ tv: NSTextView) {
            guard let s = tv.textStorage, !tv.hasMarkedText() else { return }   // don't disturb IME composition
            lang = parent.lang.id
            let look = GhosttyLook.user
            s.beginEditing()
            s.setAttributes([.font: look.font, .foregroundColor: look.foreground], range: NSRange(location: 0, length: s.length))
            for (r, t) in Syntax.tokens(s.string, parent.lang) { s.addAttribute(.foregroundColor, value: Syntax.colors[t]!, range: r) }
            s.endEditing()
            tv.typingAttributes = [.font: look.font, .foregroundColor: look.foreground]
        }
    }
}
