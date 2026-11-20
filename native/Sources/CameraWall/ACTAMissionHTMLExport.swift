import CameraCore
import Foundation

/// The caller supplies a trusted, in-memory mission snapshot, never model arguments.
enum ACTAMissionHTMLExport {
    @MainActor
    static func make(runs: [CameraMissionRun]) -> ACTAReviewedHTMLExportAction {
        let bytes = render(runs: runs)
        return ACTAReviewedHTMLExportAction(
            selector: ACTAReviewedHTMLExportUI(kind: "mission", report: bytes),
            publisher: ACTAMissionHTMLPublisher())
    }

    static func render(runs: [CameraMissionRun]) -> Data {
        Data(CameraMissionRun.CameraMissionReport.renderHTML(runs: runs).utf8)
    }
}

/// The selected directory must not be concurrently manipulated by untrusted writers.
struct ACTAMissionHTMLPublisher: ACTAReviewedHTMLPublication {
    func publish(_ selection: ACTAReviewedHTMLSelection, threadID: String) async throws {
        guard selection.kind == "mission" else { throw Failure.invalidReport }
        try ACTACreateOnlyExport.publish(selection.bytes, to: selection.destination)
    }

    func verify(_ selection: ACTAReviewedHTMLSelection, threadID: String) async throws -> Bool {
        guard selection.kind == "mission" else { return false }
        return try ACTACreateOnlyExport.verify(selection.bytes, at: selection.destination)
    }

    private enum Failure: Error { case invalidReport }
}
