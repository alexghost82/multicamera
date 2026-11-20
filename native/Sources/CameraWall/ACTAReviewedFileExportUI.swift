import AppKit
import CameraCore
import CryptoKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

@MainActor
struct ACTAReviewedFileExportUI: ACTAReviewedFileSelector {
    let kind: ACTAReviewedFileKind
    let contents: @MainActor @Sendable () throws -> Data

    func selectAndReview() async throws -> ACTAReviewedFileSelection {
        try Task.checkCancellation()
        let bytes = Data([UInt8](try contents()))
        guard !bytes.isEmpty, bytes.count <= 1024 * 1024 else { throw Failure.invalidContent }
        let pdf: PDFDocument?
        switch kind {
        case .diagnostics:
            guard let text = String(data: bytes, encoding: .utf8), Data(text.utf8) == bytes,
                  (try? JSONSerialization.jsonObject(with: bytes)) != nil else { throw Failure.invalidContent }
            pdf = nil
        case .missionPDF:
            guard let document = PDFDocument(data: bytes), !document.isLocked, document.pageCount > 0 else {
                throw Failure.invalidContent
            }
            pdf = document
        case .cameraFrame:
            throw Failure.invalidContent
        }
        let language = AppLanguage.current
        let panel = NSSavePanel()
        InterfaceLocalization.configure(panel, title: kind == .diagnostics ? "Choose diagnostics destination" : "Choose mission PDF destination", language: language)
        panel.message = language.localized("Choose a new filename in a trusted directory. Existing files are never replaced.")
        panel.allowedContentTypes = [kind == .diagnostics ? .json : .pdf]
        panel.nameFieldStringValue = kind == .diagnostics ? "camerawall-diagnostics.json" : "camerawall-mission-report.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { throw CancellationError() }
        try Task.checkCancellation()
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let header = language.localized("Destination: %@", arguments: [Self.escaped(url.path)]) + "\n"
            + language.localized("Bytes: %@", arguments: [String(bytes.count)]) + "\nSHA-256: \(digest)\n\n"
        let text: String
        switch kind {
        case .diagnostics: text = header + language.localized("Complete JSON (escaped):") + "\n" + Self.escaped(String(decoding: bytes, as: UTF8.self))
        case .missionPDF: text = header + language.localized("Complete PDF bytes (hexadecimal):") + "\n" + Self.hex(bytes)
        case .cameraFrame: throw Failure.invalidContent
        }
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 470, height: 430))
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.textContainer?.containerSize = NSSize(width: 470, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = text
        let scroll = NSScrollView(frame: textView.frame)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = textView

        let alert = NSAlert()
        alert.messageText = language.localized(kind == .diagnostics ? "Review complete diagnostics" : "Review the complete PDF")
        alert.informativeText = kind == .diagnostics
            ? language.localized("All non-ASCII and control characters are escaped. No file has been written.")
            : language.localized("Review the rendered pages and the complete bytes. No file has been written.")
        alert.addButton(withTitle: language.localized("I reviewed the complete content"))
        alert.addButton(withTitle: language.localized("Cancel"))
        if let pdf {
            let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 940, height: 430))
            split.isVertical = true
            let pdfView = PDFView(frame: NSRect(x: 0, y: 0, width: 470, height: 430))
            pdfView.document = pdf
            pdfView.displayMode = .singlePageContinuous
            pdfView.autoScales = true
            split.addArrangedSubview(pdfView)
            split.addArrangedSubview(scroll)
            alert.accessoryView = split
        } else {
            alert.accessoryView = scroll
        }
        guard alert.runModal() == .alertFirstButtonReturn else { throw CancellationError() }
        try Task.checkCancellation()
        return .init(kind: kind, bytes: bytes, destination: url)
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

    nonisolated static func hex(_ bytes: Data) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var result = [UInt8]()
        result.reserveCapacity(bytes.count * 3)
        for (index, byte) in bytes.enumerated() {
            result.append(digits[Int(byte >> 4)])
            result.append(digits[Int(byte & 15)])
            result.append(index % 16 == 15 ? 10 : 32)
        }
        return String(decoding: result, as: UTF8.self)
    }

    private enum Failure: Error { case invalidContent }
}

@MainActor
enum ACTAOperationalExportUI {
    private static var inProgress = false

    static func start(_ action: ACTAReviewedFileExportAction) {
        guard !inProgress else { return }
        inProgress = true
        Task { @MainActor in
            defer { inProgress = false }
            do {
                let context = ACTAActionContext(threadID: "local-file-export")
                let prepared = try await action.prepareConfirmation(parameters: [:], context: context)
                let language = AppLanguage.current
                let alert = NSAlert()
                alert.messageText = language.localized("Create reviewed file?")
                alert.informativeText = language.localizedMessage(prepared.reviewSummary)
                alert.addButton(withTitle: language.localized("Create new file"))
                alert.addButton(withTitle: language.localized("Cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                let confirmed = ACTAActionContext(threadID: context.threadID, isConfirmed: true)
                let result = try await action.executeConfirmed(parameters: [:], context: confirmed, snapshot: prepared.snapshot)
                guard result.success, try await action.verify(parameters: [:], context: confirmed) else {
                    showFailure()
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                showFailure()
            }
        }
    }

    private static func showFailure() {
        let alert = NSAlert()
        let language = AppLanguage.current
        alert.messageText = language.localized("Export failed")
        alert.informativeText = language.localized("The destination may already exist or the result may be uncertain. Check it before retrying.")
        alert.runModal()
    }
}
