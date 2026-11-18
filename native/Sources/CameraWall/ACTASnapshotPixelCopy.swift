import CoreVideo
import Darwin
import Foundation

/// Isolates the encoder from writes after this copy. Core Video's base-address
/// lock is not a mutual-exclusion contract with arbitrary producers: callers
/// must not assume it prevents writes during the copy itself.
enum ACTASnapshotPixelCopy {
    static func copy(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width <= 16_777_216 / height,
              format == kCVPixelFormatType_32BGRA
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
            throw ACTASnapshotActionError.invalidPreparation
        }
        var left = 0, right = 0, top = 0, bottom = 0
        CVPixelBufferGetExtendedPixels(source, &left, &right, &top, &bottom)
        guard left == 0, right == 0, top == 0, bottom == 0 else {
            throw ACTASnapshotActionError.invalidPreparation
        }
        var destination: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &destination) == kCVReturnSuccess,
              let destination else { throw ACTASnapshotActionError.invalidPreparation }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else {
            throw ACTASnapshotActionError.invalidPreparation
        }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else {
            throw ACTASnapshotActionError.invalidPreparation
        }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        if format == kCVPixelFormatType_32BGRA {
            guard !CVPixelBufferIsPlanar(source), !CVPixelBufferIsPlanar(destination) else {
                throw ACTASnapshotActionError.invalidPreparation
            }
            try copyRows(source: CVPixelBufferGetBaseAddress(source),
                         sourceStride: CVPixelBufferGetBytesPerRow(source),
                         destination: CVPixelBufferGetBaseAddress(destination),
                         destinationStride: CVPixelBufferGetBytesPerRow(destination),
                         rowBytes: width * 4, rows: height)
        } else {
            guard CVPixelBufferIsPlanar(source), CVPixelBufferIsPlanar(destination),
                  CVPixelBufferGetPlaneCount(source) == 2, CVPixelBufferGetPlaneCount(destination) == 2 else {
                throw ACTASnapshotActionError.invalidPreparation
            }
            for plane in 0..<2 {
                let planeWidth = CVPixelBufferGetWidthOfPlane(source, plane)
                let planeHeight = CVPixelBufferGetHeightOfPlane(source, plane)
                guard planeWidth > 0, planeWidth <= width, planeHeight > 0, planeHeight <= height,
                      planeWidth == CVPixelBufferGetWidthOfPlane(destination, plane),
                      planeHeight == CVPixelBufferGetHeightOfPlane(destination, plane) else {
                    throw ACTASnapshotActionError.invalidPreparation
                }
                try copyRows(source: CVPixelBufferGetBaseAddressOfPlane(source, plane),
                             sourceStride: CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                             destination: CVPixelBufferGetBaseAddressOfPlane(destination, plane),
                             destinationStride: CVPixelBufferGetBytesPerRowOfPlane(destination, plane),
                             rowBytes: planeWidth * (plane == 0 ? 1 : 2), rows: planeHeight)
            }
        }
        CVBufferPropagateAttachments(source, destination)
        return destination
    }

    private static func copyRows(source: UnsafeMutableRawPointer?, sourceStride: Int,
                                 destination: UnsafeMutableRawPointer?, destinationStride: Int,
                                 rowBytes: Int, rows: Int) throws {
        guard let source, let destination, rowBytes > 0, rows > 0,
              sourceStride >= rowBytes, destinationStride >= rowBytes,
              sourceStride <= Int.max / rows, destinationStride <= Int.max / rows else {
            throw ACTASnapshotActionError.invalidPreparation
        }
        for row in 0..<rows {
            let target = destination.advanced(by: row * destinationStride)
            memset(target, 0, destinationStride)
            memcpy(target, source.advanced(by: row * sourceStride), rowBytes)
        }
    }
}
