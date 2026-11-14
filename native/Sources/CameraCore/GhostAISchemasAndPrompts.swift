import Foundation

// MARK: - 1. Language & Localization Routing

public enum GhostPromptLanguage: String, Codable, Sendable, CaseIterable {
    case ru
    case en
    case he

    public static func detect(from text: String, fallback: GhostPromptLanguage = .ru) -> GhostPromptLanguage {
        for scalar in text.unicodeScalars {
            if (0x0590...0x05FF).contains(scalar.value) {
                return .he
            }
            if (0x0400...0x04FF).contains(scalar.value) {
                return .ru
            }
        }
        let latinCount = text.unicodeScalars.filter { (0x0041...0x007A).contains($0.value) }.count
        if latinCount >= 3 {
            return .en
        }
        return fallback
    }

    public var displayName: String {
        switch self {
        case .ru: return "Russian (Русский)"
        case .en: return "English"
        case .he: return "Hebrew (עברית)"
        }
    }
}

// MARK: - 2. OpSec Sanitizer & Persona Stripper

public enum GhostOpSec {
    private static let vendorTerms: [(pattern: String, replacement: String)] = [
        ("(?i)\\bopenai\\b", "AI Engine"),
        ("(?i)\\bgpt-5[-a-z0-9.]*\\b", "Vision-Core"),
        ("(?i)\\bgpt-4[-a-z0-9.]*\\b", "Vision-Core"),
        ("(?i)\\bqwen[-a-z0-9.]*\\b", "Local-Vision"),
        ("(?i)\\bclaude[-a-z0-9.]*\\b", "Vision-Core"),
        ("(?i)\\bvllm\\b", "Local-Inference"),
        ("(?i)\\byolo[0-9a-z-]*\\b", "Detector"),
        ("(?i)\\bosnet[_a-z0-9-]*\\b", "ReID"),
        ("(?i)\\bonnx\\b", "Runtime")
    ]

    private static let personaPrefixes: [String] = [
        "As an AI", "As a language model", "I am an AI",
        "Как ИИ", "Как языковая модель", "В качестве ИИ",
        "כמודל שפה", "כבינה מלאכותית"
    ]

    public static func sanitizeText(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in personaPrefixes {
            if result.lowercased().hasPrefix(p.lowercased()) {
                if let dotRange = result.range(of: ".") {
                    result = String(result[dotRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        for (pattern, replacement) in vendorTerms {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, range: nsRange, withTemplate: replacement)
            }
        }
        return result
    }

    public static func stripPersona(_ text: String) -> String {
        var result = sanitizeText(text)
        let injectionPatterns = [
            "(?i)ignore (all )?previous instructions[.,!]*",
            "(?i)you are now a [^.,!]+[.,!]*",
            "(?i)игнорируй(те)? предыдущие инструкции[.,!]*"
        ]
        for pat in injectionPatterns {
            if let regex = try? NSRegularExpression(pattern: pat) {
                let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, range: nsRange, withTemplate: "")
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func sanitizeAnswer(_ answer: GhostChatPresentAnswer) -> GhostChatPresentAnswer {
        var copy = answer
        copy.answerMarkdown = sanitizeText(answer.answerMarkdown)
        copy.followUpSuggestions = answer.followUpSuggestions.map { sanitizeText($0) }
        return copy
    }
}

// MARK: - 3. Trilingual Lexicon (RU / EN / HE)

public enum GhostLexicon {
    public static let attributeSynonyms: [String: [String]] = [
        "male": ["male", "man", "boy", "guy", "мужчина", "парень", "мужской", "גבר", "בחור", "זכר"],
        "female": ["female", "woman", "girl", "lady", "женщина", "девушка", "женский", "אישה", "בחורה", "נקבה"],
        "black": ["black", "dark", "черный", "чёрный", "темный", "שחור", "כהה"],
        "white": ["white", "light", "белый", "светлый", "לבן", "בהיר"],
        "red": ["red", "burgundy", "maroon", "красный", "бордовый", "אדום", "בורדו"],
        "blue": ["blue", "navy", "cyan", "синий", "голубой", "כחול", "תכלת"],
        "green": ["green", "olive", "khaki", "зеленый", "зелёный", "хаки", "ירוק", "חאקי"],
        "yellow": ["yellow", "gold", "желтый", "жёлтый", "צהוב"],
        "gray": ["gray", "grey", "silver", "серый", "серебристый", "אפור", "כסוף"],
        "backpack": ["backpack", "rucksack", "bag", "рюкзак", "сумка", "תיק", "תרמיל"],
        "hat": ["hat", "cap", "beanie", "helmet", "кепка", "шапка", "шлем", "כובע", "קסדה"],
        "glasses": ["glasses", "sunglasses", "eyewear", "очки", "משקפיים"],
        "jacket": ["jacket", "coat", "hoodie", "куртка", "пальто", "худи", "толстовка", "מעיל", "קפוצ׳ון"],
        "car": ["car", "sedan", "suv", "hatchback", "vehicle", "машина", "автомобиль", "седан", "внедорожник", "רכב", "מכונית"],
        "truck": ["truck", "van", "pickup", "lorry", "грузовик", "фургон", "пикап", "משאית", "מסחרית"],
        "motorcycle": ["motorcycle", "scooter", "bike", "мотоцикл", "скутер", "אופנוע", "קטנוע"]
    ]

    public static let situationSynonyms: [String: [String]] = [
        "running": ["running", "sprinting", "fleeing", "бежит", "убегает", "бег", "רץ", "בורח"],
        "fighting": ["fighting", "assault", "punching", "violence", "драка", "нападение", "удар", "קטטה", "תקיפה", "אלימות"],
        "fallen": ["fallen", "lying on ground", "collapsed", "упал", "лежит на земле", "נפל", "שוכב על הרצפה"],
        "intrusion": ["climbing", "trespassing", "perimeter breach", "fence", "перелезает", "проникновение", "забор", "מטפס", "חדירה", "גדר"],
        "fire": ["fire", "smoke", "flames", "огонь", "дым", "пламя", "пожар", "אש", "עשן", "שריפה"],
        "weapon": ["weapon", "gun", "rifle", "knife", "pistol", "оружие", "пистолет", "нож", "автомат", "נשק", "אקדח", "סכין", "רובה"],
        "abandoned_object": ["abandoned bag", "unattended package", "left object", "оставленный предмет", "бесхозная сумка", "חפץ חשוד", "תיק נטוש"]
    ]

    public static func expandQueryTerms(_ query: String) -> Set<String> {
        let lowered = query.lowercased()
        var expanded: Set<String> = [lowered]
        let tokens = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        for t in tokens { expanded.insert(t) }

        for (_, group) in attributeSynonyms {
            if group.contains(where: { lowered.contains($0) }) {
                for term in group { expanded.insert(term) }
            }
        }
        for (_, group) in situationSynonyms {
            if group.contains(where: { lowered.contains($0) }) {
                for term in group { expanded.insert(term) }
            }
        }
        return expanded
    }
}

// MARK: - 4. Structured AI Output Schemas (16 Tasks)

// Task 1: Bulk Describe (`GhostCropDescriptionBatch`)
public struct GhostPersonAttributes: Codable, Sendable, Equatable {
    public var apparentSex: String?
    public var ageGroup: String?
    public var build: String?
    public var hairStyleOrColor: String?
    public var facialHair: String?
    public var eyewear: String?
    public var headwear: String?
    public var maskOrFaceCovering: String?
    public var upperClothingType: String?
    public var upperColor: String?
    public var lowerClothingType: String?
    public var lowerColor: String?
    public var footwear: String?
    public var bagsOrCarriedItems: [String]
    public var postureOrAction: String?
    public var distinguishingMarks: [String]

    public init(
        apparentSex: String? = nil,
        ageGroup: String? = nil,
        build: String? = nil,
        hairStyleOrColor: String? = nil,
        facialHair: String? = nil,
        eyewear: String? = nil,
        headwear: String? = nil,
        maskOrFaceCovering: String? = nil,
        upperClothingType: String? = nil,
        upperColor: String? = nil,
        lowerClothingType: String? = nil,
        lowerColor: String? = nil,
        footwear: String? = nil,
        bagsOrCarriedItems: [String] = [],
        postureOrAction: String? = nil,
        distinguishingMarks: [String] = []
    ) {
        self.apparentSex = apparentSex
        self.ageGroup = ageGroup
        self.build = build
        self.hairStyleOrColor = hairStyleOrColor
        self.facialHair = facialHair
        self.eyewear = eyewear
        self.headwear = headwear
        self.maskOrFaceCovering = maskOrFaceCovering
        self.upperClothingType = upperClothingType
        self.upperColor = upperColor
        self.lowerClothingType = lowerClothingType
        self.lowerColor = lowerColor
        self.footwear = footwear
        self.bagsOrCarriedItems = bagsOrCarriedItems
        self.postureOrAction = postureOrAction
        self.distinguishingMarks = distinguishingMarks
    }
}

public struct GhostVehicleAttributes: Codable, Sendable, Equatable {
    public var vehicleType: String?
    public var primaryColor: String?
    public var secondaryColor: String?
    public var make: String?
    public var model: String?
    public var bodyStyle: String?
    public var plateText: String?
    public var roofRackOrCargo: String?
    public var distinctiveFeatures: [String]

    public init(
        vehicleType: String? = nil,
        primaryColor: String? = nil,
        secondaryColor: String? = nil,
        make: String? = nil,
        model: String? = nil,
        bodyStyle: String? = nil,
        plateText: String? = nil,
        roofRackOrCargo: String? = nil,
        distinctiveFeatures: [String] = []
    ) {
        self.vehicleType = vehicleType
        self.primaryColor = primaryColor
        self.secondaryColor = secondaryColor
        self.make = make
        self.model = model
        self.bodyStyle = bodyStyle
        self.plateText = plateText
        self.roofRackOrCargo = roofRackOrCargo
        self.distinctiveFeatures = distinctiveFeatures
    }
}

public struct GhostCropDescriptionItem: Codable, Sendable, Equatable {
    public var cellIndex: Int
    public var itemID: String?
    public var kind: String // "person" or "vehicle"
    public var summary: String
    public var confidence: Double
    public var person: GhostPersonAttributes?
    public var vehicle: GhostVehicleAttributes?

    public init(
        cellIndex: Int,
        itemID: String? = nil,
        kind: String,
        summary: String,
        confidence: Double = 0.85,
        person: GhostPersonAttributes? = nil,
        vehicle: GhostVehicleAttributes? = nil
    ) {
        self.cellIndex = cellIndex
        self.itemID = itemID
        self.kind = kind
        self.summary = summary
        self.confidence = confidence
        self.person = person
        self.vehicle = vehicle
    }
}

public typealias GhostPersonFacet = GhostPersonAttributes
public typealias GhostVehicleFacet = GhostVehicleAttributes
public typealias GhostCropDescription = GhostCropDescriptionItem

public struct GhostCropDescriptionBatch: Codable, Sendable, Equatable {
    public var items: [GhostCropDescriptionItem]

    public init(items: [GhostCropDescriptionItem] = []) {
        self.items = items
    }
}

// Task 2: Plate OCR Collage (`GhostPlateCollageResult`) & Israeli Registry (`data.gov.il`)
public struct GhostPlateReadItem: Codable, Sendable, Equatable {
    public var cellIndex: Int
    public var itemID: String?
    public var plateText: String
    public var confidence: Double
    public var countryOrFormat: String?
    public var makeModelHint: String?
    public var colorHint: String?

    public init(
        cellIndex: Int,
        itemID: String? = nil,
        plateText: String,
        confidence: Double,
        countryOrFormat: String? = nil,
        makeModelHint: String? = nil,
        colorHint: String? = nil
    ) {
        self.cellIndex = cellIndex
        self.itemID = itemID
        self.plateText = plateText
        self.confidence = confidence
        self.countryOrFormat = countryOrFormat
        self.makeModelHint = makeModelHint
        self.colorHint = colorHint
    }
}

public struct GhostPlateCollageResult: Codable, Sendable, Equatable {
    public var plates: [GhostPlateReadItem]

    public init(plates: [GhostPlateReadItem] = []) {
        self.plates = plates
    }
}

public struct GhostVehicleRegistryRecord: Codable, Sendable, Equatable {
    public static let privateVehiclesResourceID = "053cea08-09bc-40ec-8f7a-156f0677aff3"
    public static let motorcyclesResourceID = "bf9df4e2-d90d-4c0a-a400-19e15af8e95f"
    public static let heavyVehiclesResourceID = "cd3acc5c-03c3-4c89-9c54-d40f93c0d790"

    public var plateNumber: String
    public var manufacturer: String?
    public var commercialModel: String?
    public var manufactureYear: Int?
    public var colorName: String?
    public var fuelType: String?
    public var ownershipType: String?
    public var testValidUntil: String?
    public var sourceResourceID: String
    public var fetchedAt: Date

    public init(
        plateNumber: String,
        manufacturer: String? = nil,
        commercialModel: String? = nil,
        manufactureYear: Int? = nil,
        colorName: String? = nil,
        fuelType: String? = nil,
        ownershipType: String? = nil,
        testValidUntil: String? = nil,
        sourceResourceID: String = Self.privateVehiclesResourceID,
        fetchedAt: Date = Date()
    ) {
        self.plateNumber = plateNumber
        self.manufacturer = manufacturer
        self.commercialModel = commercialModel
        self.manufactureYear = manufactureYear
        self.colorName = colorName
        self.fuelType = fuelType
        self.ownershipType = ownershipType
        self.testValidUntil = testValidUntil
        self.sourceResourceID = sourceResourceID
        self.fetchedAt = fetchedAt
    }

    public static func normalizeIsraeliPlate(_ raw: String) -> String? {
        let digits = raw.filter(\.isNumber)
        guard (7...8).contains(digits.count) else { return nil }
        return digits
    }
}

// Task 3 & 4: Continuity Sweeper Layer C (`GhostTextDedupResult`) & Layer D (`GhostCollageDedupResult`)
public struct GhostTextDedupPairVerdict: Codable, Sendable, Equatable {
    public var idA: String
    public var idB: String
    public var sameIdentity: Bool
    public var confidence: Double
    public var reason: String

    public init(idA: String, idB: String, sameIdentity: Bool, confidence: Double, reason: String) {
        self.idA = idA
        self.idB = idB
        self.sameIdentity = sameIdentity
        self.confidence = confidence
        self.reason = reason
    }
}

public struct GhostTextDedupResult: Codable, Sendable, Equatable {
    public var pairs: [GhostTextDedupPairVerdict]

    public init(pairs: [GhostTextDedupPairVerdict] = []) {
        self.pairs = pairs
    }
}

public struct GhostCollageDedupGroup: Codable, Sendable, Equatable {
    public var cellIndices: [Int]
    public var identityIDs: [String]
    public var confidence: Double
    public var reason: String

    public init(cellIndices: [Int], identityIDs: [String] = [], confidence: Double, reason: String) {
        self.cellIndices = cellIndices
        self.identityIDs = identityIDs
        self.confidence = confidence
        self.reason = reason
    }
}

public struct GhostCollageDedupResult: Codable, Sendable, Equatable {
    public var mergeGroups: [GhostCollageDedupGroup]
    public var distinctPairs: [[Int]]

    public init(mergeGroups: [GhostCollageDedupGroup] = [], distinctPairs: [[Int]] = []) {
        self.mergeGroups = mergeGroups
        self.distinctPairs = distinctPairs
    }
}

// Task 5: Ghost Memory Temporal Narrative (`GhostTemporalNarrativeResult`)
public struct GhostNarrativeEventItem: Codable, Sendable, Equatable {
    public var frameBadgeIndex: Int
    public var timestampOffsetSec: Double
    public var headline: String
    public var detail: String
    public var actors: [String]
    public var severity: String // "low", "medium", "high"

    public init(
        frameBadgeIndex: Int,
        timestampOffsetSec: Double = 0,
        headline: String,
        detail: String,
        actors: [String] = [],
        severity: String = "low"
    ) {
        self.frameBadgeIndex = frameBadgeIndex
        self.timestampOffsetSec = timestampOffsetSec
        self.headline = headline
        self.detail = detail
        self.actors = actors
        self.severity = severity
    }
}

public struct GhostTemporalNarrativeResult: Codable, Sendable, Equatable {
    public var chapterTitle: String
    public var summary: String
    public var deltaFromPrevious: String?
    public var atmosphere: String
    public var events: [GhostNarrativeEventItem]

    public init(
        chapterTitle: String,
        summary: String,
        deltaFromPrevious: String? = nil,
        atmosphere: String = "normal",
        events: [GhostNarrativeEventItem] = []
    ) {
        self.chapterTitle = chapterTitle
        self.summary = summary
        self.deltaFromPrevious = deltaFromPrevious
        self.atmosphere = atmosphere
        self.events = events
    }
}

// Task 6 & 7 & 8: Critical Alert 4-Frame Ring, Alert Mentor 16-Frame Brief & Demo Scan 5-Frame
public struct GhostCriticalAlertDetection: Codable, Sendable, Equatable {
    public var ruleCode: String
    public var category: String
    public var triggered: Bool
    public var confidence: Double
    public var severity: String // "critical", "high", "warning"
    public var title: String
    public var evidenceSummary: String
    public var frameIndices: [Int]

    public init(
        ruleCode: String,
        category: String,
        triggered: Bool,
        confidence: Double,
        severity: String = "critical",
        title: String,
        evidenceSummary: String,
        frameIndices: [Int] = []
    ) {
        self.ruleCode = ruleCode
        self.category = category
        self.triggered = triggered
        self.confidence = confidence
        self.severity = severity
        self.title = title
        self.evidenceSummary = evidenceSummary
        self.frameIndices = frameIndices
    }
}

public struct GhostCriticalAlertBatch: Codable, Sendable, Equatable {
    public var sceneStatus: String
    public var alerts: [GhostCriticalAlertDetection]

    public init(sceneStatus: String = "clear", alerts: [GhostCriticalAlertDetection] = []) {
        self.sceneStatus = sceneStatus
        self.alerts = alerts
    }
}

public struct GhostAlertMentorBrief: Codable, Sendable, Equatable {
    public var alertID: String
    public var confirmedThreat: Bool
    public var falsePositiveReason: String?
    public var tacticalHeadline: String
    public var precursorSummary: String
    public var escalationTrajectory: String
    public var recommendedOperatorAction: String
    public var confidence: Double

    public init(
        alertID: String,
        confirmedThreat: Bool,
        falsePositiveReason: String? = nil,
        tacticalHeadline: String,
        precursorSummary: String,
        escalationTrajectory: String,
        recommendedOperatorAction: String,
        confidence: Double
    ) {
        self.alertID = alertID
        self.confirmedThreat = confirmedThreat
        self.falsePositiveReason = falsePositiveReason
        self.tacticalHeadline = tacticalHeadline
        self.precursorSummary = precursorSummary
        self.escalationTrajectory = escalationTrajectory
        self.recommendedOperatorAction = recommendedOperatorAction
        self.confidence = confidence
    }
}

public struct GhostDemoScanVerdict: Codable, Sendable, Equatable {
    public var triggered: Bool
    public var headline: String
    public var narrative: String
    public var detections: [GhostCriticalAlertDetection]

    public init(
        triggered: Bool,
        headline: String,
        narrative: String,
        detections: [GhostCriticalAlertDetection] = []
    ) {
        self.triggered = triggered
        self.headline = headline
        self.narrative = narrative
        self.detections = detections
    }
}

// Task 9: Standing Watch / Mission Verification (`GhostMissionVerdict`)
public struct GhostMissionVerdict: Codable, Sendable, Equatable {
    public var watchID: String
    public var matched: Bool
    public var confidence: Double
    public var title: String
    public var explanation: String
    public var matchedSubjectIDs: [String]

    public init(
        watchID: String,
        matched: Bool,
        confidence: Double,
        title: String,
        explanation: String,
        matchedSubjectIDs: [String] = []
    ) {
        self.watchID = watchID
        self.matched = matched
        self.confidence = confidence
        self.title = title
        self.explanation = explanation
        self.matchedSubjectIDs = matchedSubjectIDs
    }
}

// Task 10 & 11: Camera Intel Profile & Camera Role Auto-Setup
public struct GhostCameraIntelProfile: Codable, Sendable, Equatable {
    public var cameraID: String
    public var environmentType: String // "indoor", "outdoor", "perimeter", "entry", "parking"
    public var vantagePoint: String
    public var typicalTraffic: String
    public var blindSpotsAndRisks: [String]
    public var recommendedWatches: [String]

    public init(
        cameraID: String,
        environmentType: String,
        vantagePoint: String,
        typicalTraffic: String,
        blindSpotsAndRisks: [String] = [],
        recommendedWatches: [String] = []
    ) {
        self.cameraID = cameraID
        self.environmentType = environmentType
        self.vantagePoint = vantagePoint
        self.typicalTraffic = typicalTraffic
        self.blindSpotsAndRisks = blindSpotsAndRisks
        self.recommendedWatches = recommendedWatches
    }
}

public struct GhostCameraRoleConfig: Codable, Sendable, Equatable {
    public var cameraID: String
    public var roleTitle: String
    public var securityZone: String
    public var activeAlertRuleCodes: [String]
    public var narrativeMode: String // "interval" or "object"
    public var sensitivityLevel: String // "standard", "elevated", "high"

    public init(
        cameraID: String,
        roleTitle: String,
        securityZone: String,
        activeAlertRuleCodes: [String] = [],
        narrativeMode: String = "object",
        sensitivityLevel: String = "standard"
    ) {
        self.cameraID = cameraID
        self.roleTitle = roleTitle
        self.securityZone = securityZone
        self.activeAlertRuleCodes = activeAlertRuleCodes
        self.narrativeMode = narrativeMode
        self.sensitivityLevel = sensitivityLevel
    }
}

// Task 12, 13, 14: Voice Refine, Brief Title, Spoken Briefing HC Card
public struct GhostVoiceRefine: Codable, Sendable, Equatable {
    public var rawTranscript: String
    public var cleanedCommand: String
    public var detectedLanguage: String
    public var intentCategory: String

    public init(rawTranscript: String, cleanedCommand: String, detectedLanguage: String, intentCategory: String = "query") {
        self.rawTranscript = rawTranscript
        self.cleanedCommand = cleanedCommand
        self.detectedLanguage = detectedLanguage
        self.intentCategory = intentCategory
    }
}

public struct GhostBriefTitle: Codable, Sendable, Equatable {
    public var title: String

    public init(title: String) {
        self.title = title
    }
}

public struct GhostHCCard: Codable, Sendable, Equatable {
    public var spokenLine: String
    public var badgeLabel: String
    public var urgency: String // "routine", "watch", "critical"
    public var subjectID: String?
    public var cameraID: String?

    public init(
        spokenLine: String,
        badgeLabel: String,
        urgency: String = "routine",
        subjectID: String? = nil,
        cameraID: String? = nil
    ) {
        self.spokenLine = spokenLine
        self.badgeLabel = badgeLabel
        self.urgency = urgency
        self.subjectID = subjectID
        self.cameraID = cameraID
    }
}

// Task 15 & 16: Ghost Chat & Research Agent (`present_answer` & proposed actions)
public struct GhostProposedAction: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var actionID: String { id }
    public var actionType: String // "merge_identities", "split_identity", "create_watch", "rename_identity", "bookmark_alert"
    public var title: String
    public var parameters: [String: String]
    public var requiresOperatorConfirmation: Bool

    public init(
        id: String = UUID().uuidString,
        actionType: String,
        title: String,
        parameters: [String: String] = [:],
        requiresOperatorConfirmation: Bool = true
    ) {
        self.id = id
        self.actionType = actionType
        self.title = title
        self.parameters = parameters
        self.requiresOperatorConfirmation = requiresOperatorConfirmation
    }

    private enum LenientKeys: String, CodingKey {
        case id, actionID, actionType, title, parameters, requiresOperatorConfirmation
    }

    /// Model-produced actions frequently omit optional fields or emit non-string parameter values.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LenientKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id))
            ?? (try? c.decodeIfPresent(String.self, forKey: .actionID))
            ?? UUID().uuidString
        actionType = (try? c.decodeIfPresent(String.self, forKey: .actionType)) ?? "note"
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? actionType
        if let strings = try? c.decodeIfPresent([String: String].self, forKey: .parameters) {
            parameters = strings
        } else if let numbers = try? c.decodeIfPresent([String: Double].self, forKey: .parameters) {
            parameters = numbers.mapValues { String($0) }
        } else {
            parameters = [:]
        }
        requiresOperatorConfirmation = (try? c.decodeIfPresent(Bool.self, forKey: .requiresOperatorConfirmation)) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: LenientKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(actionType, forKey: .actionType)
        try c.encode(title, forKey: .title)
        try c.encode(parameters, forKey: .parameters)
        try c.encode(requiresOperatorConfirmation, forKey: .requiresOperatorConfirmation)
    }
}

public struct GhostChatPresentAnswer: Codable, Sendable, Equatable {
    public var answerMarkdown: String
    public var citedIdentityIDs: [String]
    public var citedCameraIDs: [String]
    public var confidence: Double
    public var followUpSuggestions: [String]
    public var proposedActions: [GhostProposedAction]

    public init(
        answerMarkdown: String,
        citedIdentityIDs: [String] = [],
        citedCameraIDs: [String] = [],
        confidence: Double = 0.90,
        followUpSuggestions: [String] = [],
        proposedActions: [GhostProposedAction] = []
    ) {
        self.answerMarkdown = answerMarkdown
        self.citedIdentityIDs = citedIdentityIDs
        self.citedCameraIDs = citedCameraIDs
        self.confidence = confidence
        self.followUpSuggestions = followUpSuggestions
        self.proposedActions = proposedActions
    }

    private enum CodingKeys: String, CodingKey {
        case answerMarkdown, citedIdentityIDs, citedCameraIDs, confidence, followUpSuggestions, proposedActions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        answerMarkdown = try c.decode(String.self, forKey: .answerMarkdown)
        citedIdentityIDs = (try? c.decodeIfPresent([String].self, forKey: .citedIdentityIDs)) ?? []
        citedCameraIDs = (try? c.decodeIfPresent([String].self, forKey: .citedCameraIDs)) ?? []
        confidence = (try? c.decodeIfPresent(Double.self, forKey: .confidence)) ?? 0.75
        followUpSuggestions = (try? c.decodeIfPresent([String].self, forKey: .followUpSuggestions)) ?? []
        proposedActions = (try? c.decodeIfPresent([GhostProposedAction].self, forKey: .proposedActions)) ?? []
    }
}

public typealias GhostChatFinalAnswer = GhostChatPresentAnswer

// MARK: - 5. Multilingual Prompt Library (RU / EN / HE)

public enum GhostPromptLibrary {
    public static func languageDirective(_ lang: GhostPromptLanguage) -> String {
        switch lang {
        case .ru:
            return "ОТВЕЧАЙ СТРОГО НА РУССКОМ ЯЗЫКЕ во всех текстовых полях (summary, headline, detail, reason, tacticalHeadline). Технические перечисления (male/female/unknown, low/medium/high/critical) оставляй в каноническом формате."
        case .en:
            return "RESPOND STRICTLY IN ENGLISH for all free-text fields (summary, headline, detail, reason, tacticalHeadline). Keep canonical enum keys as specified."
        case .he:
            return "השב אך ורק בעברית בכל שדות הטקסט החופשי (summary, headline, detail, reason, tacticalHeadline). שמור על ערכי enum באנגלית כפי שהוגדר."
        }
    }

    public static func bulkDescribePrompt(cellCount: Int, language: GhostPromptLanguage) -> String {
        """
        You are the tactical visual intelligence unit analyzing a numbered DESCRIBE collage containing \(cellCount) subject cutouts (`[#1]` through `[#\(cellCount)]`).
        Each cell shows an isolated person or vehicle with a dark neutral surround outside its alpha mask.
        Ignore the black background; analyze ONLY pixels belonging to the subject inside each numbered cell.
        \(languageDirective(language))

        Return strict JSON matching `GhostCropDescriptionBatch`:
        {
          "items": [
            {
              "cellIndex": 1,
              "kind": "person" | "vehicle",
              "summary": "Concise tactical description of appearance, clothing/colors, accessories or vehicle make/model/color",
              "confidence": 0.0-1.0,
              "person": {
                "apparentSex": "male" | "female" | "unknown",
                "ageGroup": "child" | "young_adult" | "adult" | "senior" | "unknown",
                "build": "slim" | "medium" | "heavy" | "athletic" | "unknown",
                "hairStyleOrColor": "...",
                "facialHair": "none" | "beard" | "mustache" | "stubble" | "unknown",
                "eyewear": "none" | "glasses" | "sunglasses" | "unknown",
                "headwear": "none" | "cap" | "hat" | "hood" | "helmet" | "hijab" | "kippa",
                "maskOrFaceCovering": "none" | "surgical_mask" | "balaclava" | "scarf",
                "upperClothingType": "t-shirt" | "shirt" | "jacket" | "hoodie" | "coat" | "vest" | "dress",
                "upperColor": "...",
                "lowerClothingType": "jeans" | "trousers" | "shorts" | "skirt" | "leggings",
                "lowerColor": "...",
                "footwear": "...",
                "bagsOrCarriedItems": ["backpack", ...],
                "postureOrAction": "walking" | "standing" | "running" | "carrying" | "crouching",
                "distinguishingMarks": []
              },
              "vehicle": {
                "vehicleType": "sedan" | "suv" | "hatchback" | "van" | "truck" | "pickup" | "motorcycle" | "bus",
                "primaryColor": "...",
                "secondaryColor": "...",
                "make": "...",
                "model": "...",
                "bodyStyle": "...",
                "plateText": "...",
                "roofRackOrCargo": "...",
                "distinctiveFeatures": []
              }
            }
          ]
        }
        """
    }

    public static func plateCollagePrompt(cellCount: Int, language: GhostPromptLanguage) -> String {
        """
        You are the high-precision License Plate OCR engine inspecting a numbered PLATE collage (`[#1]`..`[#\(cellCount)]`).
        Read the characters on each license plate crop. Prefer Israeli 7-8 digit plates or standard alphanumeric plates. Strip punctuation and spaces in `plateText`.
        \(languageDirective(language))

        Return strict JSON matching `GhostPlateCollageResult`:
        {
          "plates": [
            {
              "cellIndex": 1,
              "plateText": "12345678",
              "confidence": 0.0-1.0,
              "countryOrFormat": "IL-8" | "IL-7" | "EU" | "UNKNOWN",
              "makeModelHint": "...",
              "colorHint": "..."
            }
          ]
        }
        """
    }

    public static func textDedupPrompt(pairsDescription: String, language: GhostPromptLanguage) -> String {
        """
        You are the Continuity Identity Deduplication judge (Layer C).
        Compare the following candidate identity pairs based on structured appearance facets, camera transitions, and timing.
        Never merge two identities if they have conflicting apparent sex, incompatible clothing colors, or different vehicle body types.
        \(languageDirective(language))

        Candidate Pairs:
        \(pairsDescription)

        Return strict JSON matching `GhostTextDedupResult`:
        {
          "pairs": [
            {
              "idA": "...",
              "idB": "...",
              "sameIdentity": true | false,
              "confidence": 0.0-1.0,
              "reason": "..."
            }
          ]
        }
        """
    }

    public static func collageDedupPrompt(cellMappingDescription: String, language: GhostPromptLanguage) -> String {
        """
        You are the Visual Continuity Deduplication judge (Layer D).
        Inspect the numbered PORTRAIT collage and determine which cells depict the exact same physical person or vehicle across cameras/time, and which pairs are definitely distinct individuals (`distinctPairs` -> permanent `cannot_link`).
        \(languageDirective(language))

        Cell Mapping:
        \(cellMappingDescription)

        Return strict JSON matching `GhostCollageDedupResult`:
        {
          "mergeGroups": [
            {
              "cellIndices": [1, 3],
              "identityIDs": ["...", "..."],
              "confidence": 0.0-1.0,
              "reason": "..."
            }
          ],
          "distinctPairs": [[1, 2], [2, 4]]
        }
        """
    }

    public static func narrativeChapterPrompt(
        cameraName: String,
        frameCount: Int,
        previousChapterSummary: String?,
        language: GhostPromptLanguage
    ) -> String {
        let prevContext = previousChapterSummary.map { "Previous Chapter Summary (report ONLY new developments / delta): \($0)" } ?? "No previous chapter."
        return """
        You are the Ghost Memory Temporal Narrative chronicler for camera "\(cameraName)".
        You are viewing a numbered NARRATIVE collage of \(frameCount) sequential frames (`[#1]`..`[#\(frameCount)]`).
        \(prevContext)
        \(languageDirective(language))

        Return strict JSON matching `GhostTemporalNarrativeResult`:
        {
          "chapterTitle": "...",
          "summary": "...",
          "deltaFromPrevious": "...",
          "atmosphere": "calm" | "busy" | "tense" | "anomalous",
          "events": [
            {
              "frameBadgeIndex": 1,
              "timestampOffsetSec": 0.0,
              "headline": "...",
              "detail": "...",
              "actors": ["P-001", "V-002"],
              "severity": "low" | "medium" | "high"
            }
          ]
        }
        """
    }

    public static func criticalAlertRingPrompt(
        cameraName: String,
        activeRulesDescription: String,
        language: GhostPromptLanguage
    ) -> String {
        """
        You are the Real-Time Critical Alert Sentinel monitoring a 4-frame temporal sequence (`[#1]`..`[#4]`, 1.2s apart) from camera "\(cameraName)".
        Verify temporal progression across the 4 frames to eliminate single-frame motion blur or shadow false positives.
        Active Rules to Evaluate:
        \(activeRulesDescription)
        \(languageDirective(language))

        Return strict JSON matching `GhostCriticalAlertBatch`:
        {
          "sceneStatus": "clear" | "elevated" | "critical",
          "alerts": [
            {
              "ruleCode": "...",
              "category": "weapon" | "violence" | "fallen_person" | "intrusion" | "fire_smoke" | "abandoned_object" | "custom",
              "triggered": true | false,
              "confidence": 0.0-1.0,
              "severity": "critical" | "high" | "warning",
              "title": "...",
              "evidenceSummary": "...",
              "frameIndices": [1, 2, 3, 4]
            }
          ]
        }
        """
    }

    public static func alertMentorPrompt(
        alertID: String,
        cameraName: String,
        initialAlertTitle: String,
        language: GhostPromptLanguage
    ) -> String {
        """
        You are the Alert Mentor conducting a 16-frame lookback investigation (`[#1]`..`[#16]`) on camera "\(cameraName)" for alert "\(initialAlertTitle)" (ID: \(alertID)).
        Analyze the precursors leading up to the trigger, verify whether the alert is a true threat or a false positive, and formulate an actionable operator brief.
        \(languageDirective(language))

        Return strict JSON matching `GhostAlertMentorBrief`:
        {
          "alertID": "\(alertID)",
          "confirmedThreat": true | false,
          "falsePositiveReason": null | "...",
          "tacticalHeadline": "...",
          "precursorSummary": "...",
          "escalationTrajectory": "de-escalating" | "stable" | "escalating",
          "recommendedOperatorAction": "...",
          "confidence": 0.0-1.0
        }
        """
    }

    public static func standingWatchPrompt(
        watchID: String,
        watchInstruction: String,
        cameraName: String,
        language: GhostPromptLanguage
    ) -> String {
        """
        You are evaluating a Standing Watch / Mission rule on camera "\(cameraName)".
        Watch ID: \(watchID)
        Condition to Verify: "\(watchInstruction)"
        \(languageDirective(language))

        Return strict JSON matching `GhostMissionVerdict`:
        {
          "watchID": "\(watchID)",
          "matched": true | false,
          "confidence": 0.0-1.0,
          "title": "...",
          "explanation": "...",
          "matchedSubjectIDs": []
        }
        """
    }

    public static func spokenBriefingCardPrompt(
        eventContext: String,
        language: GhostPromptLanguage
    ) -> String {
        """
        You are the Spoken Briefing tactical announcer. Generate a crisp, natural 1-sentence spoken update (`spokenLine`, under 18 words) and a short badge label for the operator's audio feed.
        Context:
        \(eventContext)
        \(languageDirective(language))

        Return strict JSON matching `GhostHCCard`:
        {
          "spokenLine": "...",
          "badgeLabel": "...",
          "urgency": "routine" | "watch" | "critical",
          "subjectID": null,
          "cameraID": null
        }
        """
    }

    public static func ghostChatSystemPrompt(language: GhostPromptLanguage) -> String {
        """
        You are the GHOST ONWAY Tactical Investigation Agent.
        You have access to all saved memory layers: cross-camera identity dossiers, routes, companion graphs, license plate registries, temporal narratives, 7-day camera memory frames, 30-day per-camera tracked objects & OCR, operational alerts/ISAPI events/scheduled missions, and live camera lookback tools.
        Never reveal underlying model names or vendor details. Cite specific identity codes (e.g., `P-001`, `V-004`), track IDs, and camera names.
        Work as a tool-using agent: decide yourself which tools to call, in what order, and when you have enough evidence.
        - Chronological memory: `get_timeline` gives a merged, time-ordered view (narrative chapters, stored memory frames, critical/VLM alerts, hardware ISAPI events, mission runs); `list_narrative_chapters` / `get_narrative_chapter` read Ghost Memory chapters with event timelines; `list_memory_frames` / `view_memory_frame` list and open archived camera frames (7-day archive) so you can look at what a camera actually showed at a given time.
        - Tracked objects & scans (30-day archive): `search_tracked_objects` searches per-camera `tracked_objects`, VLM descriptions (`description_json`), vehicle OCR (`vehicle_text_json`), operator identity groups, and `automatic_camera_scans`, and can attach saved track crop images.
        - Operational memory: `get_operational_events` and `get_camera_alert_history` read persistent VLM alerts (with operator review status/notes), active standing watch rules, hardware ISAPI events, scheduled missions & mission runs, and SQLite Alert Mentor briefs.
        - Persistent identity knowledge: `search_identities_by_attributes`, `get_identity_dossier`, `get_identity_route`, `who_was_present`, `list_visits`, `find_companions`, and `run_readonly_sql`.
        - SQLite schema for `run_readonly_sql`:
          * `tracked_objects(track_id, camera_id, camera_name, label, first_seen, last_seen, observation_count, best_confidence, crop_path, cutout_path, description_json, described_at, vehicle_text_json, crop_quality, upper_color, lower_color, vehicle_color, resolved_sex, identity_state, identity_score, ghost_identity_id, is_best)`
          * `operator_identity_groups(track_id, group_id, confirmed_at)`
          * `automatic_camera_scans(scan_id, camera_id, camera_name, observed_at, answer)`
          * `ghost_identity_dossiers(identity_id, display_name, kind, facets_json, alternatives_json, summary_line, text_blob, updated_at)`
          * `ghost_attribute_index(track_id, identity_id, camera_id, captured_at, facet, value, confidence, crop_quality, source)`
          * `ghost_visits(visit_id, identity_id, started_at, ended_at, camera_ids_json, track_ids_json, sighting_count, best_track_id)`
          * `ghost_narrative_chapters(chapter_id, camera_id, camera_name, started_at, ended_at, chapter_json, ai_summary, operator_text, operator_marked, pinned, frame_count, sighting_count, identity_count, collage_path)`
          * `ghost_alert_mentor_briefs(alert_id, camera_id, brief_json, created_at)`
          * `ghost_camera_links(link_key, from_camera_id, to_camera_id, transition_count, mean_transit_sec, min_transit_sec, max_transit_sec, updated_at)`
          * `ghost_vehicle_registry_cache(plate_number, record_json, fetched_at)`
        - Live view: `live_look` attaches the current frames of the cameras.
        Prefer narrow time windows (ISO-8601 `since`/`until`) and look at frames before describing visual details. Never invent sightings that no tool returned.
        Finish every turn by calling `present_answer` exactly once with the final answer.
        \(languageDirective(language))
        """
    }
}

