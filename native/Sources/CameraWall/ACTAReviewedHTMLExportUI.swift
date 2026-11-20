import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Call only from trusted host code with an already authorized, frozen report.
/// This component selects and previews; it never creates or writes a file.
@MainActor
struct ACTAReviewedHTMLExportUI: ACTAReviewedHTMLSelectionProvider {
    let kind: String
    let report: Data

    func selectAndReview() async throws -> ACTAReviewedHTMLSelection {
        let bytes = Data([UInt8](report))
        guard ["mission", "operations"].contains(kind), !bytes.isEmpty, bytes.count <= 1024 * 1024,
              let text = String(data: bytes, encoding: .utf8), Data(text.utf8) == bytes else {
            throw Failure.invalidContent
        }
        try Task.checkCancellation()
        let panel = NSSavePanel()
        panel.title = "Choose HTML report destination"
        panel.message = "Choose a new filename in a trusted directory. Existing files are never replaced."
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "report.html"
        guard panel.runModal() == .OK, let url = panel.url else { throw CancellationError() }
        try Task.checkCancellation()
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let alert = NSAlert()
        alert.messageText = "Review the complete HTML report"
        alert.informativeText = "The text below escapes every non-ASCII scalar and control character. Review the content and destination; no file is written yet."
        alert.addButton(withTitle: "I reviewed the complete report")
        alert.addButton(withTitle: "Cancel")
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 360))
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.isVerticallyResizable = true
        view.textContainer?.containerSize = NSSize(width: 720, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        view.string = "Kind: \(kind)\nDestination: \(Self.escaped(url.path))\nBytes: \(bytes.count)\nSHA-256: \(digest)\n\nComplete HTML (escaped):\n\(Self.escaped(text))"
        let scroll = NSScrollView(frame: view.frame)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = view
        alert.accessoryView = scroll
        guard alert.runModal() == .alertFirstButtonReturn else { throw CancellationError() }
        try Task.checkCancellation()
        return ACTAReviewedHTMLSelection(kind: kind, bytes: bytes, destination: url)
    }

    nonisolated static func escaped(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A: result += "\\u{A}\n"
            case 0x5C: result += "\\\\"
            case 0x20...0x7E: result.unicodeScalars.append(scalar)
            default: result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            }
        }
        return result
    }

    private enum Failure: Error { case invalidContent }
}
