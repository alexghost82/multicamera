import CameraCore
import Foundation
import XCTest
@testable import CameraWall

final class ACTAAnalyticsDraftDeletionTests: XCTestCase {
    private func zone(_ name: String, id: UUID = UUID()) -> RestrictedZoneRegion {
        .rectangle(id: id, name: name, x: 0.1, y: 0.1, width: 0.4, height: 0.4)
    }

    func testOverrideConfirmationRemovesOnlyReviewedCameraAndItsZones() throws {
        let camera = UUID(), other = UUID()
        var settings = VideoAnalyticsSettings.safeDefaults
        let selected = CameraAnalyticsOverride(cameraID: camera, restrictedZones: [zone("one"), zone("two")])
        let unaffected = CameraAnalyticsOverride(cameraID: other, restrictedZones: [zone("other")])
        settings.cameraOverrides = [camera: selected, other: unaffected]
        let review = try XCTUnwrap(ACTAAnalyticsDraftDeletion.Override(cameraID: camera, settings: settings))
        XCTAssertEqual(review.reviewed.restrictedZones.count, 2)
        XCTAssertEqual(settings.cameraOverrides[camera], selected)
        XCTAssertTrue(review.apply(to: &settings))
        XCTAssertNil(settings.cameraOverrides[camera])
        XCTAssertEqual(settings.cameraOverrides[other], unaffected)
        XCTAssertFalse(review.apply(to: &settings))
    }

    func testOverrideConfirmationRejectsChangedOrMismatchedDraft() throws {
        let camera = UUID()
        var settings = VideoAnalyticsSettings.safeDefaults
        settings.cameraOverrides[camera] = CameraAnalyticsOverride(cameraID: camera, restrictedZones: [zone("reviewed")])
        let review = try XCTUnwrap(ACTAAnalyticsDraftDeletion.Override(cameraID: camera, settings: settings))
        settings.cameraOverrides[camera]?.restrictedZones.append(zone("added"))
        let changed = settings
        XCTAssertFalse(review.apply(to: &settings))
        XCTAssertEqual(settings, changed)
        settings.cameraOverrides[camera] = CameraAnalyticsOverride(cameraID: UUID())
        XCTAssertNil(ACTAAnalyticsDraftDeletion.Override(cameraID: camera, settings: settings))
        XCTAssertNil(ACTAAnalyticsDraftDeletion.Override(cameraID: UUID(), settings: settings))
    }

    func testZoneConfirmationRejectsChangesAndDuplicateIDs() throws {
        let first = zone("first"), second = zone("second")
        var zones = [first, second]
        let review = try XCTUnwrap(ACTAAnalyticsDraftDeletion.Zone(id: first.id, zones: zones))
        zones[0].name = "changed"
        let changed = zones
        XCTAssertFalse(review.apply(to: &zones))
        XCTAssertEqual(zones, changed)
        zones = [first, second]
        XCTAssertTrue(review.apply(to: &zones))
        XCTAssertEqual(zones, [second])
        XCTAssertFalse(review.apply(to: &zones))
        XCTAssertNil(ACTAAnalyticsDraftDeletion.Zone(id: first.id, zones: [first, zone("duplicate", id: first.id)]))
        XCTAssertNil(ACTAAnalyticsDraftDeletion.Zone(id: UUID(), zones: zones))
    }
}
