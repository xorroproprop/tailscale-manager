import XCTest
import AppKit
@testable import TailnetCore

final class TailnetCoreTests: XCTestCase {
    func testParsesTailscaleStatusJSON() throws {
        let json = """
        {"Version":"1.96.4","BackendState":"Running","Health":[],
         "Self":{"HostName":"mac","TailscaleIPs":["100.1.2.3"]},
         "Peer":{
           "nodekey:a":{"ID":"1","HostName":"ai-box","DNSName":"ai-box.tail123.ts.net.","OS":"windows","TailscaleIPs":["100.10.0.1"],"Online":true},
           "nodekey:b":{"ID":"2","HostName":"build1","DNSName":"build1.tail123.ts.net.","OS":"linux","TailscaleIPs":["100.10.0.2"],"Online":false,"LastSeen":"2026-10-01T10:00:00Z"}}}
        """
        let s = try JSONDecoder().decode(TailnetStatus.self, from: Data(json.utf8))
        let peers = s.machines
        XCTAssertEqual(peers.count, 2)
        XCTAssertEqual(peers.first?.hostName, "ai-box")               // online machines sort first
        XCTAssertEqual(peers.first?.ip, "100.10.0.1")
        XCTAssertEqual(peers.first?.id, "100.10.0.1")                 // keyed by tailnet IP
        XCTAssertEqual(peers.first?.dnsName, "ai-box.tail123.ts.net") // trailing dot trimmed
        XCTAssertEqual(peers.last?.online, false)
        XCTAssertEqual(s.BackendState, "Running")
    }

    func testToleratesStderrNoiseBeforeJSON() throws {
        let noisy = "Warning: client version 1.96.4 != server 1.102.3\n{\"BackendState\":\"Running\",\"Peer\":{}}"
        let brace = noisy.firstIndex(of: "{")
        XCTAssertNotNil(brace)
        let s = try JSONDecoder().decode(TailnetStatus.self, from: Data(String(noisy[brace!...]).utf8))
        XCTAssertEqual(s.machines.count, 0)
    }

    func testMachineRoundTripAndKindFlags() throws {
        var m = Machine(name: "AI Dev Box", host: "100.10.0.1")
        m.os = "windows"
        m.kind = .rdp
        m.rdpUser = "alice"
        m.tags = ["threat intel", "research"]
        m.sshTabs = [SshTab(name: "logs", command: "tail -f /var/log/syslog")]
        m.authVerifiedAt = Date()
        let data = try JSONEncoder().encode([m])
        let back = try JSONDecoder().decode([Machine].self, from: data)
        XCTAssertEqual(back, [m])
        XCTAssertEqual(back[0].sshTabs.first?.command, "tail -f /var/log/syslog")
        XCTAssertNotNil(back[0].authVerifiedAt)
        XCTAssertTrue(back[0].usesRDP)
        XCTAssertFalse(back[0].usesSSH)
        var both = m
        both.kind = .both
        XCTAssertTrue(both.usesSSH && both.usesRDP)
    }

    func testMachineDecodesLegacyVaultJSONWithoutNewFields() throws {
        // vault written before sshTabs/authVerifiedAt existed must still decode
        let legacy = """
        [{"id":"abc","name":"Box_One","host":"203.0.113.10","os":"linux","kind":"both",
          "sshUser":"alice","rdpUser":"","tags":["web_server"],"online":null}]
        """
        let ms = try JSONDecoder().decode([Machine].self, from: Data(legacy.utf8))
        XCTAssertEqual(ms.count, 1)
        XCTAssertEqual(ms[0].sshTabs, [])
        XCTAssertNil(ms[0].authVerifiedAt)
        XCTAssertEqual(ms[0].name, "Box_One")
        _ = try JSONEncoder().encode(ms[0])
    }

    func testSeparatesMullvadExitNodesAndParsesPaths() throws {
        let json = """
        {"BackendState":"Running","CurrentTailnet":{"Name":"me.github"},
         "Self":{"HostName":"mac","OS":"macOS","TailscaleIPs":["100.1.2.3"],"Online":true},
         "Peer":{
           "a":{"HostName":"gitlab","OS":"linux","TailscaleIPs":["100.10.0.5"],"Online":true,"CurAddr":"47.1.2.3:1033","Relay":"fra","Active":true,"RxBytes":2048},
           "b":{"HostName":"de-fra-wg-001","DNSName":"de-fra-wg-001.mullvad.ts.net.","TailscaleIPs":["100.64.0.60"],"Online":true,
                "ExitNode":true,"ExitNodeOption":true,"Location":{"Country":"Germany","CountryCode":"DE","City":"Frankfurt","Priority":200}}}}
        """
        let s = try JSONDecoder().decode(TailnetStatus.self, from: Data(json.utf8))
        let all = s.machines
        let own = all.filter { !$0.isMullvad }
        XCTAssertEqual(own.map(\.hostName), ["gitlab"])                     // Mullvad fleet never shows as "your" machines
        XCTAssertEqual(own.first?.curAddr, "47.1.2.3:1033")
        XCTAssertTrue(own.first?.active ?? false)
        let exit = all.first { $0.isExit }
        XCTAssertEqual(exit?.location?.City, "Frankfurt")
        XCTAssertTrue(exit?.exitOption ?? false)
        XCTAssertEqual(s.selfNode?.peer.ip, "100.1.2.3")
        XCTAssertEqual(s.CurrentTailnet?.Name, "me.github")
        XCTAssertEqual(flag("us"), "🇺🇸")
    }

    func testGhosttyLookPicksDarkThemeThenConfigOverrides() {
        let config = """
        # comment = ignored
        theme = light:Latte,dark:Mocha
        font-size = 14
        window-padding-x = 8
        window-padding-y = 6,2
        foreground = #ffffff
        background-image = "/tmp/art.png"
        background-image-opacity = 0.35
        macos-option-as-alt = true
        """
        var asked: [String] = []
        let look = GhosttyLook.resolve(config: config) { name in
            asked.append(name)
            return name == "Mocha" ? "background = #1e1e2e\nforeground = #cdd6f4\npalette = 1=#f38ba8\n" : nil
        }
        XCTAssertEqual(asked, ["Mocha"])
        XCTAssertEqual(look.background, NSColor(hex: "1e1e2e"))       // from theme
        XCTAssertEqual(look.foreground, NSColor(hex: "#ffffff"))      // config beats theme
        XCTAssertEqual(look.palette[1], NSColor(hex: "#f38ba8"))
        XCTAssertEqual(look.fontSize, 14)
        XCTAssertEqual(look.padding, NSSize(width: 8, height: 6))
        XCTAssertEqual(look.backgroundImage, "/tmp/art.png")
        XCTAssertEqual(look.backgroundImageOpacity, 0.35, accuracy: 0.001)
        XCTAssertTrue(look.optionAsAlt)
        XCTAssertEqual(GhosttyLook.darkVariant("Dracula"), "Dracula")
        XCTAssertEqual(GhosttyLook.darkVariant("light:Latte"), "Latte")
    }
}
