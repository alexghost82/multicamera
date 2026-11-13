import AVFoundation
import CameraCore
import CoreGraphics
import Foundation

// MARK: - 1. Pending Queue Items

public struct GhostPendingDescribeItem: Sendable {
    public var trackID: UUID
    public var cameraID: UUID
    public var cameraName: String
    public var kind: String // "person" or "vehicle"
    public var cgImage: CGImage
    public var cropQuality: Double
    public var enqueuedAt: Date

    public init(
        trackID: UUID,
        cameraID: UUID,
        cameraName: String,
        kind: String,
        cgImage: CGImage,
        cropQuality: Double,
        enqueuedAt: Date = Date()
    ) {
        self.trackID = trackID
        self.cameraID = cameraID
        self.cameraName = cameraName
        self.kind = kind
        self.cgImage = cgImage
        self.cropQuality = cropQuality
        self.enqueuedAt = enqueuedAt
    }
}

public struct GhostPendingPlateItem: Sendable {
    public var trackID: UUID
    public var identityID: String?
    public var cameraID: UUID
    public var cgImage: CGImage
    public var enqueuedAt: Date

    public init(
        trackID: UUID,
        identityID: String? = nil,
        cameraID: UUID,
        cgImage: CGImage,
        enqueuedAt: Date = Date()
    ) {
        self.trackID = trackID
        self.identityID = identityID
        self.cameraID = cameraID
        self.cgImage = cgImage
        self.enqueuedAt = enqueuedAt
    }
}

// MARK: - 2. Critical Alert 4-Frame Ring & Alert Rate Limiter

public struct GhostAlertRingFrame: Sendable {
    public var cgImage: CGImage
    public var capturedAt: Date

    public init(cgImage: CGImage, capturedAt: Date) {
        self.cgImage = cgImage
        self.capturedAt = capturedAt
    }
}

public struct GhostCameraAlertRingState: Sendable {
    public static let ringCapacity: Int = 4
    public static let sampleIntervalSec: TimeInterval = 1.2
    public static let lookbackCapacity: Int = 16

    public var ringFrames: [GhostAlertRingFrame] = []
    public var lookbackFrames: [GhostAlertRingFrame] = []
    public var lastSampledAt: Date = .distantPast

    public init() {}

    public mutating func offerFrame(_ image: CGImage, at timestamp: Date) -> Bool {
        guard timestamp.timeIntervalSince(lastSampledAt) >= Self.sampleIntervalSec else {
            return false
        }
        lastSampledAt = timestamp
        let item = GhostAlertRingFrame(cgImage: image, capturedAt: timestamp)
        ringFrames.append(item)
        if ringFrames.count > Self.ringCapacity {
            ringFrames.removeFirst(ringFrames.count - Self.ringCapacity)
        }
        lookbackFrames.append(item)
        if lookbackFrames.count > Self.lookbackCapacity {
            lookbackFrames.removeFirst(lookbackFrames.count - Self.lookbackCapacity)
        }
        return ringFrames.count == Self.ringCapacity
    }
}

// MARK: - 3. Narrative Sampler State per Camera

public struct GhostCameraNarrativeState: Sendable {
    public static let sampleIntervalSec: TimeInterval = 2.0
    public static let flushFrameThreshold: Int = 28
    public static let flushTimeoutSec: TimeInterval = 480.0

    public var frames: [GhostAlertRingFrame] = []
    public var chapterStartedAt: Date?
    public var lastSampledAt: Date = .distantPast
    public var lastChapterSummary: String?

    public init() {}

    public mutating func offerFrame(
        _ image: CGImage,
        hasActiveObjects: Bool,
        mode: String = "object",
        at timestamp: Date
    ) -> [GhostAlertRingFrame]? {
        if mode == "object" && !hasActiveObjects && frames.isEmpty {
            return nil
        }
        guard timestamp.timeIntervalSince(lastSampledAt) >= Self.sampleIntervalSec else {
            return nil
        }
        lastSampledAt = timestamp
        if chapterStartedAt == nil {
            chapterStartedAt = timestamp
        }
        frames.append(GhostAlertRingFrame(cgImage: image, capturedAt: timestamp))

        let elapsed = timestamp.timeIntervalSince(chapterStartedAt ?? timestamp)
        if frames.count >= Self.flushFrameThreshold || (frames.count >= 4 && elapsed >= Self.flushTimeoutSec) {
            let batch = frames
            frames.removeAll(keepingCapacity: true)
            chapterStartedAt = nil
            return batch
        }
        return nil
    }
}

// MARK: - 4. Ghost Analytics Coordinator

public final class GhostAnalyticsCoordinator: @unchecked Sendable {
    // Gate & Poller Constants
    public static let describeGateMinBatch: Int = 8
    public static let describeGateMaxBatch: Int = 88
    public static let describeGateMaxWaitSec: TimeInterval = 20.0

    public static let plateBatchTriggerCount: Int = 24
    public static let plateBatchMaxWaitSec: TimeInterval = 25.0

    public static let continuitySweepIntervalSec: TimeInterval = 48.0
    public static let puritySweepIntervalSec: TimeInterval = 18.0
    public static let spokenBriefingIntervalSec: TimeInterval = 18.0

    public static let alertMaxRPM: Int = 20
    public static let alertDedupWindowSec: TimeInterval = 30.0

    private let lock = NSLock()
    public let aiClient: GhostAIClient
    public let identityResolver: GhostIdentityResolver
    public let registryClient = GhostIsraeliVehicleRegistryClient()
    private weak var trackingStore: LocalTrackingStore?

    // Stateful Schedulers & Queues
    private var captureScheduler = GhostCaptureScheduler()
    private var cropWindowsByTrack: [String: GhostCropWindow] = [:]
    private var stitcher = GhostTrackletStitcher()

    private var pendingDescribeQueue: [GhostPendingDescribeItem] = []
    private var pendingPlateQueue: [GhostPendingPlateItem] = []
    private var facetsByIdentityID: [String: GhostFacetSummary] = [:]
    private var sexInputsByIdentityTrack: [String: [String: [GhostSexObservationInput]]] = [:]

    private var alertRingsByCamera: [UUID: GhostCameraAlertRingState] = [:]
    private var narrativeStatesByCamera: [UUID: GhostCameraNarrativeState] = [:]
    private var recentAlertTimestamps: [Date] = []
    private var lastAlertDedupByKey: [String: Date] = [:]

    private var lastContinuitySweepAt: Date = .distantPast
    private var cropsSinceLastSweep: Int = 0
    private var lastPuritySweepAt: Date = .distantPast
    private var lastSpokenBriefingAt: Date = .distantPast

    public private(set) var recentSpokenCards: [GhostHCCard] = []
    public private(set) var recentCriticalAlerts: [(cameraID: UUID, cameraName: String, detection: GhostCriticalAlertDetection, mentorBrief: GhostAlertMentorBrief?, triggeredAt: Date)] = []

    public init(
        aiClient: GhostAIClient,
        trackingStore: LocalTrackingStore? = nil
    ) {
        let initialProfiles = (try? trackingStore?.loadGhostIdentityProfiles(limit: 500)) ?? []
        self.aiClient = aiClient
        self.trackingStore = trackingStore
        self.identityResolver = GhostIdentityResolver(galleries: initialProfiles)
    }

    // MARK: - Step A: Real-Time Vision Ingestion (Capture Schedule + Quality + Chroma + Multi-Cue ReID)

    public func processTrackObservation(
        trackID: UUID,
        cameraID: UUID,
        cameraName: String,
        label: String,
        confidence: Double,
        normalizedRect: NormalizedRect,
        cropImage: CGImage?,
        alphaMask: [Float]?,
        maskWidth: Int = 0,
        maskHeight: Int = 0,
        embedding: [Float]?,
        neighborBoxes: [NormalizedRect] = [],
        now: Date = Date()
    ) -> GhostIdentityResolutionDecision? {
        let trackKey = trackID.uuidString
        let camKey = cameraID.uuidString
        let isVehicle = ["car", "truck", "bus", "motorcycle", "bicycle", "vehicle"].contains(label.lowercased())
        let kind = isVehicle ? "vehicle" : "person"

        var refinedAlpha: [Float]? = alphaMask
        if let cropImage, let alphaMask, maskWidth > 0, maskHeight > 0 {
            refinedAlpha = GhostMatteRefiner.refineAlphaMask(
                rawAlpha: alphaMask,
                maskWidth: maskWidth,
                maskHeight: maskHeight,
                guideImage: cropImage
            )
        }

        let qualityBreakdown: GhostCropQualityBreakdown
        if let cropImage {
            qualityBreakdown = GhostCropQualityScorer.score(
                cgImage: cropImage,
                alphaMask: refinedAlpha,
                confidence: confidence,
                normalizedBox: normalizedRect,
                neighborBoxes: neighborBoxes
            )
        } else {
            qualityBreakdown = GhostCropQualityBreakdown(
                confidenceScore: confidence,
                blurScore: 0.5,
                sizeScore: 0.5,
                areaScore: 0.5,
                occlusionPenalty: 0,
                truncationPenalty: 0,
                hasValidMask: false
            )
        }

        var chromaPrint: GhostChromaSignature?
        var hsvHistogram: [Float] = []
        if let cropImage {
            chromaPrint = GhostChromaPrint.compute(
                from: cropImage,
                alphaMask: refinedAlpha,
                isVehicle: isVehicle
            )
            hsvHistogram = chromaPrint?.hsvHistogram ?? []
        }

        lock.lock()
        let captureReason = captureScheduler.shouldCapture(
            trackKey: trackKey,
            cameraID: camKey,
            label: label,
            normalizedRect: normalizedRect,
            timestamp: now
        )
        var window = cropWindowsByTrack[trackKey] ?? GhostCropWindow()
        let acceptedIntoTopK = window.offer(
            GhostCropCandidate(
                id: UUID(),
                trackKey: trackKey,
                capturedAt: now,
                quality: qualityBreakdown.totalScore,
                reason: captureReason ?? .firstAppearance
            ),
            now: now
        )
        cropWindowsByTrack[trackKey] = window

        if let cropImage, (captureReason != nil || acceptedIntoTopK) {
            if pendingDescribeQueue.count < 256,
               !pendingDescribeQueue.contains(where: { $0.trackID == trackID }) {
                pendingDescribeQueue.append(
                    GhostPendingDescribeItem(
                        trackID: trackID,
                        cameraID: cameraID,
                        cameraName: cameraName,
                        kind: kind,
                        cgImage: cropImage,
                        cropQuality: qualityBreakdown.totalScore,
                        enqueuedAt: now
                    )
                )
            }
            if isVehicle, pendingPlateQueue.count < 128,
               !pendingPlateQueue.contains(where: { $0.trackID == trackID }) {
                pendingPlateQueue.append(
                    GhostPendingPlateItem(
                        trackID: trackID,
                        cameraID: cameraID,
                        cgImage: cropImage,
                        enqueuedAt: now
                    )
                )
            }
            cropsSinceLastSweep += 1
        }
        lock.unlock()

        var decision: GhostIdentityResolutionDecision?
        if let embedding, embedding.count == 512 {
            let candidate = GhostMultiCueCandidateObservation(
                trackKey: trackKey,
                cameraID: camKey,
                kind: kind,
                embedding: embedding,
                cropQuality: qualityBreakdown.totalScore,
                chromaPrint: chromaPrint,
                hsvHistogram: hsvHistogram,
                normalizedRect: normalizedRect,
                observedAt: now
            )
            let resolved = identityResolver.resolve(observation: candidate)
            decision = resolved
            if let profile = identityResolver.gallery(for: resolved.identityID) {
                try? trackingStore?.upsertGhostIdentityProfile(profile)
            }
        }

        try? trackingStore?.saveGhostTrackVisualMetadata(
            trackID: trackID,
            cropQuality: qualityBreakdown.totalScore,
            chromaPrint: chromaPrint,
            hsvHistogram: hsvHistogram,
            resolvedSex: .unknown,
            identityState: decision?.state,
            identityScore: decision?.score
        )

        return decision
    }

    // MARK: - Step B: Periodic Background Tick (DescribeGate, PlateBatch, ContinuitySweeper, PuritySplitter)

    public func runPeriodicMaintenanceTick(now: Date = Date()) async {
        await flushDescribeGateIfNeeded(now: now)
        await flushPlateBatchIfNeeded(now: now)
        await runPuritySplitterIfNeeded(now: now)
        await runContinuitySweeperIfNeeded(now: now)
    }

    public func flushDescribeGateIfNeeded(force: Bool = false, now: Date = Date()) async {
        let batchToRun: [GhostPendingDescribeItem] = lock.withLock {
            guard !pendingDescribeQueue.isEmpty else { return [] }
            let oldestWait = now.timeIntervalSince(pendingDescribeQueue.first!.enqueuedAt)
            let shouldFire = force ||
                pendingDescribeQueue.count >= Self.describeGateMinBatch ||
                oldestWait >= Self.describeGateMaxWaitSec
            guard shouldFire else { return [] }
            let count = min(Self.describeGateMaxBatch, pendingDescribeQueue.count)
            let slice = Array(pendingDescribeQueue.prefix(count))
            pendingDescribeQueue.removeFirst(count)
            return slice
        }

        guard !batchToRun.isEmpty else { return }

        let cells = batchToRun.enumerated().map { idx, item in
            GhostCollageCell(
                badgeIndex: idx + 1,
                itemID: item.trackID.uuidString,
                cgImage: item.cgImage,
                caption: item.kind
            )
        }
        guard let collage = GhostCollageBuilder.buildCollage(kind: .describe, cells: cells) else {
            return
        }

        let lang = aiClient.configuration().preferredLanguage
        let prompt = GhostPromptLibrary.bulkDescribePrompt(cellCount: cells.count, language: lang)

        let result = await aiClient.generateStructured(
            lane: .background,
            tier: .nano,
            prompt: prompt,
            jpegImages: [collage.jpegData],
            responseType: GhostCropDescriptionBatch.self,
            fallbackFactory: {
                GhostCropDescriptionBatch(
                    items: batchToRun.enumerated().map { idx, item in
                        GhostCropDescriptionItem(
                            cellIndex: idx + 1,
                            itemID: item.trackID.uuidString,
                            kind: item.kind,
                            summary: item.kind == "vehicle" ? "Транспортное средство" : "Человек в кадре",
                            confidence: 0.70
                        )
                    }
                )
            }
        )

        lock.withLock {
            for desc in result.items {
                guard desc.cellIndex >= 1, desc.cellIndex <= batchToRun.count else { continue }
                let sourceItem = batchToRun[desc.cellIndex - 1]
                let trackKey = sourceItem.trackID.uuidString

                let matchingGallery = identityResolver.allGalleries().first {
                    $0.memberTrackKeys.contains(trackKey)
                }
                let identityID = matchingGallery?.identityID ?? trackKey

                let obsInput = GhostSexObservationInput(
                    trackKey: trackKey,
                    apparentSex: desc.person?.apparentSex,
                    descriptionText: desc.summary,
                    facialHair: desc.person?.facialHair,
                    lowerClothingType: desc.person?.lowerClothingType,
                    cropQuality: sourceItem.cropQuality
                )
                var trackMap = sexInputsByIdentityTrack[identityID] ?? [:]
                var list = trackMap[trackKey] ?? []
                list.append(obsInput)
                trackMap[trackKey] = list
                sexInputsByIdentityTrack[identityID] = trackMap

                let allSexInputs = trackMap.values.flatMap { $0 }
                let sexRes = GhostSexResolver.resolve(observations: allSexInputs)

                facetsByIdentityID[identityID] = GhostFacetSummary(
                    identityID: identityID,
                    kind: sourceItem.kind,
                    resolvedSex: sexRes.sex,
                    ageGroup: desc.person?.ageGroup,
                    build: desc.person?.build,
                    hairStyleOrColor: desc.person?.hairStyleOrColor,
                    upperClothingType: desc.person?.upperClothingType,
                    upperColor: desc.person?.upperColor,
                    lowerClothingType: desc.person?.lowerClothingType,
                    lowerColor: desc.person?.lowerColor,
                    accessories: desc.person?.bagsOrCarriedItems ?? [],
                    vehicleType: desc.vehicle?.vehicleType,
                    vehicleColor: desc.vehicle?.primaryColor,
                    makeModel: [desc.vehicle?.make, desc.vehicle?.model].compactMap { $0 }.joined(separator: " "),
                    plateNumber: desc.vehicle?.plateText,
                    summaryText: GhostOpSec.sanitizeText(desc.summary)
                )

                if var profile = matchingGallery {
                    if sexRes.sex != .unknown {
                        profile.resolvedSex = sexRes.sex
                        profile.resolvedSexConfidence = sexRes.confidence
                    }
                    if let plate = desc.vehicle?.plateText, !plate.isEmpty {
                        profile.plateNumber = plate
                    }
                    identityResolver.upsertGallery(profile)
                    try? trackingStore?.upsertGhostIdentityProfile(profile)
                }
            }
        }
    }

    public func flushPlateBatchIfNeeded(force: Bool = false, now: Date = Date()) async {
        let batchToRun: [GhostPendingPlateItem] = lock.withLock {
            guard !pendingPlateQueue.isEmpty else { return [] }
            let oldestWait = now.timeIntervalSince(pendingPlateQueue.first!.enqueuedAt)
            let shouldFire = force ||
                pendingPlateQueue.count >= Self.plateBatchTriggerCount ||
                oldestWait >= Self.plateBatchMaxWaitSec
            guard shouldFire else { return [] }
            let count = min(Self.plateBatchTriggerCount, pendingPlateQueue.count)
            let slice = Array(pendingPlateQueue.prefix(count))
            pendingPlateQueue.removeFirst(count)
            return slice
        }

        guard !batchToRun.isEmpty else { return }

        let cells = batchToRun.enumerated().map { idx, item in
            GhostCollageCell(
                badgeIndex: idx + 1,
                itemID: item.trackID.uuidString,
                cgImage: item.cgImage
            )
        }
        guard let collage = GhostCollageBuilder.buildCollage(kind: .plate, cells: cells) else {
            return
        }

        let lang = aiClient.configuration().preferredLanguage
        let prompt = GhostPromptLibrary.plateCollagePrompt(cellCount: cells.count, language: lang)
        let result = await aiClient.generateStructured(
            lane: .background,
            tier: .nano,
            prompt: prompt,
            jpegImages: [collage.jpegData],
            responseType: GhostPlateCollageResult.self,
            fallbackFactory: { GhostPlateCollageResult(plates: []) }
        )

        for readItem in result.plates where readItem.confidence >= 0.55 {
            guard readItem.cellIndex >= 1, readItem.cellIndex <= batchToRun.count else { continue }
            let source = batchToRun[readItem.cellIndex - 1]
            if let normalized = GhostVehicleRegistryRecord.normalizeIsraeliPlate(readItem.plateText) {
                _ = await registryClient.lookupPlate(rawPlate: normalized, store: trackingStore)
                let trackKey = source.trackID.uuidString
                if var profile = identityResolver.allGalleries().first(where: { $0.memberTrackKeys.contains(trackKey) }) {
                    profile.plateNumber = normalized
                    identityResolver.upsertGallery(profile)
                    try? trackingStore?.upsertGhostIdentityProfile(profile)
                }
            }
        }
    }

    public func runPuritySplitterIfNeeded(now: Date = Date()) async {
        let shouldRun: Bool = lock.withLock {
            guard now.timeIntervalSince(lastPuritySweepAt) >= Self.puritySweepIntervalSec else {
                return false
            }
            lastPuritySweepAt = now
            return true
        }
        guard shouldRun else { return }

        let galleries = identityResolver.allGalleries().filter { $0.kind == "person" && $0.memberTrackKeys.count >= 2 }
        for profile in galleries {
            let trackObservations: [String: [GhostSexObservationInput]] = lock.withLock {
                sexInputsByIdentityTrack[profile.identityID] ?? [:]
            }
            guard let splitAction = GhostIdentityPuritySplitter.evaluateIdentity(
                identityID: profile.identityID,
                trackObservations: trackObservations
            ) else {
                continue
            }

            var updatedOriginal = profile
            for moved in splitAction.movedTrackKeys {
                updatedOriginal.memberTrackKeys.remove(moved)
            }
            updatedOriginal.resolvedSex = splitAction.majoritySex
            identityResolver.upsertGallery(updatedOriginal)

            let splitProfile = GhostIdentityGalleryProfile(
                identityID: splitAction.newIdentityID,
                kind: "person",
                displayCode: "P-SPLIT-\(splitAction.newIdentityID.prefix(4))",
                centroid: profile.centroid,
                resolvedSex: splitAction.minoritySex,
                resolvedSexConfidence: 0.75,
                firstSeenAt: profile.firstSeenAt,
                lastSeenAt: profile.lastSeenAt,
                lastCameraID: profile.lastCameraID,
                memberTrackKeys: Set(splitAction.movedTrackKeys)
            )
            identityResolver.upsertGallery(splitProfile)
            identityResolver.recordCannotLink(updatedOriginal.identityID, splitProfile.identityID)
            try? trackingStore?.upsertGhostIdentityProfile(updatedOriginal)
            try? trackingStore?.upsertGhostIdentityProfile(splitProfile)
        }
    }

    public func runContinuitySweeperIfNeeded(now: Date = Date()) async {
        let facetsSnapshot: [String: GhostFacetSummary] = lock.withLock {
            let elapsed = now.timeIntervalSince(lastContinuitySweepAt)
            guard elapsed >= Self.continuitySweepIntervalSec || cropsSinceLastSweep >= 8 else {
                return [:]
            }
            lastContinuitySweepAt = now
            cropsSinceLastSweep = 0
            return facetsByIdentityID
        }
        guard !facetsSnapshot.isEmpty || identityResolver.allGalleries().count >= 2 else { return }

        let galleries = identityResolver.allGalleries()
        let evalBatch = GhostContinuitySweeper.evaluateGalleries(
            galleries: galleries,
            facetsByIdentity: facetsSnapshot,
            existingCannotLinks: []
        )

        for cannotLink in evalBatch.newCannotLinks {
            identityResolver.recordCannotLink(cannotLink.idA, cannotLink.idB)
        }

        // Layer C: Text LLM Deduplication for ambiguous pairs
        if !evalBatch.layerCTextPairs.isEmpty {
            let lines = evalBatch.layerCTextPairs.map { a, fA, b, fB in
                "Pair (\(a.identityID), \(b.identityID)): A=[\(fA?.summaryText ?? a.displayCode)], B=[\(fB?.summaryText ?? b.displayCode)]"
            }.joined(separator: "\n")
            let lang = aiClient.configuration().preferredLanguage
            let prompt = GhostPromptLibrary.textDedupPrompt(pairsDescription: lines, language: lang)
            let verdict = await aiClient.generateStructured(
                lane: .background,
                tier: .nano,
                prompt: prompt,
                responseType: GhostTextDedupResult.self,
                fallbackFactory: { GhostTextDedupResult(pairs: []) }
            )
            for p in verdict.pairs where !p.sameIdentity && p.confidence >= 0.75 {
                identityResolver.recordCannotLink(p.idA, p.idB)
            }
        }
    }

    // MARK: - Step C: Real-Time 4-Frame Critical Alert Ring + 16-Frame Alert Mentor + Narrative Sampler

    public func offerCameraFrame(
        cameraID: UUID,
        cameraName: String,
        cgImage: CGImage,
        hasActiveObjects: Bool,
        activeAlertRulesDescription: String = "Weapon, Violence, Fallen Person, Perimeter Intrusion, Fire/Smoke",
        now: Date = Date()
    ) async {
        let (ringReady, narrativeBatch, prevNarrativeSummary): ([GhostAlertRingFrame]?, [GhostAlertRingFrame]?, String?) = lock.withLock {
            var rReady: [GhostAlertRingFrame]?
            var nBatch: [GhostAlertRingFrame]?
            var pSummary: String?

            var ringState = alertRingsByCamera[cameraID] ?? GhostCameraAlertRingState()
            if ringState.offerFrame(cgImage, at: now) {
                rReady = ringState.ringFrames
            }
            alertRingsByCamera[cameraID] = ringState

            var narState = narrativeStatesByCamera[cameraID] ?? GhostCameraNarrativeState()
            if let flushed = narState.offerFrame(cgImage, hasActiveObjects: hasActiveObjects, at: now) {
                nBatch = flushed
                pSummary = narState.lastChapterSummary
            }
            narrativeStatesByCamera[cameraID] = narState
            return (rReady, nBatch, pSummary)
        }

        if let ringReady, canDispatchAlertEvaluation(now: now) {
            await evaluateCriticalAlertRing(
                cameraID: cameraID,
                cameraName: cameraName,
                frames: ringReady,
                activeRulesDescription: activeAlertRulesDescription,
                now: now
            )
        }

        if let narrativeBatch {
            await flushNarrativeChapter(
                cameraID: cameraID,
                cameraName: cameraName,
                frames: narrativeBatch,
                previousSummary: prevNarrativeSummary
            )
        }
    }

    private func canDispatchAlertEvaluation(now: Date) -> Bool {
        lock.withLock {
            recentAlertTimestamps.removeAll { now.timeIntervalSince($0) > 60.0 }
            guard recentAlertTimestamps.count < Self.alertMaxRPM else { return false }
            recentAlertTimestamps.append(now)
            return true
        }
    }

    private func evaluateCriticalAlertRing(
        cameraID: UUID,
        cameraName: String,
        frames: [GhostAlertRingFrame],
        activeRulesDescription: String,
        now: Date
    ) async {
        let cells = frames.enumerated().map { idx, frame in
            GhostCollageCell(badgeIndex: idx + 1, itemID: "F-\(idx + 1)", cgImage: frame.cgImage)
        }
        guard let collage = GhostCollageBuilder.buildCollage(kind: .narrative, cells: cells) else { return }
        let lang = aiClient.configuration().preferredLanguage
        let prompt = GhostPromptLibrary.criticalAlertRingPrompt(
            cameraName: cameraName,
            activeRulesDescription: activeRulesDescription,
            language: lang
        )

        let batch = await aiClient.generateStructured(
            lane: .alert,
            tier: .mini,
            prompt: prompt,
            jpegImages: [collage.jpegData],
            responseType: GhostCriticalAlertBatch.self,
            fallbackFactory: { GhostCriticalAlertBatch(sceneStatus: "clear", alerts: []) }
        )

        for detection in batch.alerts where detection.triggered && detection.confidence >= 0.65 {
            let dedupKey = "\(cameraID.uuidString)|\(detection.ruleCode)"
            let isDuplicate: Bool = lock.withLock {
                if let prev = lastAlertDedupByKey[dedupKey], now.timeIntervalSince(prev) < Self.alertDedupWindowSec {
                    return true
                }
                lastAlertDedupByKey[dedupKey] = now
                return false
            }
            guard !isDuplicate else { continue }

            let mentorBrief = await runAlertMentorInvestigation(
                alertID: UUID().uuidString,
                cameraID: cameraID,
                cameraName: cameraName,
                detection: detection
            )

            lock.withLock {
                recentCriticalAlerts.insert(
                    (cameraID: cameraID, cameraName: cameraName, detection: detection, mentorBrief: mentorBrief, triggeredAt: now),
                    at: 0
                )
                if recentCriticalAlerts.count > 50 {
                    recentCriticalAlerts.removeLast()
                }
            }
        }
    }

    public func runAlertMentorInvestigation(
        alertID: String,
        cameraID: UUID,
        cameraName: String,
        detection: GhostCriticalAlertDetection
    ) async -> GhostAlertMentorBrief? {
        let lookbackFrames: [GhostAlertRingFrame] = lock.withLock {
            alertRingsByCamera[cameraID]?.lookbackFrames ?? []
        }
        guard !lookbackFrames.isEmpty else { return nil }

        let cells = lookbackFrames.enumerated().map { idx, f in
            GhostCollageCell(badgeIndex: idx + 1, itemID: "LB-\(idx + 1)", cgImage: f.cgImage)
        }
        guard let collage = GhostCollageBuilder.buildCollage(kind: .narrative, cells: cells) else {
            return nil
        }

        let lang = aiClient.configuration().preferredLanguage
        let prompt = GhostPromptLibrary.alertMentorPrompt(
            alertID: alertID,
            cameraName: cameraName,
            initialAlertTitle: detection.title,
            language: lang
        )

        let brief = await aiClient.generateStructured(
            lane: .alert,
            tier: .mini,
            prompt: prompt,
            jpegImages: [collage.jpegData],
            responseType: GhostAlertMentorBrief.self,
            fallbackFactory: {
                GhostAlertMentorBrief(
                    alertID: alertID,
                    confirmedThreat: true,
                    tacticalHeadline: detection.title,
                    precursorSummary: detection.evidenceSummary,
                    escalationTrajectory: "stable",
                    recommendedOperatorAction: "Проверить камеру \(cameraName)",
                    confidence: detection.confidence
                )
            }
        )
        try? trackingStore?.saveGhostAlertMentorBrief(cameraID: cameraID, brief: brief)
        return brief
    }

    private func flushNarrativeChapter(
        cameraID: UUID,
        cameraName: String,
        frames: [GhostAlertRingFrame],
        previousSummary: String?
    ) async {
        guard let startedAt = frames.first?.capturedAt,
              let endedAt = frames.last?.capturedAt else { return }
        let cells = frames.enumerated().map { idx, f in
            GhostCollageCell(badgeIndex: idx + 1, itemID: "N-\(idx + 1)", cgImage: f.cgImage)
        }
        guard let collage = GhostCollageBuilder.buildCollage(kind: .narrative, cells: cells) else { return }

        let lang = aiClient.configuration().preferredLanguage
        let prompt = GhostPromptLibrary.narrativeChapterPrompt(
            cameraName: cameraName,
            frameCount: frames.count,
            previousChapterSummary: previousSummary,
            language: lang
        )

        let chapter = await aiClient.generateStructured(
            lane: .background,
            tier: .mini,
            prompt: prompt,
            jpegImages: [collage.jpegData],
            responseType: GhostTemporalNarrativeResult.self,
            fallbackFactory: {
                GhostTemporalNarrativeResult(
                    chapterTitle: "\(cameraName) — Штатная обстановка",
                    summary: "Движение в пределах нормы.",
                    atmosphere: "calm",
                    events: []
                )
            }
        )

        lock.withLock {
            narrativeStatesByCamera[cameraID]?.lastChapterSummary = chapter.summary
        }

        try? trackingStore?.saveGhostNarrativeChapter(
            cameraID: cameraID,
            cameraName: cameraName,
            startedAt: startedAt,
            endedAt: endedAt,
            chapter: chapter
        )
    }

    // MARK: - Step D: Spoken Briefing Service (18s Priority Feed)

    public func generateSpokenBriefingIfDue(now: Date = Date()) async -> GhostHCCard? {
        let contextToAnnounce: (text: String, urgency: String)? = lock.withLock {
            guard now.timeIntervalSince(lastSpokenBriefingAt) >= Self.spokenBriefingIntervalSec else {
                return nil
            }
            lastSpokenBriefingAt = now

            if let latestAlert = recentCriticalAlerts.first,
               now.timeIntervalSince(latestAlert.triggeredAt) <= 60.0 {
                let headline = latestAlert.mentorBrief?.tacticalHeadline ?? latestAlert.detection.title
                return ("CRITICAL ALERT on \(latestAlert.cameraName): \(headline)", "critical")
            }
            if let latestIdentity = identityResolver.allGalleries().max(by: { $0.lastSeenAt < $1.lastSeenAt }),
               now.timeIntervalSince(latestIdentity.lastSeenAt) <= 45.0 {
                let facet = facetsByIdentityID[latestIdentity.identityID]?.summaryText ?? latestIdentity.kind
                return ("Subject \(latestIdentity.displayCode) (\(facet)) active on camera \(latestIdentity.lastCameraID)", "routine")
            }
            return nil
        }

        guard let contextToAnnounce else { return nil }
        let lang = aiClient.configuration().preferredLanguage
        let prompt = GhostPromptLibrary.spokenBriefingCardPrompt(
            eventContext: contextToAnnounce.text,
            language: lang
        )
        let card = await aiClient.generateStructured(
            lane: .background,
            tier: .nano,
            prompt: prompt,
            responseType: GhostHCCard.self,
            fallbackFactory: {
                GhostHCCard(
                    spokenLine: GhostOpSec.sanitizeText(contextToAnnounce.text),
                    badgeLabel: contextToAnnounce.urgency.uppercased(),
                    urgency: contextToAnnounce.urgency
                )
            }
        )

        lock.withLock {
            recentSpokenCards.insert(card, at: 0)
            if recentSpokenCards.count > 25 {
                recentSpokenCards.removeLast()
            }
        }
        return card
    }

    // MARK: - Step E: Ghost Chat / Tactical Research Agent with Tool Context & live_look

    public func askGhostChatAgent(
        question: String,
        liveCameraImages: [Data] = []
    ) async -> GhostChatPresentAnswer {
        let detectedLang = GhostPromptLanguage.detect(
            from: question,
            fallback: aiClient.configuration().preferredLanguage
        )
        let expandedTerms = GhostLexicon.expandQueryTerms(question)

        let galleries = identityResolver.allGalleries().sorted { $0.lastSeenAt > $1.lastSeenAt }
        let facetsSnapshot: [String: GhostFacetSummary] = lock.withLock {
            facetsByIdentityID
        }

        // Build local dossier + route + attribute matches for the agent context
        let matchingProfiles = galleries.prefix(20).map { g -> String in
            let facet = facetsSnapshot[g.identityID]
            let desc = facet?.summaryText ?? g.kind
            let plate = g.plateNumber.map { " plate=\($0)" } ?? ""
            let sex = g.resolvedSex != .unknown ? " sex=\(g.resolvedSex.rawValue)" : ""
            let cams = Array(g.activeWindowsByCamera.keys).sorted().joined(separator: " -> ")
            return "- \(g.displayCode) (id=\(g.identityID), kind=\(g.kind)\(sex)\(plate)): \(desc) | route: [\(cams)]"
        }.joined(separator: "\n")

        let chapters = (try? trackingStore?.loadGhostNarrativeChapters(limit: 8)) ?? []
        let narrativeContext = chapters.map { item in
            "- [\(item.cameraName)] \(item.chapter.chapterTitle): \(item.chapter.summary)"
        }.joined(separator: "\n")

        let systemPrompt = GhostPromptLibrary.ghostChatSystemPrompt(language: detectedLang)
        let fullPrompt = """
        \(systemPrompt)

        Operator Question: "\(question)"
        Expanded Multilingual Search Terms: \(Array(expandedTerms).sorted().prefix(16).joined(separator: ", "))

        Active Identity Dossiers & Cross-Camera Routes:
        \(matchingProfiles.isEmpty ? "No active identities." : matchingProfiles)

        Recent Ghost Memory Narrative Chapters:
        \(narrativeContext.isEmpty ? "No narrative chapters yet." : narrativeContext)

        Return strict JSON matching `GhostChatPresentAnswer`:
        {
          "answerMarkdown": "...",
          "citedIdentityIDs": ["P-001"],
          "citedCameraIDs": [],
          "confidence": 0.92,
          "followUpSuggestions": ["..."],
          "proposedActions": []
        }
        """

        let response = await aiClient.generateStructured(
            lane: .chat,
            tier: .full,
            prompt: fullPrompt,
            jpegImages: liveCameraImages,
            responseType: GhostChatPresentAnswer.self,
            fallbackFactory: {
                let topCode = galleries.first?.displayCode ?? "N/A"
                let fallbackText: String
                switch detectedLang {
                case .ru:
                    fallbackText = "Проанализировано досье (\(galleries.count) объектов). Последний активный объект: `\(topCode)`."
                case .he:
                    fallbackText = "נותחו תיקי זהות (\(galleries.count) אובייקטים). אובייקט פעיל אחרון: `\(topCode)`."
                case .en:
                    fallbackText = "Analyzed \(galleries.count) identity dossiers. Most recent active subject: `\(topCode)`."
                }
                return GhostChatPresentAnswer(
                    answerMarkdown: fallbackText,
                    citedIdentityIDs: galleries.first.map { [$0.displayCode] } ?? [],
                    confidence: 0.85
                )
            }
        )

        var sanitized = response
        sanitized.answerMarkdown = GhostOpSec.sanitizeText(response.answerMarkdown)
        return sanitized
    }
}
