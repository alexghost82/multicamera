import XCTest
@testable import CameraCore

final class CrossCameraVisitsTests: XCTestCase {
    func testVisitsUseOnlyAcceptedSidecarAssignmentsAndSortChronologically() {
        let identityID = UUID()
        let early = makeRecord(camera: "North", time: 10)
        let late = makeRecord(camera: "South", time: 20)
        let unrelated = makeRecord(camera: "Garage", time: 30)

        let groups = CrossCameraVisitIndex.groups(
            records: [late, unrelated, early],
            identityByTrackID: [early.trackID: identityID, late.trackID: identityID]
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].identityID, identityID)
        XCTAssertEqual(groups[0].cameraCount, 2)
        XCTAssertEqual(groups[0].visits.map(\.trackID), [early.trackID, late.trackID])
    }

    func testRouteMergesOverlappingVisitsButPreservesSeparateVisits() {
        let cameraID = UUID()
        let first = makeRecord(camera: "North", time: 10, end: 20, cameraID: cameraID)
        let overlap = makeRecord(camera: "North", time: 15, end: 25, cameraID: cameraID)
        let returnVisit = makeRecord(camera: "North", time: 30, end: 35, cameraID: cameraID)
        let group = CrossCameraVisitGroup(identityID: UUID(), visits: [returnVisit, overlap, first])

        XCTAssertEqual(group.route.count, 2)
        XCTAssertEqual(group.route[0].trackIDs, [first.trackID, overlap.trackID])
        XCTAssertEqual(group.route[0].lastSeen, Date(timeIntervalSince1970: 25))
        XCTAssertEqual(group.route[1].trackIDs, [returnVisit.trackID])
    }

    func testPresenceFiltersMustMatchTheSameVisit() {
        let north = makeRecord(camera: "North", time: 10, end: 20)
        let south = makeRecord(camera: "South", time: 30, end: 40)
        let group = CrossCameraVisitGroup(identityID: UUID(), visits: [north, south])
        let duringNorth = DateInterval(start: Date(timeIntervalSince1970: 15), duration: 0)
        XCTAssertTrue(CrossCameraPresenceQuery(cameraIDs: [north.cameraID], interval: duringNorth).matches(group))
        XCTAssertFalse(CrossCameraPresenceQuery(cameraIDs: [south.cameraID], interval: duringNorth).matches(group))
        XCTAssertFalse(CrossCameraPresenceQuery(objectClass: "car").matches(group))
        XCTAssertTrue(CrossCameraPresenceQuery(objectClass: "PERSON").matches(group))
    }

    func testCameraSequenceRequiresChronologicalNonoverlappingEvidence() {
        let north = makeRecord(camera: "North", time: 10, end: 25)
        let south = makeRecord(camera: "South", time: 20, end: 30)
        let group = CrossCameraVisitGroup(identityID: UUID(), visits: [north, south])
        XCTAssertFalse(CrossCameraPresenceQuery(cameraSequence: [north.cameraID, south.cameraID]).matches(group))
        XCTAssertFalse(CrossCameraPresenceQuery(cameraSequence: [south.cameraID, north.cameraID]).matches(group))

        let later = makeRecord(camera: "South", time: 40, end: 50, cameraID: south.cameraID)
        let extended = CrossCameraVisitGroup(identityID: group.identityID, visits: [north, south, later])
        XCTAssertTrue(CrossCameraPresenceQuery(cameraSequence: [north.cameraID, south.cameraID]).matches(extended))
        XCTAssertFalse(CrossCameraPresenceQuery(cameraSequence: [north.cameraID, north.cameraID]).matches(extended))
    }

    func testInvalidIntervalsAndConfidenceDoNotProduceMatches() {
        let invalid = makeRecord(camera: "North", time: 20, end: 10)
        let group = CrossCameraVisitGroup(identityID: UUID(), visits: [invalid])
        XCTAssertTrue(group.route.isEmpty)
        XCTAssertFalse(CrossCameraPresenceQuery().matches(group))
        XCTAssertFalse(CrossCameraPresenceQuery(minimumAttributeConfidence: .nan).matches(group))
        XCTAssertTrue(group.attributeFacets(minimumConfidence: -1).isEmpty)
    }

    func testSequenceCanUseLaterShorterVisitInsteadOfFirstLongVisit() {
        let north = makeRecord(camera: "North", time: 10, end: 100)
        let south = makeRecord(camera: "South", time: 20, end: 30)
        let northAgain = makeRecord(camera: "North", time: 40, end: 50, cameraID: north.cameraID)
        let southAgain = makeRecord(camera: "South", time: 60, end: 70, cameraID: south.cameraID)
        let group = CrossCameraVisitGroup(identityID: UUID(), visits: [north, south, northAgain, southAgain])
        XCTAssertTrue(CrossCameraPresenceQuery(cameraSequence: [north.cameraID, south.cameraID]).matches(group))
    }

    func testFacetsKeepConflictingEvidenceAndExcludeUnknownAndWeakAttributes() {
        let red = makeRecord(camera: "North", time: 10, attributes: ["color": ("red", 0.9), "hat": ("unknown", 1)])
        let blue = makeRecord(camera: "South", time: 20, attributes: ["color": ("blue", 0.8), "hat": ("cap", 0.2)])
        let group = CrossCameraVisitGroup(identityID: UUID(), visits: [red, blue])
        let facets = group.attributeFacets()
        XCTAssertEqual(facets.map(\.name), ["color", "color"])
        XCTAssertEqual(facets.map(\.value), ["blue", "red"])
        XCTAssertEqual(facets[0].trackIDs, [blue.trackID])
        XCTAssertEqual(facets[1].trackIDs, [red.trackID])
        XCTAssertTrue(CrossCameraPresenceQuery(attributes: ["color": " RED "]).matches(group))
        XCTAssertFalse(CrossCameraPresenceQuery(attributes: ["hat": "cap"]).matches(group))
        XCTAssertFalse(CrossCameraPresenceQuery(attributes: ["hat": "unknown"]).matches(group))
        XCTAssertFalse(CrossCameraPresenceQuery(cameraIDs: [blue.cameraID], attributes: ["color": "red"]).matches(group))
    }

    private func makeRecord(
        camera: String, time: TimeInterval, end: TimeInterval? = nil, cameraID: UUID = UUID(),
        attributes: [String: (String, Double)] = [:]
    ) -> TrackedObjectRecord {
        let description = attributes.isEmpty ? nil : TrackedObjectDescription(
            summary: "Visible evidence", attributes: attributes.mapValues {
                TrackedAttribute(value: $0.0, confidence: $0.1, evidence: "Local fixture")
            }, overallConfidence: 0.9
        )
        return TrackedObjectRecord(
            trackID: UUID(), cameraID: cameraID, cameraName: camera, label: "person",
            firstSeen: Date(timeIntervalSince1970: time), lastSeen: Date(timeIntervalSince1970: end ?? time),
            observationCount: 1, bestConfidence: 0.9, box: .zero,
            cropPath: nil, cutoutPath: nil, operatorGroupID: nil, description: description, describedAt: nil
        )
    }
}