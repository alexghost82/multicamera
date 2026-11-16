import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 1. Capture Scheduler (workers/capture.py)

public enum ACTACaptureReason: String, Codable, Sendable {
    case firstAppearance = "first_appearance"
    case bootstrapSecond = "bootstrap_second"
    case movement = "movement"
}

public struct ACTACaptureDecision: Equatable, Sendable {
    public let shouldCapture: Bool
    public let reason: ACTACaptureReason?
    public let inheritedFromTrackID: UUID?

    public init(shouldCapture: Bool, reason: ACTACaptureReason? = nil, inheritedFromTrackID: UUID? = nil) {
        self.shouldCapture = shouldCapture
        self.reason = reason
        self.inheritedFromTrackID = inheritedFromTrackID
    }
}

public final class ACTACaptureScheduler: @unchecked Sendable {
    public struct Config: Codable, Equatable, Sendable {
        public var bootstrapSeconds: TimeInterval = 1.0
        public var intervalSeconds: TimeInterval = 4.0
        public var movementFraction: CGFloat = 0.35
        public var inheritMaxAge: TimeInterval = 2.0
        public var inheritMinIoU: CGFloat = 0.50
        public var staleTrackTTL: TimeInterval = 30.0

        public init() {}
    }

    private struct TrackState {
        var trackID: UUID
        var label: String
        var firstSeen: TimeInterval
        var lastSeen: TimeInterval
        var lastCaptureAt: TimeInterval
        var lastCaptureBox: CGRect
        var lastObservedBox: CGRect
        var captureCount: Int
    }

    public var config: Config
    private let lock = NSLock()
    private var statesByCamera: [UUID: [UUID: TrackState]] = [:]

    public init(config: Config = Config()) {
        self.config = config
    }

    public func evaluate(
        cameraID: UUID,
        trackID: UUID,
        label: String,
        box: CGRect,
        now: TimeInterval
    ) -> ACTACaptureDecision {
        guard now.isFinite, box.width > 0, box.height > 0 else {
            return ACTACaptureDecision(shouldCapture: false)
        }
        lock.lock()
        defer { lock.unlock() }

        pruneLocked(cameraID: cameraID, now: now)
        var cameraStates = statesByCamera[cameraID, default: [:]]

        if var existing = cameraStates[trackID] {
            existing.lastSeen = now
            existing.lastObservedBox = box
            if existing.captureCount == 1 {
                if now - existing.firstSeen >= config.bootstrapSeconds {
                    existing.captureCount += 1
                    existing.lastCaptureAt = now
                    existing.lastCaptureBox = box
                    cameraStates[trackID] = existing
                    statesByCamera[cameraID] = cameraStates
                    return ACTACaptureDecision(shouldCapture: true, reason: .bootstrapSecond)
                }
                cameraStates[trackID] = existing
                statesByCamera[cameraID] = cameraStates
                return ACTACaptureDecision(shouldCapture: false)
            }
            let elapsed = now - existing.lastCaptureAt
            let diag = hypot(box.width, box.height)
            let disp = hypot(box.midX - existing.lastCaptureBox.midX, box.midY - existing.lastCaptureBox.midY)
            if elapsed >= config.intervalSeconds, diag > 0, disp >= config.movementFraction * diag {
                existing.captureCount += 1
                existing.lastCaptureAt = now
                existing.lastCaptureBox = box
                cameraStates[trackID] = existing
                statesByCamera[cameraID] = cameraStates
                return ACTACaptureDecision(shouldCapture: true, reason: .movement)
            }
            cameraStates[trackID] = existing
            statesByCamera[cameraID] = cameraStates
            return ACTACaptureDecision(shouldCapture: false)
        }

        // Check if this new trackID is an ID-switch continuation of a recently seen track
        if let inherited = tryInheritLocked(cameraStates: &cameraStates, newTrackID: trackID, label: label, box: box, now: now) {
            statesByCamera[cameraID] = cameraStates
            return inherited
        }

        let initial = TrackState(
            trackID: trackID,
            label: label,
            firstSeen: now,
            lastSeen: now,
            lastCaptureAt: now,
            lastCaptureBox: box,
            lastObservedBox: box,
            captureCount: 1
        )
        cameraStates[trackID] = initial
        statesByCamera[cameraID] = cameraStates
        return ACTACaptureDecision(shouldCapture: true, reason: .firstAppearance)
    }

    public func reset(cameraID: UUID? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let cameraID {
            statesByCamera.removeValue(forKey: cameraID)
        } else {
            statesByCamera.removeAll()
        }
    }

    private func tryInheritLocked(
        cameraStates: inout [UUID: TrackState],
        newTrackID: UUID,
        label: String,
        box: CGRect,
        now: TimeInterval
    ) -> ACTACaptureDecision? {
        var bestID: UUID?
        var bestIoU: CGFloat = 0
        for (candidateID, state) in cameraStates where candidateID != newTrackID && state.label == label {
            let age = now - state.lastSeen
            guard age >= 0, age <= config.inheritMaxAge else { continue }
            let iou = Self.iou(box, state.lastObservedBox)
            if iou >= config.inheritMinIoU && iou > bestIoU {
                bestIoU = iou
                bestID = candidateID
            }
        }
        guard let oldID = bestID, var inherited = cameraStates.removeValue(forKey: oldID) else {
            return nil
        }
        inherited.trackID = newTrackID
        inherited.lastSeen = now
        inherited.lastObservedBox = box
        cameraStates[newTrackID] = inherited
        return ACTACaptureDecision(shouldCapture: false, reason: nil, inheritedFromTrackID: oldID)
    }

    private func pruneLocked(cameraID: UUID, now: TimeInterval) {
        guard var cameraStates = statesByCamera[cameraID] else { return }
        cameraStates = cameraStates.filter { _, state in
            now - state.lastSeen <= config.staleTrackTTL
        }
        statesByCamera[cameraID] = cameraStates
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, !inter.isEmpty else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }
}

// MARK: - 2. Rolling Best-K Crop Window (identity/window.py)

public struct ACTACropWindow: Sendable {
    public struct Entry: Equatable, Sendable {
        public let cropID: UUID
        public let quality: Double
        public let timestamp: TimeInterval
    }

    public var windowSeconds: TimeInterval = 15.0
    public var topK: Int = 4
    public var improvementRatio: Double = 1.03
    private var entries: [Entry] = []

    public init(windowSeconds: TimeInterval = 15.0, topK: Int = 4, improvementRatio: Double = 1.03) {
        self.windowSeconds = windowSeconds
        self.topK = topK
        self.improvementRatio = improvementRatio
    }

    public mutating func shouldAccept(cropID: UUID = UUID(), quality: Double, now: TimeInterval) -> Bool {
        guard quality.isFinite, quality > 0, now.isFinite else { return false }
        entries.removeAll { now - $0.timestamp > windowSeconds }
        if entries.count < topK {
            entries.append(Entry(cropID: cropID, quality: quality, timestamp: now))
            entries.sort { $0.quality > $1.quality }
            return true
        }
        guard let worst = entries.last else { return true }
        if quality >= worst.quality * improvementRatio {
            entries.removeLast()
            entries.append(Entry(cropID: cropID, quality: quality, timestamp: now))
            entries.sort { $0.quality > $1.quality }
            return true
        }
        return false
    }
}

// MARK: - 3. Crop Quality Scorer & Matte Refiner (vision/cropper.py, vision/refiner.py)

public struct ACTACropQualityMetrics: Codable, Equatable, Sendable {
    public let quality: Double
    public let confidenceScore: Double
    public let blurScore: Double
    public let sizeScore: Double
    public let areaRatioScore: Double
    public let occlusionScore: Double
    public let truncationScore: Double
    public let hasMask: Bool
}

public enum ACTACropQualityScorer {
    public static let minCropQuality: Double = 0.28
    public static let aiMinCropQuality: Double = 0.42

    /// Exact GHOST ONWAY quality formula:
    /// Q = (0.28*conf + 0.22*blur + 0.20*size + 0.12*area + 0.10*(1-occ) + 0.08*(1-trunc)) * (hasMask ? 1.0 : 0.7)
    public static func evaluate(
        rgbaPixels: [UInt8],
        width: Int,
        height: Int,
        detectionConfidence: Double,
        normalizedBox: CGRect,
        siblingBoxes: [CGRect] = [],
        isVehicle: Bool = false,
        hasMask: Bool
    ) -> ACTACropQualityMetrics {
        let confScore = clamp(detectionConfidence, 0, 1)
        let blurRaw = laplacianVariance(rgbaPixels: rgbaPixels, width: width, height: height, useMask: hasMask)
        let blurScore = clamp(blurRaw / 250.0, 0, 1)
        let sizeScore = clamp(sqrt(Double(width * height)) / 180.0, 0, 1)

        var foregroundPixels = 0
        let totalPixels = max(1, width * height)
        if hasMask, rgbaPixels.count >= totalPixels * 4 {
            for i in 0..<totalPixels where rgbaPixels[i * 4 + 3] > 128 {
                foregroundPixels += 1
            }
        } else {
            foregroundPixels = totalPixels
        }
        let areaRatio = Double(foregroundPixels) / Double(totalPixels)
        let areaRatioScore = clamp(areaRatio / 0.55, 0, 1)

        // Occlusion from sibling boxes + mask deficit
        var maxSiblingOverlap: Double = 0
        for other in siblingBoxes where other != normalizedBox {
            let inter = normalizedBox.intersection(other)
            if !inter.isNull && !inter.isEmpty {
                let ratio = Double((inter.width * inter.height) / max(1e-6, normalizedBox.width * normalizedBox.height))
                if ratio > maxSiblingOverlap { maxSiblingOverlap = ratio }
            }
        }
        let expectedArea = isVehicle ? 0.62 : 0.48
        let maskDeficit = hasMask ? clamp((expectedArea - areaRatio) / expectedArea, 0, 1) : 0.25
        let occlusion = clamp(0.6 * maxSiblingOverlap + 0.4 * maskDeficit, 0, 1)

        // Truncation from frame border contact (within ~1% normalized margin)
        let margin: CGFloat = 0.01
        var borderTouches = 0
        if normalizedBox.minX <= margin { borderTouches += 1 }
        if normalizedBox.minY <= margin { borderTouches += 1 }
        if normalizedBox.maxX >= 1.0 - margin { borderTouches += 1 }
        if normalizedBox.maxY >= 1.0 - margin { borderTouches += 1 }
        let truncation = clamp(Double(borderTouches) * 0.25, 0, 1)

        let weighted = 0.28 * confScore
            + 0.22 * blurScore
            + 0.20 * sizeScore
            + 0.12 * areaRatioScore
            + 0.10 * (1.0 - occlusion)
            + 0.08 * (1.0 - truncation)
        let maskFactor = hasMask ? 1.0 : 0.7
        let quality = clamp(weighted * maskFactor, 0, 1)

        return ACTACropQualityMetrics(
            quality: quality,
            confidenceScore: confScore,
            blurScore: blurScore,
            sizeScore: sizeScore,
            areaRatioScore: areaRatioScore,
            occlusionScore: occlusion,
            truncationScore: truncation,
            hasMask: hasMask
        )
    }

    private static func laplacianVariance(rgbaPixels: [UInt8], width: Int, height: Int, useMask: Bool) -> Double {
        guard width >= 3, height >= 3, rgbaPixels.count >= width * height * 4 else { return 0 }
        var gray = [Double](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let o = i * 4
            gray[i] = 0.299 * Double(rgbaPixels[o]) + 0.587 * Double(rgbaPixels[o + 1]) + 0.114 * Double(rgbaPixels[o + 2])
        }
        var sum = 0.0
        var sumSq = 0.0
        var count = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let idx = y * width + x
                if useMask && rgbaPixels[idx * 4 + 3] <= 128 { continue }
                let lap = -4.0 * gray[idx]
                    + gray[idx - 1]
                    + gray[idx + 1]
                    + gray[idx - width]
                    + gray[idx + width]
                sum += lap
                sumSq += lap * lap
                count += 1
            }
        }
        guard count > 1 else { return 0 }
        let mean = sum / Double(count)
        return max(0, sumSq / Double(count) - mean * mean)
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, v))
    }
}

public enum ACTAMatteRefiner {
    /// Edge-aware guided alpha refinement + contrast stretch [0.35, 0.65] + feathering (vision/refiner.py)
    public static func refineRGBA(_ rgba: inout [UInt8], width: Int, height: Int) {
        let count = width * height
        guard width >= 5, height >= 5, rgba.count >= count * 4 else { return }

        var alpha = [Float](repeating: 0, count: count)
        var luma = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let o = i * 4
            alpha[i] = Float(rgba[o + 3]) / 255.0
            luma[i] = (0.299 * Float(rgba[o]) + 0.587 * Float(rgba[o + 1]) + 0.114 * Float(rgba[o + 2])) / 255.0
        }

        // 1. Edge-aware joint bilateral/guided pass (radius = 2)
        var guided = alpha
        for y in 2..<(height - 2) {
            for x in 2..<(width - 2) {
                let centerIdx = y * width + x
                let centerLuma = luma[centerIdx]
                var weightSum: Float = 0
                var valueSum: Float = 0
                for dy in -2...2 {
                    for dx in -2...2 {
                        let nIdx = (y + dy) * width + (x + dx)
                        let diff = luma[nIdx] - centerLuma
                        let w = exp(-(diff * diff) / 0.02)
                        weightSum += w
                        valueSum += w * alpha[nIdx]
                    }
                }
                if weightSum > 0 {
                    guided[centerIdx] = valueSum / weightSum
                }
            }
        }

        // 2. Contrast stretch around 0.5: [0.35, 0.65] -> [0, 1]
        for i in 0..<count {
            let stretched = (guided[i] - 0.35) / 0.30
            guided[i] = min(1, max(0, stretched))
        }

        // 3. Light 3x3 feather and write back
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let idx = y * width + x
                let avg = (
                    guided[idx] * 4
                    + guided[idx - 1] + guided[idx + 1]
                    + guided[idx - width] + guided[idx + width]
                ) / 8.0
                let aByte = UInt8(min(255, max(0, Int((avg * 255.0).rounded()))))
                let o = idx * 4
                rgba[o + 3] = aByte
                if aByte == 0 {
                    rgba[o] = 0
                    rgba[o + 1] = 0
                    rgba[o + 2] = 0
                }
            }
        }
    }
}

// MARK: - 4. Chroma-Print v1 & Color Attributes (vision/chroma.py, vision/attributes.py)

public struct ACTAChromaSignature: Codable, Equatable, Sendable {
    public static let vectorDimension = 410 // 10 regions x 41 Lab color bins
    public static let binsPerRegion = 41    // 36 chromatic (12 Hue x 3 Lightness) + 5 achromatic
    public static let regionCount = 10      // 6 horizontal bands + 3 radial rings + 1 global

    public let blob: Data                   // 410 UInt8 quantized values
    public let code: String                 // "C1-XXXXXXXXXXXXXXXX" (64-bit SimHash LSH)
    public let bucket: UInt16               // 16-bit prefix bucket
    public let hsvHistogram: [Float]        // 256-bin masked HSV histogram (16x4x4)
    public let upperColorHex: String?
    public let lowerColorHex: String?
    public let vehicleColorHex: String?
    public let aspectRatio: Double

    public init(
        blob: Data,
        code: String,
        bucket: UInt16,
        hsvHistogram: [Float],
        upperColorHex: String?,
        lowerColorHex: String?,
        vehicleColorHex: String?,
        aspectRatio: Double
    ) {
        self.blob = blob
        self.code = code
        self.bucket = bucket
        self.hsvHistogram = hsvHistogram
        self.upperColorHex = upperColorHex
        self.lowerColorHex = lowerColorHex
        self.vehicleColorHex = vehicleColorHex
        self.aspectRatio = aspectRatio
    }
}

public enum ACTAChromaPrint {
    public static let skipSimilarityThreshold: Double = 0.97
    public static let rescueSimilarityThreshold: Double = 0.90
    public static let guardSimilarityThreshold: Double = 0.55

    private static let lshProjections: [[Float]] = {
        // Deterministic 64 x 410 projection matrix using SplitMix64(0xC40A2026)
        var state: UInt64 = 0xC40A_2026
        func nextGaussian() -> Float {
            func nextU64() -> UInt64 {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return z ^ (z >> 31)
            }
            let u1 = max(1e-7, Double(nextU64() >> 11) * (1.0 / 9007199254740992.0))
            let u2 = Double(nextU64() >> 11) * (1.0 / 9007199254740992.0)
            return Float(sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2))
        }
        return (0..<64).map { _ in
            (0..<ACTAChromaSignature.vectorDimension).map { _ in nextGaussian() }
        }
    }()

    public static func compute(from imageData: Data, isVehicle: Bool = false) -> ACTAChromaSignature? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width >= 8, height >= 8 else { return nil }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let drew = rgba.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        return compute(rgba: rgba, width: width, height: height, isVehicle: isVehicle)
    }

    public static func compute(rgba: [UInt8], width: Int, height: Int, isVehicle: Bool = false) -> ACTAChromaSignature? {
        let totalPixels = width * height
        guard width >= 8, height >= 8, rgba.count >= totalPixels * 4 else { return nil }

        // 1. Identify foreground mask (alpha > 128); fallback to central ellipse if unmasked
        var mask = [Bool](repeating: false, count: totalPixels)
        var fgCount = 0
        for i in 0..<totalPixels where rgba[i * 4 + 3] > 128 {
            mask[i] = true
            fgCount += 1
        }
        if fgCount < max(16, totalPixels / 20) {
            fgCount = 0
            for y in 0..<height {
                let ny = (Double(y) + 0.5) / Double(height) - 0.5
                for x in 0..<width {
                    let nx = (Double(x) + 0.5) / Double(width) - 0.5
                    if (nx * nx) / 0.16 + (ny * ny) / 0.22 <= 1.0 {
                        mask[y * width + x] = true
                        fgCount += 1
                    }
                }
            }
        }
        guard fgCount > 0 else { return nil }

        // 2. Shades-of-Gray (Minkowski p = 6) white-balance normalization on foreground
        var sumR6 = 0.0, sumG6 = 0.0, sumB6 = 0.0
        for i in 0..<totalPixels where mask[i] {
            let o = i * 4
            let r = Double(rgba[o]) / 255.0
            let g = Double(rgba[o + 1]) / 255.0
            let b = Double(rgba[o + 2]) / 255.0
            sumR6 += pow(r, 6.0)
            sumG6 += pow(g, 6.0)
            sumB6 += pow(b, 6.0)
        }
        let n = Double(fgCount)
        let illumR = max(0.05, pow(sumR6 / n, 1.0 / 6.0))
        let illumG = max(0.05, pow(sumG6 / n, 1.0 / 6.0))
        let illumB = max(0.05, pow(sumB6 / n, 1.0 / 6.0))
        let avgIllum = (illumR + illumG + illumB) / 3.0
        let gainR = min(2.2, max(0.45, avgIllum / illumR))
        let gainG = min(2.2, max(0.45, avgIllum / illumG))
        let gainB = min(2.2, max(0.45, avgIllum / illumB))

        // 3. Accumulate 10 regions x 41 Lab bins + 256-bin HSV histogram + dominant colors
        // Regions 0..5: 6 horizontal bands with 3 LOMO sub-windows max-pooled
        var bandWindowBins = [[[Float]]](
            repeating: [[Float]](repeating: [Float](repeating: 0, count: 41), count: 3),
            count: 6
        )
        // Regions 6..8: 3 radial rings; Region 9: global
        var ringBins = [[Float]](repeating: [Float](repeating: 0, count: 41), count: 3)
        var globalBins = [Float](repeating: 0, count: 41)
        var hsvHist = [Float](repeating: 0, count: 256)

        var upperRGBSum = (r: 0.0, g: 0.0, b: 0.0, count: 0.0)
        var lowerRGBSum = (r: 0.0, g: 0.0, b: 0.0, count: 0.0)
        var fullRGBSum = (r: 0.0, g: 0.0, b: 0.0, count: 0.0)

        for y in 0..<height {
            let ny = Double(y) / Double(height)
            let bandIdx = min(5, max(0, Int(ny * 6.0)))
            let dyNorm = (ny - 0.5) * 2.0
            for x in 0..<width {
                let i = y * width + x
                guard mask[i] else { continue }
                let nx = Double(x) / Double(width)
                let winIdx = min(2, max(0, Int(nx * 3.0)))
                let dxNorm = (nx - 0.5) * 2.0
                let radius = hypot(dxNorm, dyNorm)
                let ringIdx = radius < 0.45 ? 0 : (radius < 0.85 ? 1 : 2)

                let o = i * 4
                let r = min(1.0, Double(rgba[o]) / 255.0 * gainR)
                let g = min(1.0, Double(rgba[o + 1]) / 255.0 * gainG)
                let b = min(1.0, Double(rgba[o + 2]) / 255.0 * gainB)

                fullRGBSum.r += r; fullRGBSum.g += g; fullRGBSum.b += b; fullRGBSum.count += 1
                if ny < 0.48 {
                    upperRGBSum.r += r; upperRGBSum.g += g; upperRGBSum.b += b; upperRGBSum.count += 1
                } else if ny >= 0.50 {
                    lowerRGBSum.r += r; lowerRGBSum.g += g; lowerRGBSum.b += b; lowerRGBSum.count += 1
                }

                // HSV 16x4x4 bin
                let hsv = rgbToHSV(r: r, g: g, b: b)
                let hBin = min(15, max(0, Int(hsv.h * 16.0)))
                let sBin = min(3, max(0, Int(hsv.s * 4.0)))
                let vBin = min(3, max(0, Int(hsv.v * 4.0)))
                hsvHist[hBin * 16 + sBin * 4 + vBin] += 1

                // CIE Lab 41-bin soft assignment
                let lab = rgbToLab(r: r, g: g, b: b)
                let binIdx = quantizeLabBin(L: lab.L, a: lab.a, b: lab.b)
                bandWindowBins[bandIdx][winIdx][binIdx] += 1
                ringBins[ringIdx][binIdx] += 1
                globalBins[binIdx] += 1
            }
        }

        // 4. Assemble 410-d vector with LOMO max-pooling across the 3 horizontal sub-windows per band
        var rawVector = [Float](repeating: 0, count: ACTAChromaSignature.vectorDimension)
        for band in 0..<6 {
            let base = band * 41
            for bin in 0..<41 {
                rawVector[base + bin] = max(
                    bandWindowBins[band][0][bin],
                    max(bandWindowBins[band][1][bin], bandWindowBins[band][2][bin])
                )
            }
        }
        for ring in 0..<3 {
            let base = (6 + ring) * 41
            for bin in 0..<41 {
                rawVector[base + bin] = ringBins[ring][bin]
            }
        }
        let globalBase = 9 * 41
        for bin in 0..<41 {
            rawVector[globalBase + bin] = globalBins[bin]
        }

        // 5. Per-region L1 normalization -> Hellinger sqrt -> Global L2 normalization
        for region in 0..<10 {
            let base = region * 41
            var regionSum: Float = 0
            for bin in 0..<41 { regionSum += rawVector[base + bin] }
            if regionSum > 0 {
                for bin in 0..<41 {
                    rawVector[base + bin] = sqrt(rawVector[base + bin] / regionSum)
                }
            }
        }
        var l2Sum: Float = 0
        for v in rawVector { l2Sum += v * v }
        let l2Norm = sqrt(max(1e-8, l2Sum))
        for i in 0..<rawVector.count { rawVector[i] /= l2Norm }

        // 6. Quantize to 410 UInt8 bytes
        let maxVal = max(1e-6, rawVector.max() ?? 1.0)
        let bytes = rawVector.map { UInt8(min(255, max(0, Int((($0 / maxVal) * 255.0).rounded())))) }
        let blob = Data(bytes)

        // 7. Compute 64-bit SimHash LSH code ("C1-XXXXXXXXXXXXXXXX") and 16-bit bucket
        var meanVal: Float = 0
        for v in rawVector { meanVal += v }
        meanVal /= Float(rawVector.count)
        let centered = rawVector.map { $0 - meanVal }

        var hashBits: UInt64 = 0
        for bit in 0..<64 {
            let proj = lshProjections[bit]
            var dot: Float = 0
            for i in 0..<centered.count { dot += centered[i] * proj[i] }
            if dot >= 0 {
                hashBits |= (1 << UInt64(bit))
            }
        }
        let code = String(format: "C1-%016llx", hashBits)
        let bucket = UInt16((hashBits >> 48) & 0xFFFF)

        // Normalize HSV histogram
        var hsvNorm: Float = 0
        for v in hsvHist { hsvNorm += v * v }
        let hsvScale = sqrt(max(1e-8, hsvNorm))
        for i in 0..<hsvHist.count { hsvHist[i] /= hsvScale }

        let upperHex = hexColor(from: upperRGBSum)
        let lowerHex = hexColor(from: lowerRGBSum)
        let fullHex = hexColor(from: fullRGBSum)
        let aspect = Double(height) / Double(max(1, width))

        return ACTAChromaSignature(
            blob: blob,
            code: code,
            bucket: bucket,
            hsvHistogram: hsvHist,
            upperColorHex: isVehicle ? nil : upperHex,
            lowerColorHex: isVehicle ? nil : lowerHex,
            vehicleColorHex: isVehicle ? fullHex : nil,
            aspectRatio: aspect
        )
    }

    public static func similarity(_ a: Data, _ b: Data) -> Double {
        guard a.count == ACTAChromaSignature.vectorDimension,
              b.count == ACTAChromaSignature.vectorDimension else { return 0 }
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for i in 0..<ACTAChromaSignature.vectorDimension {
            let va = Double(a[i])
            let vb = Double(b[i])
            dot += va * vb
            normA += va * va
            normB += vb * vb
        }
        let denom = sqrt(normA * normB)
        guard denom > 1e-8 else { return 0 }
        return min(1.0, max(0.0, dot / denom))
    }

    public static func hsvSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == 256, b.count == 256 else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<256 {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = sqrt(na * nb)
        guard denom > 1e-8 else { return 0 }
        return Double(min(1, max(0, dot / denom)))
    }

    public static func hammingDistance(_ codeA: String, _ codeB: String) -> Int? {
        let hexA = codeA.hasPrefix("C1-") ? String(codeA.dropFirst(3)) : codeA
        let hexB = codeB.hasPrefix("C1-") ? String(codeB.dropFirst(3)) : codeB
        guard let uA = UInt64(hexA, radix: 16), let uB = UInt64(hexB, radix: 16) else { return nil }
        return (uA ^ uB).nonzeroBitCount
    }

    private static func quantizeLabBin(L: Double, a: Double, b: Double) -> Int {
        let chroma = hypot(a, b)
        // 5 achromatic bins (indices 36..40) when chroma < 14
        if chroma < 14.0 {
            if L < 22 { return 36 }      // black
            if L < 42 { return 37 }      // charcoal
            if L < 62 { return 38 }      // gray
            if L < 80 { return 39 }      // silver
            return 40                    // white
        }
        var angle = atan2(b, a) // [-pi, pi]
        if angle < 0 { angle += 2.0 * .pi }
        let hueBin = min(11, max(0, Int((angle / (2.0 * .pi)) * 12.0)))
        let lightBin = L < 38 ? 0 : (L < 68 ? 1 : 2)
        return hueBin * 3 + lightBin
    }

    private static func rgbToHSV(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double) {
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let delta = maxC - minC
        var h = 0.0
        if delta > 1e-6 {
            if maxC == r {
                h = ((g - b) / delta).truncatingRemainder(dividingBy: 6.0)
            } else if maxC == g {
                h = (b - r) / delta + 2.0
            } else {
                h = (r - g) / delta + 4.0
            }
            h /= 6.0
            if h < 0 { h += 1.0 }
        }
        let s = maxC <= 1e-6 ? 0.0 : delta / maxC
        return (h, s, maxC)
    }

    private static func rgbToLab(r: Double, g: Double, b: Double) -> (L: Double, a: Double, b: Double) {
        func pivotRGB(_ c: Double) -> Double {
            c > 0.04045 ? pow((c + 0.055) / 1.055, 2.4) : c / 12.92
        }
        let rl = pivotRGB(r)
        let gl = pivotRGB(g)
        let bl = pivotRGB(b)
        let x = (rl * 0.4124 + gl * 0.3576 + bl * 0.1805) / 0.95047
        let y = (rl * 0.2126 + gl * 0.7152 + bl * 0.0722) / 1.00000
        let z = (rl * 0.0193 + gl * 0.1192 + bl * 0.9505) / 1.08883
        func pivotXYZ(_ t: Double) -> Double {
            t > 0.008856 ? pow(t, 1.0 / 3.0) : (7.787 * t) + (16.0 / 116.0)
        }
        let fx = pivotXYZ(x)
        let fy = pivotXYZ(y)
        let fz = pivotXYZ(z)
        return (L: max(0, 116.0 * fy - 16.0), a: 500.0 * (fx - fy), b: 200.0 * (fy - fz))
    }

    private static func hexColor(from sum: (r: Double, g: Double, b: Double, count: Double)) -> String? {
        guard sum.count > 0 else { return nil }
        let r = min(255, max(0, Int(((sum.r / sum.count) * 255.0).rounded())))
        let g = min(255, max(0, Int(((sum.g / sum.count) * 255.0).rounded())))
        let b = min(255, max(0, Int(((sum.b / sum.count) * 255.0).rounded())))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - 5. Universal Collage Builder (ai/collage.py)

public struct ACTACollageSpec: Equatable, Sendable {
    public let tileWidth: Int
    public let tileHeight: Int
    public let maxCols: Int
    public let gutter: Int
    public let jpegQuality: CGFloat

    public init(tileWidth: Int, tileHeight: Int, maxCols: Int, gutter: Int = 4, jpegQuality: CGFloat = 0.82) {
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.maxCols = maxCols
        self.gutter = gutter
        self.jpegQuality = jpegQuality
    }

    public static let describe = ACTACollageSpec(tileWidth: 176, tileHeight: 228, maxCols: 10, gutter: 4, jpegQuality: 0.82)
    public static let portrait = ACTACollageSpec(tileWidth: 200, tileHeight: 260, maxCols: 6, gutter: 4, jpegQuality: 0.85)
    public static let plate = ACTACollageSpec(tileWidth: 360, tileHeight: 112, maxCols: 3, gutter: 4, jpegQuality: 0.92)
    public static let narrative = ACTACollageSpec(tileWidth: 240, tileHeight: 135, maxCols: 8, gutter: 4, jpegQuality: 0.80)
}

public struct ACTACollageTile: Sendable {
    public let index: Int
    public let imageData: Data
    public let subtitle: String?

    public init(index: Int, imageData: Data, subtitle: String? = nil) {
        self.index = index
        self.imageData = imageData
        self.subtitle = subtitle
    }
}

public enum ACTACollageBuilder {
    public static func build(tiles: [ACTACollageTile], spec: ACTACollageSpec) -> Data? {
        guard !tiles.isEmpty else { return nil }
        let cols = min(spec.maxCols, tiles.count)
        let rows = (tiles.count + cols - 1) / cols
        let canvasWidth = cols * spec.tileWidth + (cols + 1) * spec.gutter
        let canvasHeight = rows * spec.tileHeight + (rows + 1) * spec.gutter

        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: canvasWidth,
            height: canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: canvasWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return nil }

        // Dark background (#121417)
        context.setFillColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))

        for (position, tile) in tiles.enumerated() {
            let col = position % cols
            let row = position / cols
            let cellX = spec.gutter + col * (spec.tileWidth + spec.gutter)
            // CoreGraphics origin is bottom-left; row 0 should be at top
            let cellY = canvasHeight - (row + 1) * (spec.tileHeight + spec.gutter)
            let cellRect = CGRect(x: cellX, y: cellY, width: spec.tileWidth, height: spec.tileHeight)

            context.setFillColor(red: 0.14, green: 0.16, blue: 0.18, alpha: 1.0)
            context.fill(cellRect)

            if let source = CGImageSourceCreateWithData(tile.imageData as CFData, nil),
               let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                let scale = min(
                    CGFloat(spec.tileWidth) / CGFloat(max(1, cgImage.width)),
                    CGFloat(spec.tileHeight) / CGFloat(max(1, cgImage.height))
                )
                let drawW = CGFloat(cgImage.width) * scale
                let drawH = CGFloat(cgImage.height) * scale
                let drawX = cellRect.minX + (cellRect.width - drawW) / 2.0
                let drawY = cellRect.minY + (cellRect.height - drawH) / 2.0
                context.interpolationQuality = .high
                context.draw(cgImage, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
            }

            // Draw top-left [#N] badge background for clear VLM tile indexing
            let badgeRect = CGRect(x: cellRect.minX + 4, y: cellRect.maxY - 22, width: 38, height: 18)
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.78)
            context.fill(badgeRect)
        }

        guard let finalImage = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, finalImage, [
            kCGImageDestinationLossyCompressionQuality: spec.jpegQuality
        ] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

// MARK: - 6. NormalizedRect & Unified Convenience Bridges

public struct NormalizedRect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    public func iou(with other: NormalizedRect) -> Double {
        let inter = cgRect.intersection(other.cgRect)
        guard !inter.isNull, !inter.isEmpty else { return 0 }
        let interArea = Double(inter.width * inter.height)
        let unionArea = width * height + other.width * other.height - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }
}

public struct ACTACropCandidate: Codable, Sendable, Equatable {
    public var id: UUID
    public var trackKey: String
    public var capturedAt: Date
    public var quality: Double
    public var reason: ACTACaptureReason

    public init(
        id: UUID = UUID(),
        trackKey: String,
        capturedAt: Date = Date(),
        quality: Double,
        reason: ACTACaptureReason = .firstAppearance
    ) {
        self.id = id
        self.trackKey = trackKey
        self.capturedAt = capturedAt
        self.quality = quality
        self.reason = reason
    }
}

extension ACTACaptureScheduler {
    private static func deterministicUUID(_ key: String) -> UUID {
        if let uuid = UUID(uuidString: key) { return uuid }
        var bytes = [UInt8](repeating: 0, count: 16)
        let utf8 = Array(key.utf8)
        for (i, b) in utf8.enumerated() {
            bytes[i % 16] = bytes[i % 16] &+ b &* UInt8((i % 7) + 1)
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    public func shouldCapture(
        trackKey: String,
        cameraID: String,
        label: String,
        normalizedRect: NormalizedRect,
        timestamp: Date
    ) -> ACTACaptureReason? {
        let decision = evaluate(
            cameraID: Self.deterministicUUID(cameraID),
            trackID: Self.deterministicUUID(trackKey),
            label: label,
            box: normalizedRect.cgRect,
            now: timestamp.timeIntervalSince1970
        )
        return decision.shouldCapture ? decision.reason : nil
    }
}

extension ACTACropWindow {
    public mutating func offer(_ candidate: ACTACropCandidate, now: Date = Date()) -> Bool {
        shouldAccept(
            cropID: candidate.id,
            quality: candidate.quality,
            now: candidate.capturedAt.timeIntervalSince1970
        )
    }
}

public struct ACTACropQualityBreakdown: Codable, Sendable, Equatable {
    public var confidenceScore: Double
    public var blurScore: Double
    public var sizeScore: Double
    public var areaScore: Double
    public var occlusionPenalty: Double
    public var truncationPenalty: Double
    public var hasValidMask: Bool
    public var totalScore: Double

    public init(
        confidenceScore: Double,
        blurScore: Double,
        sizeScore: Double,
        areaScore: Double,
        occlusionPenalty: Double,
        truncationPenalty: Double,
        hasValidMask: Bool
    ) {
        self.confidenceScore = confidenceScore
        self.blurScore = blurScore
        self.sizeScore = sizeScore
        self.areaScore = areaScore
        self.occlusionPenalty = occlusionPenalty
        self.truncationPenalty = truncationPenalty
        self.hasValidMask = hasValidMask
        let raw = 0.28 * confidenceScore
            + 0.22 * blurScore
            + 0.20 * sizeScore
            + 0.12 * areaScore
            + 0.10 * (1.0 - occlusionPenalty)
            + 0.08 * (1.0 - truncationPenalty)
        self.totalScore = min(1.0, max(0.0, raw * (hasValidMask ? 1.0 : 0.7)))
    }
}

extension ACTACropQualityScorer {
    public static func score(
        cgImage: CGImage,
        alphaMask: [Float]? = nil,
        confidence: Double,
        normalizedBox: NormalizedRect,
        neighborBoxes: [NormalizedRect] = []
    ) -> ACTACropQualityBreakdown {
        let width = cgImage.width
        let height = cgImage.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        rgba.withUnsafeMutableBytes { ptr in
            if let ctx = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) {
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        let hasMask = (alphaMask != nil && !(alphaMask?.isEmpty ?? true))
        if let alphaMask, alphaMask.count == width * height {
            for i in 0..<(width * height) {
                rgba[i * 4 + 3] = UInt8(min(255, max(0, Int((alphaMask[i] * 255.0).rounded()))))
            }
        }
        let metrics = evaluate(
            rgbaPixels: rgba,
            width: width,
            height: height,
            detectionConfidence: confidence,
            normalizedBox: normalizedBox.cgRect,
            siblingBoxes: neighborBoxes.map(\.cgRect),
            hasMask: hasMask
        )
        return ACTACropQualityBreakdown(
            confidenceScore: metrics.confidenceScore,
            blurScore: metrics.blurScore,
            sizeScore: metrics.sizeScore,
            areaScore: metrics.areaRatioScore,
            occlusionPenalty: metrics.occlusionScore,
            truncationPenalty: metrics.truncationScore,
            hasValidMask: metrics.hasMask
        )
    }
}

extension ACTAMatteRefiner {
    public static func refineAlphaMask(
        rawAlpha: [Float],
        maskWidth: Int,
        maskHeight: Int,
        guideImage: CGImage
    ) -> [Float] {
        guard maskWidth >= 5, maskHeight >= 5, rawAlpha.count == maskWidth * maskHeight else {
            return rawAlpha
        }
        var rgba = [UInt8](repeating: 0, count: maskWidth * maskHeight * 4)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        rgba.withUnsafeMutableBytes { ptr in
            if let ctx = CGContext(
                data: ptr.baseAddress,
                width: maskWidth,
                height: maskHeight,
                bitsPerComponent: 8,
                bytesPerRow: maskWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) {
                ctx.draw(guideImage, in: CGRect(x: 0, y: 0, width: maskWidth, height: maskHeight))
            }
        }
        for i in 0..<(maskWidth * maskHeight) {
            rgba[i * 4 + 3] = UInt8(min(255, max(0, Int((rawAlpha[i] * 255.0).rounded()))))
        }
        refineRGBA(&rgba, width: maskWidth, height: maskHeight)
        return (0..<(maskWidth * maskHeight)).map { Float(rgba[$0 * 4 + 3]) / 255.0 }
    }
}

extension ACTAChromaSignature {
    public static let descriptorDimension: Int = vectorDimension

    public func cosineSimilarity(to other: ACTAChromaSignature) -> Double {
        ACTAChromaPrint.similarity(self.blob, other.blob)
    }
}

extension ACTAChromaPrint {
    public static let descriptorDimension: Int = ACTAChromaSignature.vectorDimension

    public static func compute(
        from cgImage: CGImage,
        alphaMask: [Float]? = nil,
        isVehicle: Bool = false
    ) -> ACTAChromaSignature? {
        let width = cgImage.width
        let height = cgImage.height
        guard width >= 8, height >= 8 else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let drew = rgba.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        if let alphaMask, alphaMask.count == width * height {
            for i in 0..<(width * height) {
                rgba[i * 4 + 3] = UInt8(min(255, max(0, Int((alphaMask[i] * 255.0).rounded()))))
            }
        }
        return compute(rgba: rgba, width: width, height: height, isVehicle: isVehicle)
    }

    public static func computeHSVHistogram(
        from cgImage: CGImage,
        alphaMask: [Float]? = nil
    ) -> [Float] {
        compute(from: cgImage, alphaMask: alphaMask, isVehicle: false)?.hsvHistogram ?? []
    }

    public static func hsvCosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        hsvSimilarity(a, b)
    }
}

public enum ACTACollageKind: String, Codable, Sendable {
    case describe
    case portrait
    case plate
    case narrative

    public var spec: ACTACollageSpec {
        switch self {
        case .describe: return .describe
        case .portrait: return .portrait
        case .plate: return .plate
        case .narrative: return .narrative
        }
    }
}

public struct ACTACollageCell: Sendable {
    public var badgeIndex: Int
    public var itemID: String
    public var cgImage: CGImage
    public var caption: String?

    public init(badgeIndex: Int, itemID: String, cgImage: CGImage, caption: String? = nil) {
        self.badgeIndex = badgeIndex
        self.itemID = itemID
        self.cgImage = cgImage
        self.caption = caption
    }
}

public struct ACTARenderedCollage: Sendable {
    public var jpegData: Data
    public var cells: [ACTACollageCell]

    public init(jpegData: Data, cells: [ACTACollageCell]) {
        self.jpegData = jpegData
        self.cells = cells
    }
}

extension ACTACollageBuilder {
    public static func buildCollage(kind: ACTACollageKind, cells: [ACTACollageCell]) -> ACTARenderedCollage? {
        if cells.isEmpty {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil,
                width: 16,
                height: 16,
                bitsPerComponent: 8,
                bytesPerRow: 16 * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let cg = ctx.makeImage() else { return nil }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, cg, nil)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return ACTARenderedCollage(jpegData: out as Data, cells: [])
        }
        let tiles: [ACTACollageTile] = cells.compactMap { cell in
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, cell.cgImage, nil)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return ACTACollageTile(index: cell.badgeIndex, imageData: out as Data, subtitle: cell.caption)
        }
        guard let data = build(tiles: tiles, spec: kind.spec) else { return nil }
        return ACTARenderedCollage(jpegData: data, cells: cells)
    }
}
