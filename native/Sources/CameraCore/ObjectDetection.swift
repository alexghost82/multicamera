import Foundation
import CoreGraphics

public struct DetectedObject: Identifiable, Equatable, Sendable {
    public let id: Int
    public let trackID: UUID?
    public let label: String
    public let confidence: Double
    public let box: CGRect

    public init(id: Int, label: String, confidence: Double, box: CGRect, trackID: UUID? = nil) {
        self.id = id
        self.trackID = trackID
        self.label = label
        self.confidence = confidence
        self.box = box
    }

    public func assigning(trackID: UUID) -> DetectedObject {
        DetectedObject(id: id, label: label, confidence: confidence, box: box, trackID: trackID)
    }
}

public enum DetectionGeometry {
    public static func videoRect(image: CGSize, viewport: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0 else { return .zero }
        let scale = min(viewport.width / image.width, viewport.height / image.height)
        let width = image.width * scale
        let height = image.height * scale
        return CGRect(x: (viewport.width - width) / 2, y: (viewport.height - height) / 2, width: width, height: height)
    }

    public static func displayRect(box: CGRect, image: CGSize, viewport: CGSize) -> CGRect {
        let video = videoRect(image: image, viewport: viewport)
        let clipped = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull else { return .zero }
        return CGRect(x: video.minX + clipped.minX * video.width,
                      y: video.minY + (1 - clipped.maxY) * video.height,
                      width: clipped.width * video.width, height: clipped.height * video.height)
    }
}