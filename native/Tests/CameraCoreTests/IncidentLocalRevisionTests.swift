import Foundation
import XCTest
@testable import CameraCore

private final class IncidentMemory {
    var incidents: [SafetyIncident]
    var audit: [OperatorAuditEntry] = []
    var failWrite = false
    struct Failure: Error {}

    init(_ incidents: [SafetyIncident]) { self.incidents = incidents }
    func manager() -> UnifiedIncidentManager {
        let audit = OperatorAuditLog(url: URL(string: "memory://audit")!,
            load: { self.audit }, save: { self.audit = $0 })
        return UnifiedIncidentManager(storageURL: URL(string: "memory://incidents")!,
            auditLog: audit, load: { self.incidents }, save: {
                if self.failWrite { throw Failure() }
                self.incidents = $0
            })
    }
}

final class IncidentLocalRevisionTests: XCTestCase {
    private func incident() -> SafetyIncident {
        SafetyIncident(cameraID: UUID(), cameraName: "synthetic", trackIDs: [],
            type: .fallConfirmed, severity: .high, confidence: 1,
            title: "synthetic", explanation: "synthetic", detectorSource: "synthetic")
    }

    func testGUIWriterChangesRevisionEvenAfterABA() throws {
        let original = incident()
        let memory = IncidentMemory([original])
        let manager = memory.manager()
        let before = try XCTUnwrap(manager.localRevisionSnapshot(incidentID: original.id))
        _ = manager.transitionStatus(incidentID: original.id, to: .acknowledged)
        let middle = try XCTUnwrap(manager.localRevisionSnapshot(incidentID: original.id))
        _ = manager.transitionStatus(incidentID: original.id, to: .active)
        let after = try XCTUnwrap(manager.localRevisionSnapshot(incidentID: original.id))
        XCTAssertNotEqual(before.revision, middle.revision)
        XCTAssertNotEqual(before.revision, after.revision)
        XCTAssertNotEqual(middle.revision, after.revision)
        XCTAssertEqual(before.incident.status, after.incident.status)
        XCTAssertEqual(memory.incidents.first?.status, .active)
        XCTAssertEqual(memory.audit.count, 2)
    }

    func testNoteAndEvidenceWritersInvalidateSnapshots() throws {
        let item = incident()
        let manager = IncidentMemory([item]).manager()
        let before = try XCTUnwrap(manager.localRevisionSnapshot(incidentID: item.id))
        manager.updateOperatorNote(incidentID: item.id, note: "synthetic")
        let note = try XCTUnwrap(manager.localRevisionSnapshot(incidentID: item.id))
        manager.clearEvidenceReferences(incidentID: item.id)
        let after = try XCTUnwrap(manager.localRevisionSnapshot(incidentID: item.id))
        XCTAssertNotEqual(before.revision, note.revision)
        XCTAssertNotEqual(note.revision, after.revision)
    }

    func testInvalidStorageDuplicateIdentityAndInstancesFailClosedOrDiffer() throws {
        let item = incident()
        let memory = IncidentMemory([item, item])
        XCTAssertNil(memory.manager().localRevisionSnapshot(incidentID: item.id))
        memory.incidents = [item]
        let first = memory.manager(), second = memory.manager()
        XCTAssertNotEqual(try XCTUnwrap(first.localRevisionSnapshot(incidentID: item.id)).revision,
                          try XCTUnwrap(second.localRevisionSnapshot(incidentID: item.id)).revision)
        memory.failWrite = true
        first.clearEvidenceReferences(incidentID: item.id)
        XCTAssertNil(first.localRevisionSnapshot(incidentID: item.id))
    }

    func testExternalStorageChangesAreNotCoveredByLocalRevision() throws {
        let item = incident()
        let memory = IncidentMemory([item])
        let manager = memory.manager()
        let before = try XCTUnwrap(manager.localRevisionSnapshot(incidentID: item.id))
        memory.incidents[0].status = .resolved
        let after = try XCTUnwrap(manager.localRevisionSnapshot(incidentID: item.id))
        XCTAssertEqual(before.revision, after.revision)
        XCTAssertEqual(after.incident.status, .active)
        XCTAssertEqual(memory.incidents[0].status, .resolved)
    }
}
