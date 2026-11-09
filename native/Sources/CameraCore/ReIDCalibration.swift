import Foundation

public struct LabeledReIDPair: Equatable, Sendable {
    public let distance: Double
    public let sameObject: Bool

    public init(distance: Double, sameObject: Bool) {
        self.distance = distance
        self.sameObject = sameObject
    }
}

public struct ReIDValidationSample: Equatable, Sendable {
    public let trackA: UUID
    public let trackB: UUID
    public let pair: LabeledReIDPair
}

public struct ReIDValidationCandidate: Identifiable, Sendable {
    public let trackA: TrackedObjectRecord
    public let trackB: TrackedObjectRecord
    public let distance: Double

    public init(trackA: TrackedObjectRecord, trackB: TrackedObjectRecord, distance: Double) {
        self.trackA = trackA
        self.trackB = trackB
        self.distance = distance
    }

    public var id: String {
        [trackA.trackID.uuidString, trackB.trackID.uuidString].sorted().joined(separator: ":")
    }
}

public struct ReIDCalibrationResult: Equatable, Sendable {
    public let positivePairs: Int
    public let negativePairs: Int
    public let targetPrecision: Double
    public let recommendedDistance: Double?
    public let precision: Double?
    public let recall: Double?
    public let falsePositives: Int?
    public let truePositives: Int?
    public let sweep: [ReIDThresholdMetrics]

    public var isReady: Bool { recommendedDistance != nil }
}

public struct ReIDThresholdMetrics: Equatable, Sendable, Identifiable {
    public let threshold: Double
    public let precision: Double
    public let recall: Double
    public let falseMatchRate: Double?
    public let falsePositives: Int
    public let truePositives: Int

    public var id: Double { threshold }
}

public enum ReIDThresholdCalibrator {
    public static let defaultTargetPrecision = 0.995
    public static let minimumPositivePairs = 20
    public static let minimumNegativePairs = 100

    public static func calibrate(
        _ pairs: [LabeledReIDPair],
        targetPrecision: Double = defaultTargetPrecision,
        minimumPositivePairs: Int = minimumPositivePairs,
        minimumNegativePairs: Int = minimumNegativePairs
    ) -> ReIDCalibrationResult {
        let validPairs = pairs.filter { $0.distance.isFinite && (0...2).contains($0.distance) }
        let positives = validPairs.filter(\.sameObject)
        let negatives = validPairs.filter { !$0.sameObject }
        guard targetPrecision.isFinite, (0.5...1).contains(targetPrecision) else {
            return ReIDCalibrationResult(
                positivePairs: positives.count, negativePairs: negatives.count,
                targetPrecision: targetPrecision, recommendedDistance: nil,
                precision: nil, recall: nil, falsePositives: nil, truePositives: nil, sweep: []
            )
        }

        let sortedPositives = positives.map(\.distance).sorted()
        let sortedNegatives = negatives.map(\.distance).sorted()
        let candidates = Array(Set(sortedPositives)).sorted()
        var truePositives = 0
        var falsePositives = 0
        var positiveIndex = 0
        var negativeIndex = 0
        var sweep: [ReIDThresholdMetrics] = []
        for threshold in candidates {
            while positiveIndex < sortedPositives.count && sortedPositives[positiveIndex] <= threshold {
                truePositives += 1
                positiveIndex += 1
            }
            while negativeIndex < sortedNegatives.count && sortedNegatives[negativeIndex] <= threshold {
                falsePositives += 1
                negativeIndex += 1
            }
            guard truePositives > 0 else { continue }
            let precision = Double(truePositives) / Double(truePositives + falsePositives)
            sweep.append(ReIDThresholdMetrics(
                threshold: threshold,
                precision: precision,
                recall: Double(truePositives) / Double(positives.count),
                falseMatchRate: negatives.isEmpty ? nil : Double(falsePositives) / Double(negatives.count),
                falsePositives: falsePositives,
                truePositives: truePositives
            ))
        }
        let enoughLabels = positives.count >= max(1, minimumPositivePairs)
            && negatives.count >= max(1, minimumNegativePairs)
        var best: (threshold: Double, precision: Double, recall: Double, fp: Int, tp: Int)?
        for point in sweep where enoughLabels && point.precision >= targetPrecision {
            let threshold = point.threshold
            let truePositives = point.truePositives
            let falsePositives = point.falsePositives
            let precision = point.precision
            let recall = point.recall
            if let current = best,
               (recall < current.recall || (recall == current.recall && threshold >= current.threshold)) {
                continue
            }
            best = (threshold, precision, recall, falsePositives, truePositives)
        }

        return ReIDCalibrationResult(
            positivePairs: positives.count,
            negativePairs: negatives.count,
            targetPrecision: targetPrecision,
            recommendedDistance: best?.threshold,
            precision: best?.precision,
            recall: best?.recall,
            falsePositives: best?.fp,
            truePositives: best?.tp,
            sweep: sweep
        )
    }
}