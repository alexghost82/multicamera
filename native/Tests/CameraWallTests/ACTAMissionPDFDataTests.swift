import Foundation
import PDFKit
import XCTest
#if !ACTA_STANDALONE
@testable import CameraWall
#endif

final class ACTAMissionPDFDataTests: XCTestCase {
    func testMemoryPDFIncludesSyntheticRun() throws {
        let run = CameraMissionRun(
            missionID: UUID(), cameraID: UUID(), missionName: "Synthetic gate",
            status: .completed, occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            summary: "Synthetic observation"
        )
        let bytes = try CameraMissionRun.CameraMissionReport.renderPDFData(
            runs: [run], generatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let document = try XCTUnwrap(PDFDocument(data: bytes))
        XCTAssertGreaterThan(document.pageCount, 0)
        XCTAssertTrue(document.string?.contains("Synthetic gate") == true)
        XCTAssertTrue(document.string?.contains("Synthetic observation") == true)
    }
}
