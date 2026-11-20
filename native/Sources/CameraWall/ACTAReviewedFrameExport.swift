import AppKit
import CameraCore
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum ACTAReviewedFrameExport {
    static func make(cameraID: UUID, frames: any ACTASnapshotFrameProvider) -> ACTAReviewedFileExportAction {
        ACTAReviewedFileExportAction(kind: .cameraFrame,
            selector: ACTAReviewedFrameExportSelector(cameraID: cameraID, frames: frames))
    }
}

/// Trusted operator UI selects the destination and reviews the frozen JPEG.
@MainActor
struct ACTAReviewedFrameExportSelector: ACTAReviewedFileSelector {
    let cameraID: UUID
    let frames: any ACTASnapshotFrameProvider

    func selectAndReview() async throws -> ACTAReviewedFileSelection {
        try await selectAndReviewFrame().selection
    }

    func selectAndReviewFrame() async throws -> ACTAReviewedCameraFrame {
        try Task.checkCancellation()
        let frame = try await frames.captureFreshFrame(cameraID: cameraID)
        guard frame.cameraID == cameraID else { throw Failure.invalidFrame }
        let preview = try ACTAFrameExportPreview(jpeg: frame.jpeg)
        try Task.checkCancellation()
        let language = AppLanguage.current
        let panel = NSSavePanel()
        InterfaceLocalization.configure(panel, title: "Choose camera frame destination", language: language)
        panel.message = language.localized("Choose a new filename in a trusted directory. Existing files are never replaced.")
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = "camera-frame.jpg"
        guard panel.runModal() == .OK, let url = panel.url else { throw CancellationError() }
        try Task.checkCancellation()

        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 470, height: 430))
        imageView.image = NSImage(cgImage: preview.image, size: .zero)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 470, height: 430))
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.textContainer?.containerSize = NSSize(width: 470, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = language.localized("Camera: %@", arguments: [cameraID.uuidString]) + "\n"
            + language.localized("Destination: %@", arguments: [ACTAReviewedFileExportUI.escaped(url.path)]) + "\n"
            + language.localized("Bytes: %@", arguments: [String(preview.bytes.count)]) + "\nSHA-256: \(preview.digest)\n"
            + language.localized("The image may now be stale. Review the complete image and bytes.") + "\n\n"
            + language.localized("Complete JPEG bytes (hexadecimal):") + "\n\(ACTAReviewedFileExportUI.hex(preview.bytes))"
        let scroll = NSScrollView(frame: textView.frame)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = textView
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 940, height: 430))
        split.isVertical = true
        split.addArrangedSubview(imageView)
        split.addArrangedSubview(scroll)
        let alert = NSAlert()
        alert.messageText = language.localized("Review the complete camera frame")
        alert.informativeText = language.localized("This is the exact JPEG that would be saved. It may no longer be current. No file has been written.")
        alert.addButton(withTitle: language.localized("I reviewed the image and complete bytes"))
        alert.addButton(withTitle: language.localized("Cancel"))
        alert.accessoryView = split
        guard alert.runModal() == .alertFirstButtonReturn else { throw CancellationError() }
        try Task.checkCancellation()
        return .init(frame: frame, selection: .init(kind: .cameraFrame, bytes: preview.bytes, destination: url))
    }

    private enum Failure: Error { case invalidFrame }
}

struct ACTAReviewedCameraFrame: Sendable {
    let frame: ACTASnapshotFrame
    let selection: ACTAReviewedFileSelection
}

struct ACTAFrameExportPreview {
    let bytes: Data
    let image: CGImage
    let digest: String

    init(jpeg: Data) throws {
        let bytes = Data([UInt8](jpeg))
        guard !bytes.isEmpty, bytes.count <= 1024 * 1024,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192,
              width <= 16_777_216 / height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == width, image.height == height else { throw Failure.invalidJPEG }
        self.bytes = bytes
        self.image = image
        self.digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private enum Failure: Error { case invalidJPEG }
}
