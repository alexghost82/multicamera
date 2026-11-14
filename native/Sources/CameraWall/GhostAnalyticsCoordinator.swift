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

// MARK: - 3. Narrative Sampler State per Camera ("Ghost Memory")

public struct GhostCameraNarrativeState: Sendable {
    public static let intervalSampleSec: TimeInterval = 5.0
    public static let objectHeartbeatSec: TimeInterval = 8.0
    public static let flushFrameThreshold: Int = 28
    public static let flushTimeoutSec: TimeInterval = 480.0

    public var mode: GhostNarrativeTriggerMode = .object
    public var sampledFrames: [GhostNarrativeSampledFrame] = []
    public var chapterStartedAt: Date?
    public var lastSampledAt: Date = .distantPast
    public var lastChapterSummary: String?
    public var previousThumbLuma: [UInt8]?
    public var previousHistogram: [Float]?
    public var seenTrackIDsInChapter: Set<String> = []
    public var seenIdentityIDsInChapter: Set<String> = []

    public init(mode: GhostNarrativeTriggerMode = .object) {
        self.mode = mode
    }

    public mutating func offerFrame(
        _ image: CGImage,
        activeLabels: [String],
        activeTrackIDs: [String] = [],
        activeIdentityIDs: [String] = [],
        modeOverride: GhostNarrativeTriggerMode? = nil,
        at timestamp: Date
    ) -> (frames: [GhostNarrativeSampledFrame], sightingCount: Int, identityCount: Int)? {
        let activeMode = modeOverride ?? mode
        let hasStory = GhostNarrativeSamplerRules.hasStoryObject(labels: activeLabels) || !activeTrackIDs.isEmpty

        let newTracks = Set(activeTrackIDs).subtracting(seenTrackIDsInChapter)
        var shouldSample = false
        var sampleReason: GhostNarrativeSampleReason = .sceneChanged

        switch activeMode {
        case .object:
            if !hasStory && sampledFrames.isEmpty {
                return nil
            }
            if !newTracks.isEmpty {
                shouldSample = true
                sampleReason = .newObject
            } else if hasStory && timestamp.timeIntervalSince(lastSampledAt) >= Self.objectHeartbeatSec {
                shouldSample = true
                sampleReason = sampledFrames.isEmpty ? .firstFrame : .objectHeartbeat
            }
        case .interval:
            if timestamp.timeIntervalSince(lastSampledAt) >= Self.intervalSampleSec {
                let eval = GhostNarrativeSamplerRules.evaluateSceneChange(
                    cgImage: image,
                    previousLuma: previousThumbLuma,
                    previousHistogram: previousHistogram
                )
                previousThumbLuma = eval.luma
                previousHistogram = eval.histogram
                if eval.changed || sampledFrames.isEmpty {
                    shouldSample = true
                    sampleReason = sampledFrames.isEmpty ? .firstFrame : .sceneChanged
                }
            }
        }

        if shouldSample {
            lastSampledAt = timestamp
            if chapterStartedAt == nil {
                chapterStartedAt = timestamp
            }
            seenTrackIDsInChapter.formUnion(activeTrackIDs)
            seenIdentityIDsInChapter.formUnion(activeIdentityIDs)
            sampledFrames.append(
                GhostNarrativeSampledFrame(
                    cgImage: image,
                    capturedAt: timestamp,
                    activeLabels: activeLabels,
                    activeTrackIDs: activeTrackIDs,
                    activeIdentityIDs: activeIdentityIDs,
                    reason: sampleReason
                )
            )
        }

        let elapsed = timestamp.timeIntervalSince(chapterStartedAt ?? timestamp)
        if sampledFrames.count >= Self.flushFrameThreshold || (sampledFrames.count >= 4 && elapsed >= Self.flushTimeoutSec) {
            return drainForFlush()
        }
        return nil
    }

    public mutating func forceClose() -> (frames: [GhostNarrativeSampledFrame], sightingCount: Int, identityCount: Int)? {
        guard !sampledFrames.isEmpty else { return nil }
        return drainForFlush()
    }

    private mutating func drainForFlush() -> (frames: [GhostNarrativeSampledFrame], sightingCount: Int, identityCount: Int) {
        let thinned = GhostNarrativeSamplerRules.thinFrames(sampledFrames, maxFrames: Self.flushFrameThreshold)
        let sCount = seenTrackIDsInChapter.count
        let iCount = seenIdentityIDsInChapter.count
        sampledFrames.removeAll(keepingCapacity: true)
        chapterStartedAt = nil
        seenTrackIDsInChapter.removeAll(keepingCapacity: true)
        seenIdentityIDsInChapter.removeAll(keepingCapacity: true)
        return (thinned, sCount, iCount)
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
    public static let storageJanitorIntervalSec: TimeInterval = 300.0

    public static let alertMaxRPM: Int = 20
    public static let alertDedupWindowSec: TimeInterval = 30.0

    private let lock = NSLock()
    public let aiClient: GhostAIClient
    public let identityResolver: GhostIdentityResolver
    public let registryClient = GhostIsraeliVehicleRegistryClient()
    public let memoryGuard = GhostMemoryGuard()
    public var janitorPolicy = GhostStorageJanitorPolicy()
    private weak var trackingStore: LocalTrackingStore?

    // Stateful Schedulers & Queues
    private var captureScheduler = GhostCaptureScheduler()
    private var cropWindowsByTrack: [String: GhostCropWindow] = [:]
    private var stitcher = GhostTrackletStitcher()
    private var observationStrideCounter: Int = 0

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
    private var lastJanitorPassAt: Date = .distantPast

    public private(set) var recentSpokenCards: [GhostHCCard] = []
    public private(set) var recentCriticalAlerts: [(cameraID: UUID, cameraName: String, detection: GhostCriticalAlertDetection, mentorBrief: GhostAlertMentorBrief?, triggeredAt: Date)] = []

    public init(
        aiClient: GhostAIClient,
        trackingStore: LocalTrackingStore? = nil
    ) {
        let initialProfiles = (try? trackingStore?.loadGhostIdentityProfiles(limit: 500)) ?? []
        let initialLinks = (try? trackingStore?.loadGhostCameraLinks()) ?? []
        let initialCannotLinks = (try? trackingStore?.loadGhostCannotLinkPairs()) ?? []
        let initialDossiers = (try? trackingStore?.loadAllGhostIdentityDossiers()) ?? []

        self.aiClient = aiClient
        self.trackingStore = trackingStore
        self.aiClient.attachCacheStore(trackingStore)
        self.identityResolver = GhostIdentityResolver(
            galleries: initialProfiles,
            topology: GhostCameraTopology(links: initialLinks)
        )
        for (a, b) in initialCannotLinks {
            self.identityResolver.recordCannotLink(a, b)
        }
        for dossier in initialDossiers {
            self.facetsByIdentityID[dossier.identityID] = dossier.facetSummary
        }
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
        let memState = memoryGuard.evaluate()
        if memState.strideMultiplier > 1 {
            let skip: Bool = lock.withLock {
                observationStrideCounter += 1
                return (observationStrideCounter % memState.strideMultiplier) != 0
            }
            if skip && embedding == nil {
                return nil
            }
        }

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
            let currentLinks = identityResolver.currentTopology().allLinks
            if !currentLinks.isEmpty {
                try? trackingStore?.saveGhostCameraLinks(currentLinks)
            }
        }

        let resolvedIdentityID = decision?.identityID ?? trackKey
        try? trackingStore?.saveGhostTrackVisualMetadata(
            trackID: trackID,
            cropQuality: qualityBreakdown.totalScore,
            chromaPrint: chromaPrint,
            hsvHistogram: hsvHistogram,
            resolvedSex: .unknown,
            identityState: decision?.state,
            identityScore: decision?.score,
            ghostIdentityID: decision?.identityID,
            isBest: acceptedIntoTopK
        )

        if chromaPrint != nil {
            try? trackingStore?.indexGhostTrackKnowledge(
                trackID: trackKey,
                identityID: resolvedIdentityID,
                cameraID: camKey,
                capturedAt: now,
                cropQuality: qualityBreakdown.totalScore,
                description: nil,
                chromaSignature: chromaPrint,
                kind: kind
            )
        }

        return decision
    }

    // MARK: - Step B: Periodic Background Tick (DescribeGate, PlateBatch, ContinuitySweeper, PuritySplitter, StorageJanitor)

    public func runPeriodicMaintenanceTick(now: Date = Date()) async {
        _ = memoryGuard.evaluate()
        await flushDescribeGateIfNeeded(now: now)
        await flushPlateBatchIfNeeded(now: now)
        await runPuritySplitterIfNeeded(now: now)
        await runContinuitySweeperIfNeeded(now: now)
        runStorageJanitorIfNeeded(now: now)
    }

    @discardableResult
    public func runStorageJanitorIfNeeded(force: Bool = false, now: Date = Date()) -> GhostStorageJanitorReport? {
        let shouldRun: Bool = lock.withLock {
            guard force || now.timeIntervalSince(lastJanitorPassAt) >= Self.storageJanitorIntervalSec else {
                return false
            }
            lastJanitorPassAt = now
            return true
        }
        guard shouldRun, let store = trackingStore else { return nil }
        return try? store.runGhostStorageJanitorPass(policy: janitorPolicy, now: now)
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
            taskType: "bulk_describe",
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

                // Persist into Semantic Knowledge Layer (ghost_attribute_index + ghost_identity_dossiers + ghost_visits + FTS5)
                try? trackingStore?.indexGhostTrackKnowledge(
                    trackID: trackKey,
                    identityID: identityID,
                    cameraID: sourceItem.cameraID.uuidString,
                    capturedAt: sourceItem.enqueuedAt,
                    cropQuality: sourceItem.cropQuality,
                    description: desc,
                    chromaSignature: matchingGallery?.chromaPrint,
                    displayName: matchingGallery?.displayName ?? matchingGallery?.displayCode,
                    kind: sourceItem.kind
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
            taskType: "plate_ocr",
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
        let cannotLinkSet = Set(identityResolver.allCannotLinkPairs().map { "\($0.0)|\($0.1)" })
        let evalBatch = GhostContinuitySweeper.evaluateGalleries(
            galleries: galleries,
            facetsByIdentity: facetsSnapshot,
            existingCannotLinks: cannotLinkSet
        )

        for cannotLink in evalBatch.newCannotLinks {
            identityResolver.recordCannotLink(cannotLink.idA, cannotLink.idB)
            try? trackingStore?.saveGhostDedupDecision(cannotLink, decidedAt: now)
        }
        for merge in evalBatch.autoMerges {
            try? trackingStore?.saveGhostDedupDecision(merge, decidedAt: now)
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
                taskType: "text_dedup",
                prompt: prompt,
                responseType: GhostTextDedupResult.self,
                fallbackFactory: { GhostTextDedupResult(pairs: []) }
            )
            for p in verdict.pairs where !p.sameIdentity && p.confidence >= 0.75 {
                identityResolver.recordCannotLink(p.idA, p.idB)
                let decision = GhostSweeperPairDecision(
                    idA: p.idA,
                    idB: p.idB,
                    layer: .layerCTextLLM,
                    shouldMerge: false,
                    recordCannotLink: true,
                    confidence: p.confidence,
                    reason: p.reason
                )
                try? trackingStore?.saveGhostDedupDecision(decision, decidedAt: now)
            }
        }
    }

    // MARK: - Step C: Real-Time 4-Frame Critical Alert Ring + 16-Frame Alert Mentor + Narrative Sampler ("Ghost Memory")

    public func offerCameraFrame(
        cameraID: UUID,
        cameraName: String,
        cgImage: CGImage,
        hasActiveObjects: Bool,
        activeLabels: [String] = [],
        activeTrackIDs: [String] = [],
        activeIdentityIDs: [String] = [],
        narrativeMode: GhostNarrativeTriggerMode? = nil,
        activeAlertRulesDescription: String = "Weapon, Violence, Fallen Person, Perimeter Intrusion, Fire/Smoke",
        now: Date = Date()
    ) async {
        let effectiveLabels = activeLabels.isEmpty ? (hasActiveObjects ? ["person"] : []) : activeLabels
        let (ringReady, narrativeFlush, prevNarrativeSummary): ([GhostAlertRingFrame]?, (frames: [GhostNarrativeSampledFrame], sightingCount: Int, identityCount: Int)?, String?) = lock.withLock {
            var rReady: [GhostAlertRingFrame]?
            var nFlush: (frames: [GhostNarrativeSampledFrame], sightingCount: Int, identityCount: Int)?
            var pSummary: String?

            var ringState = alertRingsByCamera[cameraID] ?? GhostCameraAlertRingState()
            if ringState.offerFrame(cgImage, at: now) {
                rReady = ringState.ringFrames
            }
            alertRingsByCamera[cameraID] = ringState

            var narState = narrativeStatesByCamera[cameraID] ?? GhostCameraNarrativeState()
            if let flushed = narState.offerFrame(
                cgImage,
                activeLabels: effectiveLabels,
                activeTrackIDs: activeTrackIDs,
                activeIdentityIDs: activeIdentityIDs,
                modeOverride: narrativeMode,
                at: now
            ) {
                nFlush = flushed
                pSummary = narState.lastChapterSummary
            }
            narrativeStatesByCamera[cameraID] = narState
            return (rReady, nFlush, pSummary)
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

        if let narrativeFlush {
            await flushNarrativeChapter(
                cameraID: cameraID,
                cameraName: cameraName,
                sampledFrames: narrativeFlush.frames,
                sightingCount: narrativeFlush.sightingCount,
                identityCount: narrativeFlush.identityCount,
                previousSummary: prevNarrativeSummary
            )
        }
    }

    /// Immediately closes and summarizes the in-progress Ghost Memory chapter for a camera (e.g., on camera stop or operator button).
    @discardableResult
    public func forceCloseNarrativeChapter(cameraID: UUID, cameraName: String) async -> GhostNarrativeChapterRecord? {
        let (flushed, prevSummary): ((frames: [GhostNarrativeSampledFrame], sightingCount: Int, identityCount: Int)?, String?) = lock.withLock {
            guard var state = narrativeStatesByCamera[cameraID],
                  let drained = state.forceClose() else {
                return (nil, nil)
            }
            let prev = state.lastChapterSummary
            narrativeStatesByCamera[cameraID] = state
            return (drained, prev)
        }
        guard let flushed else { return nil }
        return await flushNarrativeChapter(
            cameraID: cameraID,
            cameraName: cameraName,
            sampledFrames: flushed.frames,
            sightingCount: flushed.sightingCount,
            identityCount: flushed.identityCount,
            previousSummary: prevSummary
        )
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
            taskType: "critical_alert_ring",
            prompt: prompt,
            jpegImages: [collage.jpegData],
            useContentCache: false,
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
            taskType: "alert_mentor",
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

    @discardableResult
    private func flushNarrativeChapter(
        cameraID: UUID,
        cameraName: String,
        sampledFrames: [GhostNarrativeSampledFrame],
        sightingCount: Int,
        identityCount: Int,
        previousSummary: String?
    ) async -> GhostNarrativeChapterRecord? {
        guard let startedAt = sampledFrames.first?.capturedAt,
              let endedAt = sampledFrames.last?.capturedAt else { return nil }
        let thinned = GhostNarrativeSamplerRules.thinFrames(sampledFrames, maxFrames: GhostCameraNarrativeState.flushFrameThreshold)
        let cells = thinned.enumerated().map { idx, f in
            GhostCollageCell(badgeIndex: idx + 1, itemID: "N-\(idx + 1)", cgImage: f.cgImage)
        }
        guard let collage = GhostCollageBuilder.buildCollage(kind: .narrative, cells: cells) else { return nil }

        // If previousSummary is nil in RAM (e.g. after app restart), fetch the latest chapter for this camera from SQLite
        let effectivePreviousSummary: String? = previousSummary ?? {
            guard let latest = try? trackingStore?.loadGhostNarrativeChapterRecords(cameraID: cameraID, limit: 1).first else {
                return nil
            }
            return latest.effectiveSummary
        }()

        let lang = aiClient.configuration().preferredLanguage
        let prompt = GhostPromptLibrary.narrativeChapterPrompt(
            cameraName: cameraName,
            frameCount: thinned.count,
            previousChapterSummary: effectivePreviousSummary,
            language: lang
        )

        let chapter = await aiClient.generateStructured(
            lane: .background,
            tier: .mini,
            taskType: "narrative_chapter",
            prompt: prompt,
            jpegImages: [collage.jpegData],
            responseType: GhostTemporalNarrativeResult.self,
            fallbackFactory: {
                let deltaText = effectivePreviousSummary.map { "Без существенных отклонений от предыдущей главы (\($0.prefix(40)))." }
                return GhostTemporalNarrativeResult(
                    chapterTitle: "\(cameraName) — Штатная обстановка",
                    summary: "Зафиксировано \(thinned.count) ключевых кадров, объектов: \(max(sightingCount, identityCount)). Движение в пределах нормы.",
                    deltaFromPrevious: deltaText,
                    atmosphere: "calm",
                    events: []
                )
            }
        )

        lock.withLock {
            narrativeStatesByCamera[cameraID]?.lastChapterSummary = chapter.summary
        }

        let record = GhostNarrativeChapterRecord(
            chapterID: UUID().uuidString,
            cameraID: cameraID,
            cameraName: cameraName,
            startedAt: startedAt,
            endedAt: endedAt,
            narrative: chapter,
            aiSummary: chapter.summary,
            operatorText: nil,
            operatorMarked: false,
            pinned: false,
            frameCount: thinned.count,
            sightingCount: sightingCount,
            identityCount: identityCount,
            collagePath: nil
        )
        try? trackingStore?.saveGhostNarrativeChapterRecord(record, collageJPEG: collage.jpegData)
        return record
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
            taskType: "spoken_briefing",
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

    // MARK: - Step E: Ghost Chat / Tactical Research Agent, Tool Registry, Focus Memory & Action Execution

    /// Executes a read-only agent tool and records an audit entry in `ghost_chat_tool_calls`.
    public func executeAgentTool(
        toolName: String,
        arguments: [String: String] = [:],
        threadID: String = "default",
        liveCameraImages: [Data] = [],
        now: Date = Date()
    ) async -> (outputJSON: String, resultRows: Int, savedClipID: String?) {
        let start = Date()
        var outputDict: [String: Any] = ["tool": toolName]
        var rowsCount = 0
        var savedClipID: String?
        var errorMsg: String?

        do {
            switch toolName {
            case "search_identities_by_attributes":
                var facets: [String: String] = [:]
                for key in ["upper_color", "lower_color", "vehicle_color", "color", "sex", "age_group", "upper_wear", "lower_wear", "headwear", "bag", "make", "model", "plate_number"] {
                    if let v = arguments[key], !v.isEmpty { facets[key] = v }
                }
                let matches = (try trackingStore?.searchGhostIdentitiesByAttributes(
                    kind: arguments["kind"],
                    facets: facets,
                    freeTextQuery: arguments["query"],
                    cameraID: arguments["camera_id"],
                    limit: Int(arguments["limit"] ?? "20") ?? 20
                )) ?? []
                rowsCount = matches.count
                outputDict["matches"] = matches.map {
                    ["identity_id": $0.identityID, "display_name": $0.displayName ?? $0.identityID, "summary": $0.summaryLine]
                }

            case "get_identity_dossier":
                let id = arguments["identity_id"] ?? ""
                if let d = try trackingStore?.getGhostIdentityDossier(identityID: id) {
                    rowsCount = 1
                    outputDict["dossier"] = [
                        "identity_id": d.identityID,
                        "display_name": d.displayName ?? d.identityID,
                        "kind": d.kind,
                        "summary_line": d.summaryLine,
                        "facets": d.facets,
                        "alternatives": d.alternatives
                    ]
                } else {
                    outputDict["dossier"] = NSNull()
                }

            case "get_identity_route":
                let id = arguments["identity_id"] ?? ""
                if let route = try trackingStore?.getGhostIdentityRoute(identityID: id, topology: identityResolver.currentTopology()) {
                    rowsCount = route.legs.count
                    outputDict["ordered_cameras"] = route.orderedCameras
                    outputDict["sightings_count"] = route.sightingsCount
                    outputDict["legs"] = route.legs.map {
                        [
                            "from": $0.fromCameraID,
                            "to": $0.toCameraID,
                            "transit_sec": $0.transitSeconds,
                            "plausibility": $0.plausibility.rawValue
                        ]
                    }
                }

            case "who_was_present":
                let windowSec = Double(arguments["window_seconds"] ?? "3600") ?? 3600.0
                let since = now.addingTimeInterval(-windowSec)
                let present = (try trackingStore?.whoWasPresent(
                    cameraID: arguments["camera_id"],
                    since: since,
                    until: now,
                    kind: arguments["kind"]
                )) ?? []
                rowsCount = present.count
                outputDict["present"] = present.map { ["identity_id": $0.identityID, "summary": $0.summaryLine] }

            case "list_visits":
                let visits = (try trackingStore?.listGhostVisits(
                    identityID: arguments["identity_id"],
                    cameraID: arguments["camera_id"],
                    limit: Int(arguments["limit"] ?? "25") ?? 25
                )) ?? []
                rowsCount = visits.count
                outputDict["visits"] = visits.map {
                    [
                        "visit_id": $0.visitID,
                        "identity_id": $0.identityID,
                        "cameras": $0.cameraIDs,
                        "sighting_count": $0.sightingCount,
                        "best_track_id": $0.bestTrackID
                    ]
                }

            case "find_companions":
                let id = arguments["identity_id"] ?? ""
                let companions = (try trackingStore?.findGhostCompanions(identityID: id)) ?? []
                rowsCount = companions.count
                outputDict["companions"] = companions.map {
                    [
                        "companion_identity_id": $0.companionIdentityID,
                        "co_sightings": $0.coSightingCount,
                        "shared_cameras": $0.sharedCameras
                    ]
                }

            case "get_channel_narrative":
                let camUUID = arguments["camera_id"].flatMap(UUID.init(uuidString:))
                let chaps = (try trackingStore?.loadGhostNarrativeChapterRecords(cameraID: camUUID, limit: 10)) ?? []
                rowsCount = chaps.count
                outputDict["chapters"] = chaps.map {
                    [
                        "chapter_id": $0.chapterID,
                        "camera_name": $0.cameraName,
                        "title": $0.narrative.chapterTitle,
                        "summary": $0.effectiveSummary,
                        "pinned": $0.pinned,
                        "operator_marked": $0.operatorMarked
                    ]
                }

            case "get_camera_alert_history":
                let alerts: [[String: Any]] = lock.withLock {
                    recentCriticalAlerts.prefix(20).map { item in
                        [
                            "camera_id": item.cameraID.uuidString,
                            "camera_name": item.cameraName,
                            "title": item.detection.title,
                            "severity": item.detection.severity,
                            "confirmed": item.mentorBrief?.confirmedThreat ?? true
                        ]
                    }
                }
                rowsCount = alerts.count
                outputDict["alerts"] = alerts

            case "live_look":
                let camID = arguments["camera_id"] ?? "active"
                let camUUID = UUID(uuidString: camID)
                let recentChapters = (try? trackingStore?.loadGhostNarrativeChapterRecords(cameraID: camUUID, limit: 3)) ?? []
                let historyBlock = recentChapters.map { "[\($0.cameraName)] \($0.effectiveSummary)" }.joined(separator: " | ")
                let visualHit = !liveCameraImages.isEmpty || (arguments["force_hit"] == "true")
                let conf = visualHit ? 0.86 : 0.40
                outputDict["_history_block"] = historyBlock.isEmpty ? "No recent narrative history on camera." : historyBlock
                outputDict["visual_hit"] = visualHit
                outputDict["confidence"] = conf
                rowsCount = 1
                if visualHit && conf >= 0.55, let firstImg = liveCameraImages.first, let store = trackingStore {
                    if let clip = try? store.saveGhostChatClip(
                        threadID: threadID,
                        cameraID: camID,
                        clipData: firstImg,
                        fileExtension: "jpg",
                        createdAt: now
                    ) {
                        savedClipID = clip.clipID
                        outputDict["clip_id"] = clip.clipID
                    }
                }

            case "run_readonly_sql":
                let sql = arguments["sql"] ?? "SELECT identity_id, summary_line FROM ghost_identity_dossiers LIMIT 10"
                let rows = (try trackingStore?.executeReadOnlyGhostSQL(sql)) ?? []
                rowsCount = rows.count
                outputDict["rows"] = rows

            default:
                outputDict["status"] = "unknown_tool"
            }
        } catch {
            errorMsg = error.localizedDescription
            outputDict["error"] = error.localizedDescription
        }

        let elapsedMs = max(1, Int(Date().timeIntervalSince(start) * 1000.0))
        let argsJSON = (try? String(data: JSONEncoder().encode(arguments), encoding: .utf8)) ?? "{}"
        let outputData = (try? JSONSerialization.data(withJSONObject: outputDict)) ?? Data("{}".utf8)
        let outputJSON = String(data: outputData, encoding: .utf8) ?? "{}"

        try? trackingStore?.recordGhostToolCallAudit(
            GhostToolCallAuditRecord(
                threadID: threadID,
                toolName: toolName,
                argsJSON: argsJSON,
                resultRows: rowsCount,
                durationMs: elapsedMs,
                ok: errorMsg == nil,
                error: errorMsg,
                createdAt: now
            )
        )
        return (outputJSON, rowsCount, savedClipID)
    }

    public func askGhostChatAgent(
        question: String,
        threadID: String = "default",
        focusedIdentityID: String? = nil,
        liveCameraImages: [Data] = [],
        now: Date = Date()
    ) async -> GhostChatPresentAnswer {
        let strippedQuestion = GhostOpSec.stripPersona(question)
        let detectedLang = GhostPromptLanguage.detect(
            from: strippedQuestion,
            fallback: aiClient.configuration().preferredLanguage
        )
        let expandedTerms = GhostLexicon.expandQueryTerms(strippedQuestion)

        // 1. Ensure thread exists, record user message, and push explicit focus if supplied
        _ = try? trackingStore?.ensureGhostChatThread(
            threadID: threadID,
            title: String(strippedQuestion.prefix(60)),
            now: now
        )
        _ = try? trackingStore?.appendGhostChatMessage(
            GhostChatMessageRecord(
                threadID: threadID,
                role: "user",
                text: strippedQuestion,
                createdAt: now
            )
        )
        if let focusedIdentityID, !focusedIdentityID.isEmpty {
            try? trackingStore?.pushGhostThreadFocus(
                threadID: threadID,
                kind: "identity",
                refID: focusedIdentityID,
                pinned: true,
                now: now
            )
        }

        // 2. Consume any owed `function_call_output` debt from the previous turn's terminal `present_answer`
        let chainDebt = (try? trackingStore?.consumeGhostThreadPendingOutputs(threadID: threadID)) ?? (nil, [])

        // 3. Load Active Entity Focus block (top 6 entities for pronoun resolution) & prior thread messages
        let focusBlock = (try? trackingStore?.loadGhostThreadFocusBlock(threadID: threadID, limit: 6)) ?? ""
        let priorMessages = (try? trackingStore?.loadGhostChatMessages(threadID: threadID, limit: 12)) ?? []
        let conversationTranscript = priorMessages.dropLast().suffix(8).map { msg in
            "[\(msg.role.uppercased())]: \(msg.text)"
        }.joined(separator: "\n")

        // 4. Execute knowledge retrieval tools & optional live_look tool
        let searchToolOut = await executeAgentTool(
            toolName: "search_identities_by_attributes",
            arguments: ["query": strippedQuestion, "limit": "15"],
            threadID: threadID,
            now: now
        )
        var liveLookClipID: String?
        var liveLookContext = ""
        if !liveCameraImages.isEmpty {
            let liveOut = await executeAgentTool(
                toolName: "live_look",
                arguments: ["camera_id": "live"],
                threadID: threadID,
                liveCameraImages: liveCameraImages,
                now: now
            )
            liveLookClipID = liveOut.savedClipID
            liveLookContext = liveOut.outputJSON
        }

        let galleries = identityResolver.allGalleries().sorted { $0.lastSeenAt > $1.lastSeenAt }
        let facetsSnapshot: [String: GhostFacetSummary] = lock.withLock {
            facetsByIdentityID
        }

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

        \(focusBlock.isEmpty ? "" : focusBlock + "\n")
        \(conversationTranscript.isEmpty ? "" : "Prior Conversation Transcript:\n" + conversationTranscript + "\n")
        Operator Question: "\(strippedQuestion)"
        Expanded Multilingual Search Terms: \(Array(expandedTerms).sorted().prefix(16).joined(separator: ", "))

        Knowledge Layer Search Output:
        \(searchToolOut.outputJSON)

        \(liveLookContext.isEmpty ? "" : "Live Look Past+Present Verification:\n" + liveLookContext + "\n")
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

        let focusEntries = (try? trackingStore?.loadGhostThreadFocusEntries(threadID: threadID, limit: 6)) ?? []
        let response = await aiClient.generateStructured(
            lane: .chat,
            tier: .full,
            taskType: "ghost_chat",
            prompt: fullPrompt,
            jpegImages: liveCameraImages,
            previousResponseID: chainDebt.0,
            owedOutputs: chainDebt.1,
            useContentCache: false,
            responseType: GhostChatPresentAnswer.self,
            fallbackFactory: {
                let topCode = focusEntries.first?.refID ?? galleries.first?.displayCode ?? "N/A"
                let fallbackText: String
                switch detectedLang {
                case .ru:
                    fallbackText = "Проанализировано досье (\(galleries.count) объектов). Фокус расследования: `\(topCode)`."
                case .he:
                    fallbackText = "נותחו תיקי זהות (\(galleries.count) אובייקטים). מוקד החקירה: `\(topCode)`."
                case .en:
                    fallbackText = "Analyzed \(galleries.count) identity dossiers. Investigation focus: `\(topCode)`."
                }
                return GhostChatPresentAnswer(
                    answerMarkdown: fallbackText,
                    citedIdentityIDs: topCode != "N/A" ? [topCode] : [],
                    confidence: 0.85
                )
            }
        )

        let sanitized = GhostOpSec.sanitizeAnswer(response)

        // 5. Auto-update thread focus with cited identities and bind cited cameras
        for citedID in sanitized.citedIdentityIDs {
            try? trackingStore?.pushGhostThreadFocus(
                threadID: threadID,
                kind: "identity",
                refID: citedID,
                now: now
            )
        }
        if !sanitized.citedCameraIDs.isEmpty {
            try? trackingStore?.bindGhostThreadCameras(
                threadID: threadID,
                cameraIDs: sanitized.citedCameraIDs,
                now: now
            )
        }

        // 6. Save proposed operator actions (`ghost_chat_actions`)
        for action in sanitized.proposedActions {
            try? trackingStore?.saveGhostChatAction(
                GhostChatActionRecord(
                    actionID: action.actionID,
                    threadID: threadID,
                    actionType: action.actionType,
                    title: action.title,
                    parameters: action.parameters,
                    status: "proposed",
                    createdAt: now
                )
            )
        }

        // 7. Persist assistant message and record `present_answer` call debt for next turn's `previous_response_id`
        let callID = "call_present_\(UUID().uuidString.prefix(8))"
        let newRespID = "resp_\(UUID().uuidString.prefix(12))"
        _ = try? trackingStore?.appendGhostChatMessage(
            GhostChatMessageRecord(
                threadID: threadID,
                role: "assistant",
                text: sanitized.answerMarkdown,
                structuredAnswer: sanitized,
                clipID: liveLookClipID,
                callID: callID,
                createdAt: now
            )
        )
        try? trackingStore?.setGhostThreadChainHead(
            threadID: threadID,
            lastResponseID: newRespID,
            pendingOutputs: [
                GhostPendingOutputDebt(callID: callID, outputJSON: "{\"status\":\"presented\"}")
            ],
            now: now
        )

        return sanitized
    }

    /// Confirms or rejects a proposed `GhostChatActionRecord` and executes the mutation if confirmed.
    @discardableResult
    public func reviewAndExecuteChatAction(
        actionID: String,
        confirmed: Bool,
        now: Date = Date()
    ) -> GhostChatActionRecord? {
        guard let updated = try? trackingStore?.resolveGhostChatAction(actionID: actionID, confirmed: confirmed, now: now) else {
            return nil
        }
        guard confirmed else { return updated }

        switch updated.actionType {
        case "rename_identity":
            if let id = updated.parameters["identity_id"],
               let newName = updated.parameters["new_name"] {
                if var profile = identityResolver.gallery(for: id) ?? identityResolver.allGalleries().first(where: { $0.displayCode == id }) {
                    profile.displayName = newName
                    identityResolver.upsertGallery(profile)
                    try? trackingStore?.upsertGhostIdentityProfile(profile)
                    _ = try? trackingStore?.rebuildGhostIdentityDossier(identityID: profile.identityID, displayName: newName, kind: profile.kind, now: now)
                } else {
                    _ = try? trackingStore?.rebuildGhostIdentityDossier(identityID: id, displayName: newName, now: now)
                }
            }

        case "merge_identities":
            if let sourceID = updated.parameters["source_id"],
               let targetID = updated.parameters["target_id"],
               sourceID != targetID,
               let sourceProf = identityResolver.gallery(for: sourceID),
               var targetProf = identityResolver.gallery(for: targetID) {
                targetProf.memberTrackKeys.formUnion(sourceProf.memberTrackKeys)
                identityResolver.upsertGallery(targetProf)
                identityResolver.removeGallery(identityID: sourceID)
                try? trackingStore?.upsertGhostIdentityProfile(targetProf)
                try? trackingStore?.deleteGhostIdentityProfile(identityID: sourceID)
            }

        case "split_identity":
            if let id = updated.parameters["identity_id"],
               let trackID = updated.parameters["track_id"],
               var prof = identityResolver.gallery(for: id) {
                prof.memberTrackKeys.remove(trackID)
                identityResolver.upsertGallery(prof)
                let newID = UUID().uuidString
                let splitProf = GhostIdentityGalleryProfile(
                    identityID: newID,
                    kind: prof.kind,
                    displayCode: "P-SPLIT-\(newID.prefix(4))",
                    centroid: prof.centroid,
                    firstSeenAt: now,
                    lastSeenAt: now,
                    lastCameraID: prof.lastCameraID,
                    memberTrackKeys: [trackID]
                )
                identityResolver.upsertGallery(splitProf)
                identityResolver.recordCannotLink(id, newID)
                try? trackingStore?.upsertGhostIdentityProfile(prof)
                try? trackingStore?.upsertGhostIdentityProfile(splitProf)
            }

        default:
            break
        }
        return updated
    }
}
