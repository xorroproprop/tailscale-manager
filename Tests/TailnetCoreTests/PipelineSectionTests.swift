import XCTest
@testable import TailnetCore

final class PipelineSectionTests: XCTestCase {
    func ev(_ json: String) throws -> PipelineEvent { try PipelineEvent.decode(Data(json.utf8)) }

    func testEnvelopeDecodesAndOldStoredEventsStillLoad() throws {
        // envelope only: resource.id → job, occurred_at → time, type → event, data → telemetry
        let e = try ev(#"{"schema_version":1,"event_id":"e-1","occurred_at":"2026-10-06T14:00:00Z","service":"nightly-backup","type":"job.started","resource":{"type":"job","id":"pr-7"},"status":"running","message":"Q3-reports.7z","data":{"volumes":3}}"#)
        XCTAssertEqual([e.jobId, e.event, e.service, e.resourceType, e.resourceId, e.eventId], ["pr-7", "job.started", "nightly-backup", "job", "pr-7", "e-1"])
        XCTAssertTrue(e.telemetry.contains("volumes"))
        XCTAssertEqual(e.at.timeIntervalSince1970, 1791295200, accuracy: 1)
        // both shapes at once: job_id wins for grouping, type wins over the legacy event name
        let both = try ev(#"{"job_id":"run-1","timestamp":"2026-10-06T14:00:00Z","event":"stage_finished","type":"job.stage_finished","stage":"extract","status":"success","service":"nightly-backup","resource":{"type":"job","id":"run-1"}}"#)
        XCTAssertEqual([both.jobId, both.event, both.stage], ["run-1", "job.stage_finished", "extract"])
        XCTAssertThrowsError(try ev(#"{"occurred_at":"2026-10-06T14:00:00Z","type":"x","status":"ok"}"#))   // no job_id, no resource.id

        // a vault written before the envelope existed — none of the new keys — must still decode (else the vault resets)
        let old = try JSONDecoder().decode(PipelineEvent.self, from: Data(#"{"id":"1","jobId":"j","at":0,"event":"e","stage":"","status":"ok","source":"s","machineId":"","message":"","telemetry":"","receivedAt":0}"#.utf8))
        XCTAssertNil(old.service)
        XCTAssertNil(old.eventId)
    }

    @MainActor func testReplayedEventsAreDroppedButStillAccepted() throws {
        let store = Store(vaultKey: nil)
        let e = try ev(#"{"event_id":"e-1","occurred_at":"2026-10-06T14:00:00Z","service":"nightly-backup","type":"job.started","resource":{"type":"job","id":"r"},"status":"running"}"#)
        XCTAssertTrue(store.receive(e, seen: false))
        XCTAssertFalse(store.receive(PipelineEvent.withNewId(e), seen: false))   // same event_id, new local id
        XCTAssertEqual(store.events.count, 1)
        let req = HTTP.Request(method: "POST", path: "/pipeline-events", headers: ["authorization": "Bearer " + store.pipelineToken],
                               body: Data(#"{"event_id":"e-1","occurred_at":"2026-10-06T14:00:00Z","type":"job.started","resource":{"id":"r"},"status":"running"}"#.utf8))
        let (code, body) = store.inbox.handle(req)
        XCTAssertEqual(code, 202)                                                  // the sender doesn't retry forever
        XCTAssertEqual(body["duplicate"] as? Bool, true)
    }

    func testSectionsGroupByServiceThenByWhatTheRunIs() throws {
        let events = [
            try ev(#"{"occurred_at":"2026-10-06T14:00:00Z","service":"nightly-backup","type":"job.started","resource":{"type":"job","id":"run-1"},"status":"running","source":"Box_One"}"#),
            try ev(#"{"occurred_at":"2026-10-06T14:01:00Z","service":"nightly-backup","type":"deploy.failed","resource":{"type":"deploy","id":"d-7"},"status":"failed","source":"Box_One"}"#),
            try ev(#"{"job_id":"legacy-1","timestamp":"2026-10-06T14:00:00Z","event":"job_failed","status":"failed","source":"build-box"}"#),
        ]
        let sections = PipelineSection.build([], PipelineJob.group(events), now: Date())
        XCTAssertEqual(sections.map(\.id), ["nightly-backup", "build-box"])        // both need attention; services first
        let svc = sections[0]
        XCTAssertTrue(svc.isService)
        XCTAssertEqual(svc.source, "Box_One")
        XCTAssertEqual(svc.kinds.map { PipelineSection.title($0.name) }, ["DEPLOYS", "JOBS"])
        XCTAssertFalse(sections[1].isService)                                      // no service field → grouped by sender
        XCTAssertEqual(PipelineSection.title(""), "RUNS")
    }

    func testOldSectionSettingsWithAnAPIAddressStillDecode() throws {
        let old = try JSONDecoder().decode(ServiceSettings.self, from: Data(#"{"label":"Ingest","apiBase":"https://box.example.ts.net"}"#.utf8))
        XCTAssertEqual(old.label, "Ingest")
    }
}
