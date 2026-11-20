import Foundation

@MainActor
enum ACTAOperationalExports {
    static func diagnostics(model: WallModel) -> ACTAReviewedFileExportAction {
        ACTAReviewedFileExportAction(kind: .diagnostics, selector: ACTAReviewedFileExportUI(
            kind: .diagnostics, contents: { [weak model] in
                guard let model else { throw Failure.unavailable }
                return try model.diagnosticsData()
            }))
    }

    static func missionPDF(model: WallModel) -> ACTAReviewedFileExportAction {
        ACTAReviewedFileExportAction(kind: .missionPDF, selector: ACTAReviewedFileExportUI(
            kind: .missionPDF, contents: { [weak model] in
                guard let model else { throw Failure.unavailable }
                return try CameraMissionRun.CameraMissionReport.renderPDFData(runs: model.cameraMissionRuns)
            }))
    }

    private enum Failure: Error { case unavailable }
}
