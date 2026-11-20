import XCTest
@testable import CameraWall

@MainActor
final class ACTACameraWriterGateTests: XCTestCase {
    func testWriteRejectsStaleRevisionIncludingABA() throws {
        let gate = ACTACameraWriterGate()
        var value = false
        let old = try gate.capture { value }
        try gate.write { value = true }
        try gate.write { value = false }
        XCTAssertFalse(value)
        XCTAssertThrowsError(try gate.writeIfCurrent(old.revision) { value = true })
        XCTAssertFalse(value)
        let current = try gate.capture { value }
        try gate.writeIfCurrent(current.revision) { value = true }
        XCTAssertTrue(value)
    }

    func testSynchronousObserverCannotReadOrWriteDuringTransaction() throws {
        let gate = ACTACameraWriterGate()
        var value = 0
        try gate.write {
            XCTAssertThrowsError(try gate.capture { value })
            XCTAssertThrowsError(try gate.write { value = 2 })
            value = 1
        }
        XCTAssertEqual(try gate.capture { value }.value, 1)
    }

    func testFailedWriteInvalidatesAndGateReopens() throws {
        struct Failure: Error {}
        let gate = ACTACameraWriterGate()
        var value = 0
        let old = try gate.capture { value }
        XCTAssertThrowsError(try gate.write {
            value = 1
            throw Failure()
        })
        XCTAssertThrowsError(try gate.writeIfCurrent(old.revision) { value = 2 })
        XCTAssertEqual(try gate.capture { value }.value, 1)
    }

    func testReadRejectsSynchronousInterveningWrite() throws {
        let gate = ACTACameraWriterGate()
        var value = 0
        XCTAssertThrowsError(try gate.capture {
            try gate.write { value = 1 }
            return value
        })
        XCTAssertEqual(try gate.capture { value }.value, 1)
    }
}
