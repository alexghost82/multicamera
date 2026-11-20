import Foundation
import XCTest
@testable import CameraWall

final class ACTALocalAnswerStreamTests: XCTestCase {
    private final class Previews: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(String, Int)] = []
        func append(_ text: String, _ revision: Int) {
            lock.lock(); defer { lock.unlock() }; values.append((text, revision))
        }
        func snapshot() -> [(String, Int)] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func testLateAndReorderedCallbacksCannotReplaceCurrentStep() {
        let previews = Previews()
        let sequence = ACTAStreamPreviewSequence { previews.append($0, $1) }
        let first = sequence.beginStep()
        first("newer", 2)
        first("older", 1)
        sequence.endStep()
        let second = sequence.beginStep()
        first("late from first step", 3)
        second("current", 1)
        sequence.endStep()
        second("late after completion", 2)

        let values = previews.snapshot()
        XCTAssertEqual(values.map(\.0), ["", "newer", "", "", "current", ""])
        XCTAssertEqual(values.map(\.1), Array(1...6))
    }

    func testClosedStreamIgnoresLateChunks() {
        let previews = Previews()
        let stream = ACTALocalAnswerStream { previews.append($0, $1) }
        stream.append(#"{"answerMarkdown":"first"#)
        stream.close()
        stream.append(#" late"}"#)
        XCTAssertEqual(previews.snapshot().map(\.0), ["first"])
    }

    func testPublishesPreviewBeforeJSONCompletes() {
        let emitted = expectation(description: "partial answer")
        let stream = ACTALocalAnswerStream { text, revision in
            XCTAssertEqual(text, "Camera one")
            XCTAssertEqual(revision, 1)
            emitted.fulfill()
        }
        stream.append(#"{"citedRecordIDs":["S1"],"answerMarkdown":""#)
        stream.append("Camera one")
        wait(for: [emitted], timeout: 1)
    }

    func testExtractsOnlyTopLevelAnswerFromPartialJSON() {
        let input = #"{"citedRecordIDs":["S1"],"nested":{"answerMarkdown":"not an answer"},"answerMarkdown":"Camera one"#
        XCTAssertEqual(ACTALocalAnswerStream.extract(Array(input.utf8)), "Camera one")
        XCTAssertNil(ACTALocalAnswerStream.extract(Array(#"{"tool_calls":[{"answerMarkdown":"do not display"}]"#.utf8)))
        XCTAssertNil(ACTALocalAnswerStream.extract(Array(#"{"answerMarkdown":{"text":"unsafe"}}"#.utf8)))
    }

    func testPartialEscapesAndIncompleteFieldsDoNotLeakJSON() {
        XCTAssertEqual(ACTALocalAnswerStream.extract(Array(#"{"answerMarkdown":"line\nnext \u04"#.utf8)), "line\nnext ")
        XCTAssertEqual(ACTALocalAnswerStream.extract(Array(#"{"answerMarkdown":"say \"yes\""}"#.utf8)), #"say "yes""#)
        XCTAssertNil(ACTALocalAnswerStream.extract(Array(#"{"citedRecordIDs":["S1"#.utf8)))
        XCTAssertNil(ACTALocalAnswerStream.extract(Array(#"not JSON {"answerMarkdown":"hidden"}"#.utf8)))
    }

    func testStreamsTerminalAnswerButNotOtherTools() {
        XCTAssertEqual(ACTALocalAnswerStream.extract(Array(#"{"tool_calls":[{"name":"present_answer","arguments":{"answerMarkdown":"Partial"#.utf8)), "Partial")
        XCTAssertNil(ACTALocalAnswerStream.extract(Array(#"{"tool_calls":[{"name":"camera.delete","arguments":{"answerMarkdown":"not an answer"#.utf8)))
        XCTAssertNil(ACTALocalAnswerStream.extract(Array(#"{"tool_calls":[{"name":"present_answer","arguments":{"answerMarkdown":"first"}},{"name":"camera.delete","arguments":{}}"#.utf8)))
    }

    func testClearsPreviewWhenAnotherToolAppears() {
        let emitted = expectation(description: "preview then clear")
        emitted.expectedFulfillmentCount = 2
        let stream = ACTALocalAnswerStream { text, revision in
            XCTAssertEqual(text, revision == 1 ? "First" : "")
            emitted.fulfill()
        }
        stream.append(#"{"tool_calls":[{"name":"present_answer","arguments":{"answerMarkdown":"First"}}"#)
        stream.append(#",{"name":"camera.delete","arguments":{}}"#)
        wait(for: [emitted], timeout: 1)
    }

    func testOversizedStreamDiscardsAndClearsActivePreview() {
        let previews = Previews()
        let stream = ACTALocalAnswerStream { previews.append($0, $1) }
        stream.append(#"{"answerMarkdown":"initial preview"#)
        stream.append(String(repeating: "x", count: 65_536))
        stream.append(#" late tail"}"#)
        XCTAssertEqual(previews.snapshot().map(\.0), ["initial preview", ""])
        XCTAssertEqual(previews.snapshot().map(\.1), [1, 2])
    }
}
