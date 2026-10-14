import XCTest
@testable import TailnetCore

final class SnippetsTests: XCTestCase {
    /// "text:kind" for every token — readable assertions.
    func toks(_ code: String, _ id: String) -> [String] {
        let ns = code as NSString
        return Syntax.tokens(code, Syntax.lang(id)!).map { "\(ns.substring(with: $0.0)):\($0.1)" }
    }

    func testScannerKeepsCommentsStringsAndCodeApart() {
        // a # inside a string isn't a comment; a quote inside a comment isn't a string
        XCTAssertEqual(toks(#"x = "a # b"  # it's fine"#, "python"), [#""a # b":string"#, "# it's fine:comment"])
        XCTAssertEqual(toks("def run(n=42):\n    return Path(n)", "python"),
                       ["def:keyword", "run:function", "42:number", "return:keyword", "Path:function"])
        XCTAssertEqual(toks(#"s = """a\n"b"\n"""; class Job: pass"#, "python").first, #""""a\n"b"\n""":string"#)   // docstring spans lines
        XCTAssertEqual(toks("echo \"$HOME\" ${x} $? # done", "bash"), [#""$HOME":string"#, "${x}:variable", "$?:variable", "# done:comment"])
        // PowerShell: backslashes are path separators (backtick escapes), keywords any case, <# block #>
        XCTAssertEqual(toks(#"<# hi #> IF ($env) { "C:\temp\" }"#, "powershell"),
                       ["<# hi #>:comment", "IF:keyword", "$env:variable", #""C:\temp\":string"#])
        XCTAssertEqual(toks("SELECT id FROM t -- note", "sql"), ["SELECT:keyword", "FROM:keyword", "-- note:comment"])
        XCTAssertEqual(toks("services:\n  web:\n    ports: [80]", "yaml"), ["services:function", "web:function", "ports:function", "80:number"])
        XCTAssertEqual(toks(#"<div class="x">"#, "html"), ["div:keyword", "class:function", #""x":string"#])
        XCTAssertEqual(toks("let s = \"open\nlet t = 1", "swift").map { $0 }, ["let:keyword", "\"open:string", "let:keyword", "1:number"])   // unclosed quote stops at the line end
        XCTAssertEqual(toks("é \"ü\" 1", "js"), [#""ü":string"#, "1:number"])   // non-ASCII: UTF-16 ranges stay right
    }

    func testLanguageComesFromTheNameThenTheShebang() {
        XCTAssertEqual(Syntax.detect("tnm_notify.py").id, "python")
        XCTAssertEqual(Syntax.detect("Send-TnmEvent.PS1").id, "powershell")
        XCTAssertEqual(Syntax.detect("docker-compose.yml").id, "yaml")
        XCTAssertEqual(Syntax.detect("Dockerfile").id, "dockerfile")
        XCTAssertEqual(Syntax.detect(".env").id, "ini")
        XCTAssertEqual(Syntax.detect("deploy", "#!/usr/bin/env python3\nprint(1)").id, "python")
        XCTAssertEqual(Syntax.detect("deploy", "#!/bin/zsh\nls").id, "bash")
        XCTAssertEqual(Syntax.detect("notes").id, "text")
        var s = Snippet(name: "a.sh")
        XCTAssertEqual(s.lang.id, "bash")
        s.language = "python"                                                   // picked by hand wins
        XCTAssertEqual(s.lang.id, "python")
        XCTAssertEqual(Set(Syntax.langs.map(\.id)).count, Syntax.langs.count)  // ids unique
    }

    func testSearchRanksNamesThenLettersInOrderThenCode() {
        let all = [Snippet(name: "docker-compose.yml", code: "services:"), Snippet(name: "gcs-upload.sh", code: "gcloud storage cp"),
                   Snippet(name: "notes.txt", code: "remember docker prune"), Snippet(name: "Dockerfile", code: "FROM alpine")]
        XCTAssertEqual(Snippet.search(all, "").map(\.name), ["docker-compose.yml", "Dockerfile", "gcs-upload.sh", "notes.txt"])
        XCTAssertEqual(Snippet.search(all, "docker").map(\.name), ["docker-compose.yml", "Dockerfile", "notes.txt"])
        XCTAssertEqual(Snippet.search(all, "dcy").map(\.name), ["docker-compose.yml"])
        XCTAssertEqual(Snippet.search(all, "GCLOUD").map(\.name), ["gcs-upload.sh"])
        XCTAssertEqual(Snippet.search(all, "zzz"), [])
    }

    @MainActor func testSaveOnlyStampsRealChangesAndImportTakesTextFiles() throws {
        let store = Store(vaultKey: nil)
        let s = store.addSnippet(Snippet(name: "a.sh", code: "ls", updatedAt: .distantPast))
        store.saveSnippet(s)
        XCTAssertEqual(store.snippets[0].updatedAt, .distantPast)              // nothing changed → no write
        var edited = s
        edited.code = "ls -la"
        store.saveSnippet(edited)
        XCTAssertEqual(store.snippets[0].code, "ls -la")
        XCTAssertGreaterThan(store.snippets[0].updatedAt, .distantPast)
        store.deleteSnippet(s.id)
        store.saveSnippet(edited)                                              // editor flushing after a delete
        XCTAssertTrue(store.snippets.isEmpty)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = dir.appendingPathComponent("gcs-upload.sh"), bin = dir.appendingPathComponent("blob.bin"), big = dir.appendingPathComponent("big.txt")
        try Data("gcloud storage cp a gs://b\n".utf8).write(to: text)
        try Data([0x00, 0x01, 0xFF]).write(to: bin)
        try Data(repeating: 65, count: Snippet.maxBytes + 1).write(to: big)
        XCTAssertEqual(store.importSnippet(text)?.lang.id, "bash")
        XCTAssertNil(store.importSnippet(bin))
        XCTAssertNil(store.importSnippet(big))
        XCTAssertNil(store.importSnippet(dir))
        XCTAssertEqual(store.snippets.map(\.name), ["gcs-upload.sh"])
    }
}
