import XCTest
@testable import TailnetCore

@MainActor
final class FolderTests: XCTestCase {
    func store(_ names: [String]) -> Store {
        let s = Store(vaultKey: nil)
        s.machines = names.map { Machine(id: $0, name: $0, host: $0) }
        return s
    }

    func testTagGroupsMigrateToFoldersOnce() {
        var ms = [Machine(id: "a", name: "a", host: "a"), Machine(id: "b", name: "b", host: "b"), Machine(id: "c", name: "c", host: "c")]
        ms[0].tags = ["acme", "prod"]
        ms[1].tags = ["acme"]
        let fs = Store.foldersFromTags(&ms)
        XCTAssertEqual(fs.map(\.name), ["acme"])                 // first tag only → one folder
        XCTAssertEqual(ms.map(\.folderId), [fs[0].id, fs[0].id, ""])
    }

    func testDragReorderNestAndDelete() {
        let s = store(["web", "db", "cache"])
        let acme = s.addFolder("ACME")!
        let prod = s.addFolder("prod", in: acme.id)!

        XCTAssertTrue(s.drop(["m:db"], into: prod.id))           // machine onto a folder
        XCTAssertEqual(s.machines(in: prod.id).map(\.id), ["db"])
        s.drop(["m:cache"], into: prod.id, before: "db")         // machine onto a machine → lands above it
        XCTAssertEqual(s.machines(in: prod.id).map(\.id), ["cache", "db"])
        XCTAssertEqual(s.path(prod.id).map(\.name), ["ACME", "prod"])
        XCTAssertEqual(s.treeOrder().map(\.id), ["cache", "db", "web"])   // folders first, depth-first, then loose

        XCTAssertFalse(s.drop(["f:\(acme.id)"], into: prod.id))  // can't nest a folder inside itself
        XCTAssertEqual(s.folders(in: "").map(\.name), ["ACME"])

        s.deleteFolder(acme.id)                                   // contents move up, nothing deleted
        XCTAssertEqual(s.folders(in: "").map(\.name), ["prod"])
        XCTAssertEqual(s.machines.count, 3)
        s.deleteFolder(prod.id)
        XCTAssertEqual(Set(s.machines(in: "").map(\.id)), ["web", "db", "cache"])
    }

    func testDanglingFolderFallsBackToTopLevel() {
        let s = store(["x"])
        s.machines[0].folderId = "gone"
        XCTAssertEqual(s.machines(in: "").map(\.id), ["x"])
    }
}
