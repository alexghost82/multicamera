import AppKit
import Foundation
import UniformTypeIdentifiers

/// Destination selection only. This does not authorize report contents or write.
@MainActor
enum ACTAExportDestinationUI {
    enum Kind {
        case html, diagnostics, missionPDF, cameraFrame

        var type: UTType {
            switch self {
            case .html: return .html
            case .diagnostics: return .json
            case .missionPDF: return .pdf
            case .cameraFrame: return .jpeg
            }
        }

        var suggestedName: String {
            switch self {
            case .html: return "report.html"
            case .diagnostics: return "diagnostics.json"
            case .missionPDF: return "mission-report.pdf"
            case .cameraFrame: return "camera-frame.jpg"
            }
        }
    }

    static func select(_ kind: Kind) throws -> URL {
        try Task.checkCancellation()
        let panel = NSSavePanel()
        panel.title = "Choose a new export file"
        panel.message = "Existing files are never replaced. Choose a new name."
        panel.allowedContentTypes = [kind.type]
        panel.nameFieldStringValue = kind.suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { throw CancellationError() }
        try Task.checkCancellation()
        return url
    }
}
