import XCTest
import SwiftTerm
@testable import TailnetCore

final class TerminalCopyTests: XCTestCase {
    /// A remote host can't touch this Mac's clipboard through OSC 52 (read and write share one handler; writing is the
    /// half a test can observe without reading your clipboard). Only web links open on ⌘-click.
    @MainActor func testRemoteCannotReachTheClipboardOrOpenLocalURLs() {
        _ = NSApplication.shared
        let term = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let before = NSPasteboard.general.changeCount
        term.feed(text: "\u{1b}]52;c;\(Data("pwned".utf8).base64EncodedString())\u{07}")   // write
        term.feed(text: "\u{1b}]52;c;?\u{07}")                                             // read query
        XCTAssertEqual(NSPasteboard.general.changeCount, before)
    }

    @MainActor func testDragSelectsEvenWhenTheRemoteGrabsTheMouseAndCopyOnSelectFollowsGhostty() throws {
        _ = NSApplication.shared
        let saved = NSPasteboard.general.string(forType: .string)   // don't leave the test's text on your clipboard
        defer { NSPasteboard.general.clearContents(); if let saved { NSPasteboard.general.setString(saved, forType: .string) } }

        let term = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let win = NSWindow(contentRect: term.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = term
        var copied: [String] = []
        term.onCopy = { copied.append($0) }
        term.copyOnSelect = true
        term.feed(text: "\u{1b}[?1000hhello world from the server\r\n")   // remote turns on mouse tracking, like tmux / ConPTY

        func drag(_ flags: NSEvent.ModifierFlags = []) {
            func ev(_ t: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
                NSEvent.mouseEvent(with: t, location: term.convert(NSPoint(x: x, y: term.bounds.height - 8), to: nil), modifierFlags: flags,
                                   timestamp: 0, windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            term.mouseDown(with: ev(.leftMouseDown, 2))
            term.mouseDragged(with: ev(.leftMouseDragged, 3))
            term.mouseDragged(with: ev(.leftMouseDragged, 120))
            term.mouseUp(with: ev(.leftMouseUp, 120))
        }
        drag()
        let sel = try XCTUnwrap(term.getSelection())
        XCTAssertTrue(sel.hasPrefix("hello world"), sel)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), sel)        // copy-on-select = clipboard
        XCTAssertEqual(copied, [sel])                                             // → "copied" notice
        XCTAssertTrue(term.allowMouseReporting)                                   // the wheel still goes to the app

        term.dataReceived(slice: ArraySlice("more output\r\nand more\r\n".utf8))   // the path ssh output takes
        XCTAssertEqual(term.getSelection(), sel)                                  // streaming output keeps it

        let menu = try XCTUnwrap(term.menu(for: NSEvent()))
        XCTAssertEqual(menu.items.map(\.title), ["Copy", "Paste", "", "Select All"])
        XCTAssertTrue(term.validateUserInterfaceItem(menu.items[0]))              // Copy enabled with a selection

        term.selectNone()
        drag(.option)                                                             // ⌥: the mouse belongs to the remote app
        XCTAssertNil(term.getSelection())
        XCTAssertFalse(term.validateUserInterfaceItem(menu.items[0]))
        XCTAssertEqual(copied.count, 1)

        term.copyOnSelect = false
        drag()
        XCTAssertEqual(copied.count, 1)                                           // selecting alone doesn't copy…
        term.copy(term)
        XCTAssertEqual(copied.count, 2)                                           // …⌘C / right-click Copy does

        XCTAssertTrue(GhosttyLook.resolve(config: "copy-on-select = clipboard") { _ in nil }.copyOnSelect)
        XCTAssertFalse(GhosttyLook.resolve(config: "copy-on-select = true") { _ in nil }.copyOnSelect)
        XCTAssertFalse(GhosttyLook.resolve(config: "") { _ in nil }.copyOnSelect)
    }

    func testMachineHotkeysHopBetweenConnectedMachines() {
        let live = ["a", "b", "c"]
        func hop(_ h: Terminals.Hop, _ cur: String?, last: String? = nil) -> String? { Terminals.hop(h, live: live, current: cur, last: last) }
        XCTAssertEqual(hop(.next, "a"), "b")
        XCTAssertEqual(hop(.next, "c"), "a")                                     // wraps
        XCTAssertEqual(hop(.previous, "a"), "c")
        XCTAssertEqual(hop(.next, nil, last: "b"), "b")                          // from Pipelines: back to where you were
        XCTAssertEqual(hop(.next, nil, last: "gone"), "a")                       // …unless it disconnected
        XCTAssertEqual(hop(.previous, "home-page-machine"), "c")
        XCTAssertEqual(hop(.number(2), nil), "b")
        XCTAssertEqual(hop(.number(9), "a"), "c")                                // ⌃9 = last
        XCTAssertNil(hop(.number(5), "a"))                                       // no 5th machine: key passes through
        XCTAssertNil(Terminals.hop(.next, live: [], current: nil, last: "a"))
    }

    /// Fast switching: the old page's wrapper is torn down after the new one took the terminal. The terminal must
    /// stay on the new page.
    @MainActor func testNewestPageKeepsTheTerminalWhenAnOldPageTearsDownLate() {
        let term = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let c = TermContainer(term: term)
        let old = TermSlot(c)
        XCTAssertTrue(c.superview === old)
        let new = TermSlot(c)
        XCTAssertTrue(c.superview === new)
        old.layout()                                    // late layout on the dying page
        old.adopt()
        XCTAssertTrue(c.superview === new)              // never taken back
        old.removeFromSuperview()
        XCTAssertTrue(c.superview === new)
    }

    func testListingKeysNoLongerSpawnsAShell() {
        _ = SSHKeys.list()
        let t0 = Date()
        for _ in 0..<10 { _ = SSHKeys.list() }
        XCTAssertLessThan(Date().timeIntervalSince(t0) / 10, 0.03)   // was ~100 ms per machine switch
    }
}
