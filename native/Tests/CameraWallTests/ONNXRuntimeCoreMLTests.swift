import XCTest
import OnnxRuntimeBindings

final class ONNXRuntimeCoreMLTests: XCTestCase {
    func testCoreMLExecutionProviderIsAvailable() {
        XCTAssertTrue(ORTIsCoreMLExecutionProviderAvailable())
    }
}