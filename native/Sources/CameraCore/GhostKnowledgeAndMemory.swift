import CoreGraphics
import CryptoKit
import Darwin
import Foundation

// MARK: - 1. Content-Hash AI Request Deduplication

public enum GhostAIRequestHasher {
    /// Computes a deterministic SHA-256 hex digest over taskType, promptVersion, promptText, and attached image bytes.
    public static func computeHash(
        taskType: String,
        promptVersion: String = "v1",
        prompt: String,
        images: [Data] = []
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(taskType.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(promptVersion.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(prompt.utf8))
        for img in images {
            hasher.update(data: Data([0xFF]))
            hasher.update(data: img)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 2. Smart Narrative Sampler ("Ghost Memory")

public enum GhostNarrativeTriggerMode: String, Codable, Sendable, CaseIterable {
    case interval
    case object
}

public enum GhostNarrativeSampleReason: String, Codable, Sendable, Equatable {
    case firstFrame = "first_frame"
    case sceneChanged = "scene_changed"
    case newObject = "new_object"
    case objectHeartbeat = "object_heartbeat"
}

public struct GhostNarrativeSampledFrame: Sendable {
    public var cgImage: CGImage
    public var capturedAt: Date
    public var activeLabels: [String]
    public var activeTrackIDs: [String]
    public var activeIdentityIDs: [String]
    public var reason: GhostNarrativeSampleReason

    public init(
        cgImage: CGImage,
        capturedAt: Date,
        activeLabels: [String],
        activeTrackIDs: [String] = [],
        activeIdentityIDs: [String] = [],
        reason: GhostNarrativeSampleReason = .sceneChanged
    ) {
        self.cgImage = cgImage
        self.capturedAt = capturedAt
        self.activeLabels = activeLabels
        self.activeTrackIDs = activeTrackIDs
        self.activeIdentityIDs = activeIdentityIDs
        self.reason = reason
    }
}

public enum GhostNarrativeSamplerRules {
    public static let storyLabels: Set<String> = [
        "person", "car", "truck", "bus", "motorcycle", "bicycle",
        "dog", "cat", "horse", "bird", "boat", "train", "airplane",
        "vehicle", "animal", "van", "pickup", "suv", "sedan"
    ]

    public static func hasStoryObject(labels: [String]) -> Bool {
        for raw in labels {
            let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if storyLabels.contains(lower) { return true }
            for token in storyLabels where lower.contains(token) {
                return true
            }
        }
        return false
    }

    /// Downsamples image to 64x36 grayscale luma + 48-bin HSV histogram and compares with previous signature.
    /// Scene is considered changed if `meanAbsLumaDiff > 0.045` or `hsvCorrelation < 0.96`.
    public static func evaluateSceneChange(
        cgImage: CGImage,
        previousLuma: [UInt8]?,
        previousHistogram: [Float]?
    ) -> (changed: Bool, luma: [UInt8], histogram: [Float]) {
        let thumbW = 64
        let thumbH = 36
        var rgba = [UInt8](repeating: 0, count: thumbW * thumbH * 4)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        rgba.withUnsafeMutableBytes { ptr in
            if let ctx = CGContext(
                data: ptr.baseAddress,
                width: thumbW,
                height: thumbH,
                bitsPerComponent: 8,
                bytesPerRow: thumbW * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) {
                ctx.interpolationQuality = .low
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: thumbW, height: thumbH))
            }
        }

        var luma = [UInt8](repeating: 0, count: thumbW * thumbH)
        for i in 0..<(thumbW * thumbH) {
            let r = Int(rgba[i * 4])
            let g = Int(rgba[i * 4 + 1])
            let b = Int(rgba[i * 4 + 2])
            luma[i] = UInt8(min(255, (77 * r + 150 * g + 29 * b) >> 8))
        }

        let hist = GhostChromaPrint.computeHSVHistogram(from: cgImage)
        guard let prevLuma = previousLuma, prevLuma.count == luma.count else {
            return (true, luma, hist)
        }

        var diffSum = 0
        for i in 0..<luma.count {
            diffSum += abs(Int(luma[i]) - Int(prevLuma[i]))
        }
        let meanDiff = Double(diffSum) / (Double(luma.count) * 255.0)

        var corr = 1.0
        if let prevHist = previousHistogram, !prevHist.isEmpty, prevHist.count == hist.count {
            corr = GhostChromaPrint.hsvCosineSimilarity(prevHist, hist)
        }

        let changed = (meanDiff > 0.045) || (corr < 0.96)
        return (changed, luma, hist)
    }

    /// Thins an array of frames to at most `maxFrames`, preserving the first frame, last frame, and evenly spaced intermediate frames.
    public static func thinFrames(_ frames: [GhostNarrativeSampledFrame], maxFrames: Int = 28) -> [GhostNarrativeSampledFrame] {
        guard maxFrames >= 2, frames.count > maxFrames else {
            return frames
        }
        var result: [GhostNarrativeSampledFrame] = []
        result.reserveCapacity(maxFrames)
        let lastIndex = frames.count - 1
        for i in 0..<maxFrames {
            if i == 0 {
                result.append(frames[0])
            } else if i == maxFrames - 1 {
                result.append(frames[lastIndex])
            } else {
                let ratio = Double(i) / Double(maxFrames - 1)
                let idx = Int((ratio * Double(lastIndex)).rounded())
                result.append(frames[min(max(1, idx), lastIndex - 1)])
            }
        }
        return result
    }
}

public struct GhostNarrativeChapterRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String { chapterID }
    public var chapterID: String
    public var cameraID: UUID
    public var cameraName: String
    public var startedAt: Date
    public var endedAt: Date
    public var narrative: GhostTemporalNarrativeResult
    public var aiSummary: String
    public var operatorText: String?
    public var operatorMarked: Bool
    public var pinned: Bool
    public var frameCount: Int
    public var sightingCount: Int
    public var identityCount: Int
    public var collagePath: String?

    public var effectiveSummary: String {
        if let operatorText = operatorText?.trimmingCharacters(in: .whitespacesAndNewlines), !operatorText.isEmpty {
            return operatorText
        }
        return aiSummary.isEmpty ? narrative.summary : aiSummary
    }

    public init(
        chapterID: String,
        cameraID: UUID,
        cameraName: String,
        startedAt: Date,
        endedAt: Date,
        narrative: GhostTemporalNarrativeResult,
        aiSummary: String? = nil,
        operatorText: String? = nil,
        operatorMarked: Bool = false,
        pinned: Bool = false,
        frameCount: Int = 0,
        sightingCount: Int = 0,
        identityCount: Int = 0,
        collagePath: String? = nil
    ) {
        self.chapterID = chapterID
        self.cameraID = cameraID
        self.cameraName = cameraName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.narrative = narrative
        self.aiSummary = aiSummary ?? narrative.summary
        self.operatorText = operatorText
        self.operatorMarked = operatorMarked
        self.pinned = pinned
        self.frameCount = frameCount
        self.sightingCount = sightingCount
        self.identityCount = identityCount
        self.collagePath = collagePath
    }
}

// MARK: - 3. Semantic Knowledge Layer (Attribute Index, Dossiers, Visits, Routes)

public enum GhostColorNormalizer {
    private static let palette: [(name: String, r: Double, g: Double, b: Double)] = [
        ("black", 20, 20, 22),
        ("white", 235, 235, 240),
        ("gray", 128, 130, 135),
        ("silver", 185, 190, 195),
        ("red", 205, 40, 45),
        ("blue", 40, 90, 205),
        ("navy", 25, 40, 95),
        ("green", 45, 155, 70),
        ("yellow", 230, 200, 45),
        ("orange", 230, 125, 35),
        ("brown", 115, 75, 45),
        ("beige", 205, 190, 155),
        ("pink", 225, 120, 165),
        ("purple", 130, 60, 175)
    ]

    private static let synonyms: [String: String] = [
        "черный": "black", "чёрный": "black", "темный": "black", "dark": "black", "black": "black",
        "белый": "white", "светлый": "white", "white": "white",
        "серый": "gray", "grey": "gray", "gray": "gray",
        "серебристый": "silver", "silver": "silver",
        "красный": "red", "бордовый": "red", "maroon": "red", "burgundy": "red", "red": "red",
        "синий": "blue", "голубой": "blue", "blue": "blue",
        "темно-синий": "navy", "navy": "navy",
        "зеленый": "green", "зелёный": "green", "хаки": "green", "olive": "green", "green": "green",
        "желтый": "yellow", "жёлтый": "yellow", "yellow": "yellow",
        "оранжевый": "orange", "рыжий": "orange", "orange": "orange",
        "коричневый": "brown", "brown": "brown",
        "бежевый": "beige", "песочный": "beige", "tan": "beige", "khaki": "beige", "beige": "beige",
        "розовый": "pink", "pink": "pink",
        "фиолетовый": "purple", "пурпурный": "purple", "violet": "purple", "purple": "purple"
    ]

    public static func normalizeColorToken(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let lower = raw.lowercased()
        if lower.hasPrefix("#"), lower.count == 7 {
            return colorNameFromHex(lower)
        }
        if let exact = synonyms[lower] {
            return exact
        }
        for (k, v) in synonyms where lower.contains(k) {
            return v
        }
        return lower
    }

    public static func colorNameFromHex(_ hex: String?) -> String? {
        guard let hex else { return nil }
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard cleaned.count == 6, let val = UInt32(cleaned, radix: 16) else { return nil }
        let r = Double((val >> 16) & 0xFF)
        let g = Double((val >> 8) & 0xFF)
        let b = Double(val & 0xFF)

        var bestName = "gray"
        var bestDist = Double.greatestFiniteMagnitude
        for entry in palette {
            let dr = r - entry.r
            let dg = g - entry.g
            let db = b - entry.b
            let dist = dr * dr + dg * dg + db * db
            if dist < bestDist {
                bestDist = dist
                bestName = entry.name
            }
        }
        return bestName
    }
}

public struct GhostAttributeIndexEntry: Codable, Sendable, Equatable {
    public var trackID: String
    public var identityID: String
    public var cameraID: String
    public var capturedAt: Date
    public var facet: String
    public var value: String
    public var confidence: Double
    public var cropQuality: Double
    public var source: String // "describe" | "local"

    public init(
        trackID: String,
        identityID: String,
        cameraID: String,
        capturedAt: Date,
        facet: String,
        value: String,
        confidence: Double,
        cropQuality: Double = 0.75,
        source: String = "describe"
    ) {
        self.trackID = trackID
        self.identityID = identityID
        self.cameraID = cameraID
        self.capturedAt = capturedAt
        self.facet = facet.lowercased()
        self.value = value.lowercased()
        self.confidence = confidence
        self.cropQuality = cropQuality
        self.source = source
    }

    /// Extracts garment-bound facets from a VLM `GhostCropDescription` and/or local `GhostChromaSignature`.
    public static func extractEntries(
        trackID: String,
        identityID: String,
        cameraID: String,
        capturedAt: Date,
        cropQuality: Double,
        description: GhostCropDescription?,
        chromaSignature: GhostChromaSignature?
    ) -> [GhostAttributeIndexEntry] {
        var entries: [GhostAttributeIndexEntry] = []

        func add(_ facet: String, _ rawValue: String?, conf: Double, source: String) {
            guard let cleaned = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !cleaned.isEmpty,
                  cleaned != "none",
                  cleaned != "null",
                  cleaned != "unknown" else { return }
            entries.append(
                GhostAttributeIndexEntry(
                    trackID: trackID,
                    identityID: identityID,
                    cameraID: cameraID,
                    capturedAt: capturedAt,
                    facet: facet,
                    value: cleaned,
                    confidence: conf,
                    cropQuality: cropQuality,
                    source: source
                )
            )
        }

        if let desc = description {
            let conf = max(0.35, min(1.0, desc.confidence))
            add("kind", desc.kind, conf: conf, source: "describe")
            if let p = desc.person {
                add("sex", p.apparentSex, conf: conf, source: "describe")
                add("age_group", p.ageGroup, conf: conf, source: "describe")
                add("build", p.build, conf: conf, source: "describe")
                add("hair_color", GhostColorNormalizer.normalizeColorToken(p.hairStyleOrColor) ?? p.hairStyleOrColor, conf: conf, source: "describe")
                add("hair_style", p.hairStyleOrColor, conf: conf, source: "describe")
                add("facial_hair", p.facialHair, conf: conf, source: "describe")
                add("headwear", p.headwear, conf: conf, source: "describe")
                add("upper_wear", p.upperClothingType, conf: conf, source: "describe")
                if let uc = GhostColorNormalizer.normalizeColorToken(p.upperColor) {
                    add("upper_color", uc, conf: conf, source: "describe")
                    add("color", uc, conf: conf * 0.9, source: "describe")
                }
                add("lower_wear", p.lowerClothingType, conf: conf, source: "describe")
                if let lc = GhostColorNormalizer.normalizeColorToken(p.lowerColor) {
                    add("lower_color", lc, conf: conf, source: "describe")
                    add("color", lc, conf: conf * 0.85, source: "describe")
                }
                add("footwear", p.footwear, conf: conf, source: "describe")
                for bag in p.bagsOrCarriedItems {
                    add("bag", bag, conf: conf, source: "describe")
                }
            }
            if let v = desc.vehicle {
                add("vehicle_category", v.vehicleType, conf: conf, source: "describe")
                add("make", v.make, conf: conf, source: "describe")
                add("model", v.model, conf: conf, source: "describe")
                if let vc = GhostColorNormalizer.normalizeColorToken(v.primaryColor) {
                    add("vehicle_color", vc, conf: conf, source: "describe")
                    add("color", vc, conf: conf, source: "describe")
                }
                if let plate = v.plateText {
                    add("plate_number", GhostVehicleRegistryRecord.normalizeIsraeliPlate(plate) ?? plate, conf: conf, source: "describe")
                }
            }
        }

        // Local fallback from GhostChromaSignature at confidence = 0.40
        if let sig = chromaSignature {
            let isVeh = (description?.kind.lowercased() == "vehicle") || (sig.vehicleColorHex != nil)
            if isVeh {
                if let vc = GhostColorNormalizer.colorNameFromHex(sig.vehicleColorHex ?? sig.upperColorHex) {
                    add("vehicle_color", vc, conf: 0.40, source: "local")
                    add("color", vc, conf: 0.40, source: "local")
                }
            } else {
                if let uc = GhostColorNormalizer.colorNameFromHex(sig.upperColorHex) {
                    add("upper_color", uc, conf: 0.40, source: "local")
                    add("color", uc, conf: 0.35, source: "local")
                }
                if let lc = GhostColorNormalizer.colorNameFromHex(sig.lowerColorHex) {
                    add("lower_color", lc, conf: 0.40, source: "local")
                    add("color", lc, conf: 0.35, source: "local")
                }
            }
        }

        return entries
    }
}

public struct GhostIdentityDossier: Codable, Sendable, Equatable {
    public var identityID: String
    public var displayName: String?
    public var kind: String
    public var facets: [String: String]
    public var alternatives: [String: [String]]
    public var summaryLine: String
    public var textBlob: String
    public var updatedAt: Date

    public init(
        identityID: String,
        displayName: String? = nil,
        kind: String = "person",
        facets: [String: String],
        alternatives: [String: [String]] = [:],
        summaryLine: String,
        textBlob: String,
        updatedAt: Date = Date()
    ) {
        self.identityID = identityID
        self.displayName = displayName
        self.kind = kind
        self.facets = facets
        self.alternatives = alternatives
        self.summaryLine = summaryLine
        self.textBlob = textBlob
        self.updatedAt = updatedAt
    }

    public var facetSummary: GhostFacetSummary {
        let sexRaw = facets["sex"]?.lowercased()
        let resolvedSex: GhostResolvedSex
        if sexRaw == "male" || sexRaw == "m" {
            resolvedSex = .male
        } else if sexRaw == "female" || sexRaw == "f" {
            resolvedSex = .female
        } else {
            resolvedSex = .unknown
        }
        let makeModelStr = [facets["make"], facets["model"]].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return GhostFacetSummary(
            identityID: identityID,
            kind: facets["kind"] ?? kind,
            resolvedSex: resolvedSex,
            ageGroup: facets["age_group"],
            build: facets["build"],
            hairStyleOrColor: facets["hair_color"] ?? facets["hair_style"],
            upperClothingType: facets["upper_wear"],
            upperColor: facets["upper_color"],
            lowerClothingType: facets["lower_wear"],
            lowerColor: facets["lower_color"],
            accessories: facets["bag"].map { [$0] } ?? [],
            vehicleType: facets["vehicle_category"],
            vehicleColor: facets["vehicle_color"],
            makeModel: makeModelStr.isEmpty ? nil : makeModelStr,
            plateNumber: facets["plate_number"],
            summaryText: summaryLine
        )
    }
}

public enum GhostIdentityDossierBuilder {
    /// Aggregates all attribute index entries and free-text descriptions for an identity via weighted voting:
    /// `voteWeight = confidence * max(cropQuality, 0.25)`.
    public static func build(
        identityID: String,
        displayName: String?,
        kind: String,
        entries: [GhostAttributeIndexEntry],
        descriptions: [String] = [],
        now: Date = Date()
    ) -> GhostIdentityDossier {
        var bucketWeights: [String: [String: Double]] = [:]
        for entry in entries where entry.identityID == identityID {
            let weight = entry.confidence * max(entry.cropQuality, 0.25)
            bucketWeights[entry.facet, default: [:]][entry.value, default: 0.0] += weight
        }

        var canonicalFacets: [String: String] = [:]
        var alternatives: [String: [String]] = [:]

        for (facet, valueMap) in bucketWeights {
            let ranked = valueMap.sorted {
                if abs($0.value - $1.value) > 1e-6 { return $0.value > $1.value }
                return $0.key < $1.key
            }
            guard let top = ranked.first else { continue }
            canonicalFacets[facet] = top.key
            if ranked.count > 1 {
                let runnersUp = ranked.dropFirst().prefix(3).map(\.key)
                if !runnersUp.isEmpty {
                    alternatives[facet] = Array(runnersUp)
                }
            }
        }
        if canonicalFacets["kind"] == nil {
            canonicalFacets["kind"] = kind.lowercased()
        }

        let summaryParts: [String] = {
            if (canonicalFacets["kind"] ?? kind).lowercased() == "vehicle" {
                return [
                    canonicalFacets["vehicle_color"],
                    canonicalFacets["make"],
                    canonicalFacets["model"],
                    canonicalFacets["vehicle_category"],
                    canonicalFacets["plate_number"].map { "[\($0.uppercased())]" }
                ].compactMap { $0 }.filter { !$0.isEmpty }
            } else {
                return [
                    canonicalFacets["sex"],
                    canonicalFacets["age_group"],
                    [canonicalFacets["upper_color"], canonicalFacets["upper_wear"]].compactMap { $0 }.joined(separator: " "),
                    [canonicalFacets["lower_color"], canonicalFacets["lower_wear"]].compactMap { $0 }.joined(separator: " "),
                    canonicalFacets["headwear"],
                    canonicalFacets["bag"]
                ].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        }()

        let prefix = displayName.map { "\($0) (\(identityID))" } ?? identityID
        let summaryLine = summaryParts.isEmpty
            ? "\(prefix): \(kind)"
            : "\(prefix): \(summaryParts.joined(separator: ", "))"

        var blobTokens: [String] = [identityID]
        if let displayName { blobTokens.append(displayName) }
        for (k, v) in canonicalFacets {
            blobTokens.append("\(k):\(v)")
            blobTokens.append(v)
        }
        for (_, altValues) in alternatives {
            blobTokens.append(contentsOf: altValues)
        }
        blobTokens.append(contentsOf: descriptions)
        let textBlob = blobTokens.joined(separator: " ")

        return GhostIdentityDossier(
            identityID: identityID,
            displayName: displayName,
            kind: canonicalFacets["kind"] ?? kind,
            facets: canonicalFacets,
            alternatives: alternatives,
            summaryLine: summaryLine,
            textBlob: textBlob,
            updatedAt: now
        )
    }
}

public struct GhostVisitSession: Codable, Sendable, Equatable, Identifiable {
    public var id: String { visitID }
    public var visitID: String
    public var identityID: String
    public var startedAt: Date
    public var endedAt: Date
    public var cameraIDs: [String]
    public var trackIDs: [String]
    public var sightingCount: Int
    public var bestTrackID: String

    public init(
        visitID: String,
        identityID: String,
        startedAt: Date,
        endedAt: Date,
        cameraIDs: [String],
        trackIDs: [String],
        sightingCount: Int,
        bestTrackID: String
    ) {
        self.visitID = visitID
        self.identityID = identityID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.cameraIDs = cameraIDs
        self.trackIDs = trackIDs
        self.sightingCount = sightingCount
        self.bestTrackID = bestTrackID
    }
}

public struct GhostSightingForVisit: Sendable {
    public var trackID: String
    public var identityID: String
    public var cameraID: String
    public var cameraName: String
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var quality: Double

    public init(
        trackID: String,
        identityID: String,
        cameraID: String,
        cameraName: String = "",
        firstSeenAt: Date,
        lastSeenAt: Date,
        quality: Double = 0.75
    ) {
        self.trackID = trackID
        self.identityID = identityID
        self.cameraID = cameraID
        self.cameraName = cameraName
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.quality = quality
    }
}

public enum GhostVisitBuilder {
    /// Collapses consecutive sightings of the same identity separated by at most `visitGapSeconds` into discrete visit sessions.
    public static func buildVisits(
        sightings: [GhostSightingForVisit],
        visitGapSeconds: TimeInterval = 120.0
    ) -> [GhostVisitSession] {
        let grouped = Dictionary(grouping: sightings, by: \.identityID)
        var allVisits: [GhostVisitSession] = []

        for (identityID, items) in grouped {
            let sorted = items.sorted { $0.firstSeenAt < $1.firstSeenAt }
            guard let first = sorted.first else { continue }

            var curStart = first.firstSeenAt
            var curEnd = max(first.firstSeenAt, first.lastSeenAt)
            var curCameras: [String] = [first.cameraID]
            var curTracks: [String] = [first.trackID]
            var bestTrack = first.trackID
            var bestQuality = first.quality
            var visitIndex = 1

            func flushVisit() {
                let visitID = "\(identityID)-V\(String(format: "%03d", visitIndex))"
                visitIndex += 1
                allVisits.append(
                    GhostVisitSession(
                        visitID: visitID,
                        identityID: identityID,
                        startedAt: curStart,
                        endedAt: curEnd,
                        cameraIDs: curCameras,
                        trackIDs: curTracks,
                        sightingCount: curTracks.count,
                        bestTrackID: bestTrack
                    )
                )
            }

            for item in sorted.dropFirst() {
                let gap = item.firstSeenAt.timeIntervalSince(curEnd)
                if gap <= visitGapSeconds {
                    curEnd = max(curEnd, item.lastSeenAt)
                    if !curCameras.contains(item.cameraID) {
                        curCameras.append(item.cameraID)
                    }
                    if !curTracks.contains(item.trackID) {
                        curTracks.append(item.trackID)
                    }
                    if item.quality > bestQuality {
                        bestQuality = item.quality
                        bestTrack = item.trackID
                    }
                } else {
                    flushVisit()
                    curStart = item.firstSeenAt
                    curEnd = max(item.firstSeenAt, item.lastSeenAt)
                    curCameras = [item.cameraID]
                    curTracks = [item.trackID]
                    bestTrack = item.trackID
                    bestQuality = item.quality
                }
            }
            flushVisit()
        }

        return allVisits.sorted { $0.startedAt > $1.startedAt }
    }
}

public enum GhostRouteTransitionPlausibility: String, Codable, Sendable, Equatable {
    case sameCamera = "same_camera"
    case plausible = "plausible"
    case tooFastVsLearned = "too_fast_vs_learned"
    case tooSlowVsLearned = "too_slow_vs_learned"
    case unlearnedTransition = "unlearned_transition"
}

public struct GhostRouteLeg: Codable, Sendable, Equatable {
    public var fromCameraID: String
    public var toCameraID: String
    public var departedAt: Date
    public var arrivedAt: Date
    public var transitSeconds: Double
    public var plausibility: GhostRouteTransitionPlausibility
    public var topologyBonus: Double

    public init(
        fromCameraID: String,
        toCameraID: String,
        departedAt: Date,
        arrivedAt: Date,
        transitSeconds: Double,
        plausibility: GhostRouteTransitionPlausibility,
        topologyBonus: Double
    ) {
        self.fromCameraID = fromCameraID
        self.toCameraID = toCameraID
        self.departedAt = departedAt
        self.arrivedAt = arrivedAt
        self.transitSeconds = transitSeconds
        self.plausibility = plausibility
        self.topologyBonus = topologyBonus
    }
}

public struct GhostIdentityRoute: Codable, Sendable, Equatable {
    public var identityID: String
    public var sightingsCount: Int
    public var orderedCameras: [String]
    public var legs: [GhostRouteLeg]

    public init(identityID: String, sightingsCount: Int, orderedCameras: [String], legs: [GhostRouteLeg]) {
        self.identityID = identityID
        self.sightingsCount = sightingsCount
        self.orderedCameras = orderedCameras
        self.legs = legs
    }
}

public enum GhostRouteBuilder {
    public static func buildRoute(
        identityID: String,
        sightings: [GhostSightingForVisit],
        topology: GhostCameraTopology
    ) -> GhostIdentityRoute {
        let sorted = sightings.filter { $0.identityID == identityID }.sorted { $0.firstSeenAt < $1.firstSeenAt }
        guard !sorted.isEmpty else {
            return GhostIdentityRoute(identityID: identityID, sightingsCount: 0, orderedCameras: [], legs: [])
        }
        var orderedCameras: [String] = [sorted[0].cameraID]
        var legs: [GhostRouteLeg] = []

        for idx in 1..<sorted.count {
            let prev = sorted[idx - 1]
            let curr = sorted[idx]
            if orderedCameras.last != curr.cameraID {
                orderedCameras.append(curr.cameraID)
            }
            let dt = curr.firstSeenAt.timeIntervalSince(prev.lastSeenAt)
            let prior = topology.transitionPrior(from: prev.cameraID, to: curr.cameraID, deltaSec: max(0, dt))
            let bonus = prior - 0.50
            let plausibility: GhostRouteTransitionPlausibility
            if prev.cameraID == curr.cameraID {
                plausibility = .sameCamera
            } else if prior > 0.55 {
                plausibility = .plausible
            } else if prior < 0.25 {
                plausibility = .tooFastVsLearned
            } else if prior < 0.40 {
                plausibility = .tooSlowVsLearned
            } else {
                plausibility = .unlearnedTransition
            }
            legs.append(
                GhostRouteLeg(
                    fromCameraID: prev.cameraID,
                    toCameraID: curr.cameraID,
                    departedAt: prev.lastSeenAt,
                    arrivedAt: curr.firstSeenAt,
                    transitSeconds: dt,
                    plausibility: plausibility,
                    topologyBonus: bonus
                )
            )
        }
        return GhostIdentityRoute(
            identityID: identityID,
            sightingsCount: sorted.count,
            orderedCameras: orderedCameras,
            legs: legs
        )
    }
}

public struct GhostCompanionRecord: Codable, Sendable, Equatable {
    public var companionIdentityID: String
    public var coSightingCount: Int
    public var sharedCameras: [String]
    public var firstCoSeenAt: Date
    public var lastCoSeenAt: Date

    public init(
        companionIdentityID: String,
        coSightingCount: Int,
        sharedCameras: [String],
        firstCoSeenAt: Date,
        lastCoSeenAt: Date
    ) {
        self.companionIdentityID = companionIdentityID
        self.coSightingCount = coSightingCount
        self.sharedCameras = sharedCameras
        self.firstCoSeenAt = firstCoSeenAt
        self.lastCoSeenAt = lastCoSeenAt
    }
}

public enum GhostCompanionFinder {
    public static func findCompanions(
        for identityID: String,
        allSightings: [GhostSightingForVisit],
        maxGapSeconds: TimeInterval = 15.0
    ) -> [GhostCompanionRecord] {
        let targetSightings = allSightings.filter { $0.identityID == identityID }
        guard !targetSightings.isEmpty else { return [] }
        let otherSightings = allSightings.filter { $0.identityID != identityID }

        var counts: [String: Int] = [:]
        var cameras: [String: Set<String>] = [:]
        var firstSeen: [String: Date] = [:]
        var lastSeen: [String: Date] = [:]

        for mine in targetSightings {
            for other in otherSightings where other.cameraID == mine.cameraID {
                let earliestEnd = min(mine.lastSeenAt, other.lastSeenAt)
                let latestStart = max(mine.firstSeenAt, other.firstSeenAt)
                let gap = latestStart.timeIntervalSince(earliestEnd)
                if gap <= maxGapSeconds {
                    let cid = other.identityID
                    counts[cid, default: 0] += 1
                    cameras[cid, default: []].insert(mine.cameraID)
                    let t = min(mine.firstSeenAt, other.firstSeenAt)
                    if let prev = firstSeen[cid] {
                        firstSeen[cid] = min(prev, t)
                    } else {
                        firstSeen[cid] = t
                    }
                    let tEnd = max(mine.lastSeenAt, other.lastSeenAt)
                    if let prevEnd = lastSeen[cid] {
                        lastSeen[cid] = max(prevEnd, tEnd)
                    } else {
                        lastSeen[cid] = tEnd
                    }
                }
            }
        }

        return counts.keys.compactMap { cid -> GhostCompanionRecord? in
            guard let count = counts[cid],
                  let first = firstSeen[cid],
                  let last = lastSeen[cid] else { return nil }
            return GhostCompanionRecord(
                companionIdentityID: cid,
                coSightingCount: count,
                sharedCameras: Array(cameras[cid] ?? []).sorted(),
                firstCoSeenAt: first,
                lastCoSeenAt: last
            )
        }.sorted {
            if $0.coSightingCount != $1.coSightingCount {
                return $0.coSightingCount > $1.coSightingCount
            }
            return $0.lastCoSeenAt > $1.lastCoSeenAt
        }
    }
}

// MARK: - 4. Agent Conversation History, Focus Memory, Chain Debt & Actions

public struct GhostPendingOutputDebt: Codable, Sendable, Equatable {
    public var callID: String
    public var outputJSON: String

    public init(callID: String, outputJSON: String) {
        self.callID = callID
        self.outputJSON = outputJSON
    }
}

public struct GhostChatThreadRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String { threadID }
    public var threadID: String
    public var title: String
    public var operatorName: String
    public var kind: String // "general" | "incident" | "identity"
    public var severity: String // "normal" | "warning" | "critical"
    public var pinned: Bool
    public var lastResponseID: String?
    public var pendingOutputs: [GhostPendingOutputDebt]
    public var boundCameraIDs: [String]
    public var linkedThreadIDs: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        threadID: String = UUID().uuidString,
        title: String = "Investigation",
        operatorName: String = "operator",
        kind: String = "general",
        severity: String = "normal",
        pinned: Bool = false,
        lastResponseID: String? = nil,
        pendingOutputs: [GhostPendingOutputDebt] = [],
        boundCameraIDs: [String] = [],
        linkedThreadIDs: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.threadID = threadID
        self.title = title
        self.operatorName = operatorName
        self.kind = kind
        self.severity = severity
        self.pinned = pinned
        self.lastResponseID = lastResponseID
        self.pendingOutputs = pendingOutputs
        self.boundCameraIDs = boundCameraIDs
        self.linkedThreadIDs = linkedThreadIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct GhostChatMessageRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String { messageID }
    public var messageID: String
    public var threadID: String
    public var role: String // "user" | "assistant" | "tool"
    public var text: String
    public var structuredAnswer: GhostChatFinalAnswer?
    public var clipID: String?
    public var callID: String?
    public var createdAt: Date

    public init(
        messageID: String = UUID().uuidString,
        threadID: String,
        role: String,
        text: String,
        structuredAnswer: GhostChatFinalAnswer? = nil,
        clipID: String? = nil,
        callID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.messageID = messageID
        self.threadID = threadID
        self.role = role
        self.text = text
        self.structuredAnswer = structuredAnswer
        self.clipID = clipID
        self.callID = callID
        self.createdAt = createdAt
    }
}

public struct GhostThreadFocusEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(threadID):\(kind):\(refID)" }
    public var threadID: String
    public var kind: String // "identity" | "camera"
    public var refID: String
    public var label: String?
    public var pinned: Bool
    public var lastUsedAt: Date

    public init(
        threadID: String,
        kind: String = "identity",
        refID: String,
        label: String? = nil,
        pinned: Bool = false,
        lastUsedAt: Date = Date()
    ) {
        self.threadID = threadID
        self.kind = kind
        self.refID = refID
        self.label = label
        self.pinned = pinned
        self.lastUsedAt = lastUsedAt
    }
}

public struct GhostToolCallAuditRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var threadID: String
    public var toolName: String
    public var argsJSON: String
    public var resultRows: Int
    public var durationMs: Int
    public var ok: Bool
    public var error: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        threadID: String,
        toolName: String,
        argsJSON: String,
        resultRows: Int,
        durationMs: Int,
        ok: Bool,
        error: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.threadID = threadID
        self.toolName = toolName
        self.argsJSON = argsJSON
        self.resultRows = resultRows
        self.durationMs = durationMs
        self.ok = ok
        self.error = error
        self.createdAt = createdAt
    }
}

public struct GhostChatActionRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String { actionID }
    public var actionID: String
    public var threadID: String
    public var actionType: String // "rename_identity" | "merge_identities" | "split_identity" | "create_watch" | "set_camera_role"
    public var title: String
    public var parameters: [String: String]
    public var status: String // "proposed" | "confirmed" | "rejected"
    public var createdAt: Date
    public var reviewedAt: Date?

    public init(
        actionID: String = UUID().uuidString,
        threadID: String,
        actionType: String,
        title: String,
        parameters: [String: String],
        status: String = "proposed",
        createdAt: Date = Date(),
        reviewedAt: Date? = nil
    ) {
        self.actionID = actionID
        self.threadID = threadID
        self.actionType = actionType
        self.title = title
        self.parameters = parameters
        self.status = status
        self.createdAt = createdAt
        self.reviewedAt = reviewedAt
    }
}

public struct GhostChatClipRecord: Codable, Sendable, Equatable, Identifiable {
    public static let defaultTTLSeconds: TimeInterval = 44.0 * 60.0 // 44 minutes

    public var id: String { clipID }
    public var clipID: String
    public var threadID: String
    public var cameraID: String
    public var filePath: String
    public var createdAt: Date
    public var expiresAt: Date

    public init(
        clipID: String = UUID().uuidString,
        threadID: String,
        cameraID: String,
        filePath: String,
        createdAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.clipID = clipID
        self.threadID = threadID
        self.cameraID = cameraID
        self.filePath = filePath
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(Self.defaultTTLSeconds)
    }
}

// MARK: - 5. Read-Only SQL Validator for `run_readonly_sql`

public enum GhostReadOnlySQLGuard {
    private static let forbiddenKeywords: Set<String> = [
        "insert", "update", "delete", "drop", "alter", "pragma",
        "attach", "detach", "create", "replace", "truncate",
        "vacuum", "reindex", "begin", "commit", "rollback",
        "savepoint", "release", "load_extension"
    ]

    /// Strips single-quoted and double-quoted literals so structural SQL tokens can be inspected accurately.
    private static func stripQuotedLiterals(_ sql: String) -> String {
        var result = ""
        result.reserveCapacity(sql.count)
        var inSingle = false
        var inDouble = false
        var iterator = sql.makeIterator()
        while let ch = iterator.next() {
            if inSingle {
                if ch == "'" { inSingle = false }
                continue
            }
            if inDouble {
                if ch == "\"" { inDouble = false }
                continue
            }
            if ch == "'" {
                inSingle = true
                result.append(" ")
            } else if ch == "\"" {
                inDouble = true
                result.append(" ")
            } else {
                result.append(ch)
            }
        }
        return result
    }

    public static func validateAndCap(_ rawSQL: String, maxLimit: Int = 200) throws -> String {
        let safeMaxLimit = max(1, min(maxLimit, 1000))
        let trimmed = rawSQL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "GhostReadOnlySQLGuard", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty SQL query"])
        }
        // Disallow SQL comments and multiple statements via semicolon
        let withoutTrailingSemicolon = trimmed.hasSuffix(";") ? String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
        let structural = stripQuotedLiterals(withoutTrailingSemicolon)
        if structural.contains(";") || structural.contains("--") || structural.contains("/*") {
            throw NSError(domain: "GhostReadOnlySQLGuard", code: 2, userInfo: [NSLocalizedDescriptionKey: "Multiple SQL statements or comments are forbidden"])
        }

        let lowerStructural = structural.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard lowerStructural.hasPrefix("select ") || lowerStructural.hasPrefix("with ") else {
            throw NSError(domain: "GhostReadOnlySQLGuard", code: 3, userInfo: [NSLocalizedDescriptionKey: "Only SELECT or WITH queries are permitted"])
        }

        let tokens = lowerStructural.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        for token in tokens where forbiddenKeywords.contains(token) {
            throw NSError(domain: "GhostReadOnlySQLGuard", code: 4, userInfo: [NSLocalizedDescriptionKey: "Forbidden keyword '\(token)' in read-only SQL"])
        }

        if !tokens.contains("limit") {
            return "\(withoutTrailingSemicolon) LIMIT \(safeMaxLimit)"
        }
        return withoutTrailingSemicolon
    }
}

// MARK: - 6. Memory Guard (RAM Watchdog) & Storage Janitor Report

public enum GhostMemoryPressureLevel: String, Codable, Sendable, Equatable {
    case ok
    case soft
    case hard
}

public final class GhostMemoryGuard: @unchecked Sendable {
    private let lock = NSLock()
    public let softThresholdMB: Double
    public let hardThresholdMB: Double
    public let releaseHysteresis: Double
    private var currentLevel: GhostMemoryPressureLevel = .ok
    private var overriddenRSSMB: Double?

    public init(
        softThresholdMB: Double = 1400.0,
        hardThresholdMB: Double = 2000.0,
        releaseHysteresis: Double = 0.90
    ) {
        self.softThresholdMB = softThresholdMB
        self.hardThresholdMB = hardThresholdMB
        self.releaseHysteresis = releaseHysteresis
    }

    public func setTestRSSOverrideMB(_ rssMB: Double?) {
        lock.lock()
        defer { lock.unlock() }
        overriddenRSSMB = rssMB
    }

    public static func currentProcessRSSMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return 0.0 }
        return Double(info.resident_size) / (1024.0 * 1024.0)
    }

    @discardableResult
    public func evaluate() -> (level: GhostMemoryPressureLevel, rssMB: Double, allowContextFrames: Bool, strideMultiplier: Int) {
        lock.lock()
        defer { lock.unlock() }

        let rss = overriddenRSSMB ?? Self.currentProcessRSSMB()
        switch currentLevel {
        case .ok:
            if rss >= hardThresholdMB {
                currentLevel = .hard
            } else if rss >= softThresholdMB {
                currentLevel = .soft
            }
        case .soft:
            if rss >= hardThresholdMB {
                currentLevel = .hard
            } else if rss < softThresholdMB * releaseHysteresis {
                currentLevel = .ok
            }
        case .hard:
            if rss < softThresholdMB * releaseHysteresis {
                currentLevel = .ok
            } else if rss < hardThresholdMB * releaseHysteresis {
                currentLevel = .soft
            }
        }

        let allowContext = (currentLevel == .ok)
        let stride: Int
        switch currentLevel {
        case .ok: stride = 1
        case .soft: stride = 2
        case .hard: stride = 4
        }
        return (currentLevel, rss, allowContext, stride)
    }
}

public struct GhostStorageJanitorPolicy: Codable, Sendable, Equatable {
    public var maxMediaDiskMB: Double
    public var minFreeDiskGB: Double
    public var maxCropsPerIdentity: Int
    public var dataSaverEnabled: Bool
    public var trackImageRetentionDays: Int
    public var logRetentionDays: Int

    public init(
        maxMediaDiskMB: Double = 2048.0,
        minFreeDiskGB: Double = 2.0,
        maxCropsPerIdentity: Int = 48,
        dataSaverEnabled: Bool = false,
        trackImageRetentionDays: Int = 14,
        logRetentionDays: Int = 14
    ) {
        self.maxMediaDiskMB = maxMediaDiskMB
        self.minFreeDiskGB = minFreeDiskGB
        self.maxCropsPerIdentity = maxCropsPerIdentity
        self.dataSaverEnabled = dataSaverEnabled
        self.trackImageRetentionDays = trackImageRetentionDays
        self.logRetentionDays = logRetentionDays
    }
}

public struct GhostStorageJanitorReport: Codable, Sendable, Equatable {
    public var degradedCutoutCount: Int
    public var degradedCropCount: Int
    public var overflowCropsDegradedCount: Int
    public var expiredClipsRemovedCount: Int
    public var oldLogsPrunedCount: Int
    public var lowDiskSpaceTriggered: Bool

    public init(
        degradedCutoutCount: Int = 0,
        degradedCropCount: Int = 0,
        overflowCropsDegradedCount: Int = 0,
        expiredClipsRemovedCount: Int = 0,
        oldLogsPrunedCount: Int = 0,
        lowDiskSpaceTriggered: Bool = false
    ) {
        self.degradedCutoutCount = degradedCutoutCount
        self.degradedCropCount = degradedCropCount
        self.overflowCropsDegradedCount = overflowCropsDegradedCount
        self.expiredClipsRemovedCount = expiredClipsRemovedCount
        self.oldLogsPrunedCount = oldLogsPrunedCount
        self.lowDiskSpaceTriggered = lowDiskSpaceTriggered
    }
}
