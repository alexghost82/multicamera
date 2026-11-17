import Foundation
import CameraCore

struct OperationsPreferences: Codable, Equatable {
    var personCountAlertsEnabled = false
    var personThreshold = 10
    var holdSeconds = 3
    var cooldownSeconds = 300
    var criticalSoundEnabled = false

    func validate() throws {
        guard (2...100).contains(personThreshold), (1...60).contains(holdSeconds),
              (60...3600).contains(cooldownSeconds) else {
            throw ConfigurationError.invalid("Check the crowd threshold, hold time and cooldown.")
        }
    }
}

extension OperationsPreferences {
    private enum CodingKeys: String, CodingKey {
        case personCountAlertsEnabled, personThreshold, holdSeconds, cooldownSeconds, criticalSoundEnabled
    }

    init(from decoder: Swift.Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        personCountAlertsEnabled = try values.decodeIfPresent(Bool.self, forKey: .personCountAlertsEnabled) ?? false
        personThreshold = try values.decodeIfPresent(Int.self, forKey: .personThreshold) ?? 10
        holdSeconds = try values.decodeIfPresent(Int.self, forKey: .holdSeconds) ?? 3
        cooldownSeconds = try values.decodeIfPresent(Int.self, forKey: .cooldownSeconds) ?? 300
        criticalSoundEnabled = try values.decodeIfPresent(Bool.self, forKey: .criticalSoundEnabled) ?? false
        try validate()
    }
}

enum OperationsAlertQueue {
    static func status(
        for alertID: UUID, reviews: [UUID: OperationsAlertReview], acknowledgements: [UUID: Date]
    ) -> OperationsAlertReview.Status {
        reviews[alertID]?.status ?? (acknowledgements[alertID] == nil ? .open : .acknowledged)
    }

    static func ordered(
        _ alerts: [VLMAlert], reviews: [UUID: OperationsAlertReview], acknowledgements: [UUID: Date]
    ) -> [VLMAlert] {
        func rank(_ alert: VLMAlert) -> Int {
            let state = status(for: alert.id, reviews: reviews, acknowledgements: acknowledgements)
            if state == .resolved { return 4 }
            let critical = (reviews[alert.id]?.priority ?? alert.priority) == .critical
            return (critical ? 0 : 2) + (state == .open ? 0 : 1)
        }
        return alerts.sorted {
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func pendingCriticalIDs(
        alerts: [VLMAlert], reviews: [UUID: OperationsAlertReview], acknowledgements: [UUID: Date]
    ) -> Set<UUID> {
        Set(alerts.filter {
            (reviews[$0.id]?.priority ?? $0.priority) == .critical
                && status(for: $0.id, reviews: reviews, acknowledgements: acknowledgements) == .open
        }.map(\.id))
    }

    static func shouldSound(
        featureEnabled: Bool, soundEnabled: Bool, previous: Set<UUID>, current: Set<UUID>
    ) -> Bool {
        featureEnabled && soundEnabled && !current.subtracting(previous).isEmpty
    }
}

enum OperationsAlertReport {
    static func renderHTML(
        alerts: [VLMAlert], reviews: [UUID: OperationsAlertReview], acknowledgements: [UUID: Date],
        generatedAt: Date = Date()
    ) -> String {
        let rows = OperationsAlertQueue.ordered(alerts, reviews: reviews, acknowledgements: acknowledgements).prefix(100).map { alert in
            let review = reviews[alert.id]
            let status = OperationsAlertQueue.status(for: alert.id, reviews: reviews, acknowledgements: acknowledgements)
            return """
            <tr><td>\(escape(alert.createdAt.formatted()))</td><td>\(escape(alert.cameraName))</td>
            <td>\(escape((review?.priority ?? alert.priority).rawValue))</td><td>\(escape(status.rawValue))</td>
            <td>\(escape(alert.condition))</td><td>\(escape(alert.evidence))</td><td>\(escape(review?.note ?? ""))</td>
            <td>\(alert.id.uuidString)</td></tr>
            """
        }.joined(separator: "\n")
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <title>CameraWall operations report</title>
        <style>body{font:15px -apple-system,sans-serif;margin:24px;color:#17212b}table{border-collapse:collapse;width:100%}th,td{text-align:left;vertical-align:top;padding:8px;border-bottom:1px solid #ccd3d9;white-space:pre-wrap;overflow-wrap:anywhere}</style>
        </head><body><h1>CameraWall operations report</h1><p>\(escape(generatedAt.formatted()))</p>
        <table><thead><tr><th>Time</th><th>Camera</th><th>Operator priority</th><th>Status</th><th>Condition</th><th>Evidence</th><th>Operator note</th><th>Alert UUID</th></tr></thead>
        <tbody>\(rows)</tbody></table></body></html>
        """
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

struct OperationsWatchRule: Codable, Equatable, Identifiable {
    static let maximumRules = 24
    static let maximumTextCharacters = 500
    static let maximumTerms = 16
    static let defaultTTLSeconds: TimeInterval = 120 * 60
    static let maximumTTLSeconds: TimeInterval = 30 * 24 * 60 * 60

    let id: UUID
    let text: String
    let terms: [String]
    let cameraIDs: Set<UUID>
    let createdAt: Date
    let expiresAt: Date?
    var firedTrackIDs: [UUID]

    var isForever: Bool { expiresAt == nil }

    init(
        id: UUID = UUID(), text: String, cameraIDs: Set<UUID> = [], createdAt: Date = Date(),
        ttlSeconds: TimeInterval? = OperationsWatchRule.defaultTTLSeconds, firedTrackIDs: [UUID] = []
    ) throws {
        let normalizedText = text.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = OperationsWatchMatcher.terms(normalizedText)
        guard !normalizedText.isEmpty, normalizedText.count <= Self.maximumTextCharacters,
              (1...Self.maximumTerms).contains(terms.count), createdAt.timeIntervalSince1970.isFinite,
              ttlSeconds.map({ $0.isFinite && $0 >= 60 && $0 <= Self.maximumTTLSeconds }) ?? true else {
            throw ConfigurationError.invalid("Enter a watch condition with 1 to 16 search terms and a valid expiry.")
        }
        self.id = id
        self.text = normalizedText
        self.terms = terms
        self.cameraIDs = cameraIDs
        self.createdAt = createdAt
        self.expiresAt = ttlSeconds.map { createdAt.addingTimeInterval($0) }
        var seenTracks = Set<UUID>()
        self.firedTrackIDs = Array(firedTrackIDs.filter { seenTracks.insert($0).inserted }.suffix(64))
    }

    private enum CodingKeys: String, CodingKey { case id, text, terms, cameraIDs, createdAt, expiresAt, firedTrackIDs }

    init(from decoder: Swift.Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(UUID.self, forKey: .id)
        let text = try values.decode(String.self, forKey: .text)
        let cameraIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .cameraIDs) ?? []
        let createdAt = try values.decode(Date.self, forKey: .createdAt)
        let expiresAt = try values.decodeIfPresent(Date.self, forKey: .expiresAt)
        let firedTrackIDs = try values.decodeIfPresent([UUID].self, forKey: .firedTrackIDs) ?? []
        try self.init(id: id, text: text, cameraIDs: cameraIDs, createdAt: createdAt,
                      ttlSeconds: expiresAt.map { $0.timeIntervalSince(createdAt) }, firedTrackIDs: firedTrackIDs)
        guard try values.decodeIfPresent([String].self, forKey: .terms) == nil || values.decode([String].self, forKey: .terms) == terms else {
            throw ConfigurationError.invalid("Saved watch terms do not match the rule text.")
        }
    }

    func isActive(at time: Date) -> Bool {
        time.timeIntervalSince1970.isFinite && (expiresAt.map { $0 > time } ?? true)
    }

    func matches(_ record: TrackedObjectRecord, at time: Date, window: TimeInterval = 300) -> Bool {
        let evidenceAt = record.describedAt ?? record.lastSeen
        guard isActive(at: time), !firedTrackIDs.contains(record.trackID),
              evidenceAt <= time, time.timeIntervalSince(evidenceAt) <= window,
              cameraIDs.isEmpty || cameraIDs.contains(record.cameraID),
              let description = record.description else { return false }
        var textFields = [record.label, record.cameraName, description.summary]
        for (name, attribute) in description.attributes {
            textFields.append(contentsOf: [name, attribute.value, attribute.evidence])
        }
        let facts = Set(textFields.flatMap(OperationsWatchMatcher.terms))
        return terms.allSatisfy(facts.contains)
    }

    mutating func markFired(trackID: UUID) {
        guard !firedTrackIDs.contains(trackID) else { return }
        firedTrackIDs = Array((firedTrackIDs + [trackID]).suffix(64))
    }
}

enum OperationsWatchMatcher {
    private static let stopWords: Set<String> = [
        "what", "when", "where", "who", "how", "the", "a", "an", "is", "are", "was", "were",
        "in", "on", "at", "to", "from", "of", "with", "and", "or", "if", "you", "me", "see",
        "אם", "תראה", "תראי", "תתריע", "לי", "את", "עם", "של", "על", "או", "גם", "כל", "וגם", "יש", "אין"
    ]

    static func terms(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var seen = Set<String>()
        return folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { token in
            token.count > 1 && !stopWords.contains(token) && seen.insert(token).inserted
        }
    }
}

enum OperationsWatchStore {
    static let maximumBytes = 256 * 1024
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CameraWall/operation-watches.json")
    }

    static func load(from url: URL = defaultURL, at time: Date = Date()) throws -> [OperationsWatchRule] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= maximumBytes else {
            throw ConfigurationError.invalid("Watch rules exceed the local storage limit.")
        }
        let rules = try JSONDecoder().decode([OperationsWatchRule].self, from: Data(contentsOf: url))
        guard rules.count <= OperationsWatchRule.maximumRules,
              Set(rules.map(\.id)).count == rules.count,
              rules.allSatisfy({ $0.terms == OperationsWatchMatcher.terms($0.text) && $0.firedTrackIDs.count <= 64 }) else {
            throw ConfigurationError.invalid("Saved watch rules are invalid.")
        }
        return rules.filter { $0.isActive(at: time) }
    }

    static func save(_ rules: [OperationsWatchRule], to url: URL = defaultURL) throws {
        let active = Array(rules.suffix(OperationsWatchRule.maximumRules))
        guard Set(active.map(\.id)).count == active.count,
              active.allSatisfy({ $0.terms == OperationsWatchMatcher.terms($0.text) }) else {
            throw ConfigurationError.invalid("Watch rules are invalid.")
        }
        let data = try JSONEncoder().encode(active)
        guard data.count <= maximumBytes else { throw ConfigurationError.invalid("Watch rules exceed the local storage limit.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

struct OperationsWatchEvaluationResult {
    let rules: [OperationsWatchRule]
    let alerts: [VLMAlert]
    let changed: Bool
}

enum OperationsWatchEvaluator {
    static func evaluate(
        rules sourceRules: [OperationsWatchRule], records: [TrackedObjectRecord],
        existingAlerts: [VLMAlert], at time: Date, historyLimit: Int = 100
    ) -> OperationsWatchEvaluationResult {
        var rules = sourceRules.filter { $0.isActive(at: time) }
        var alerts = existingAlerts
        var changed = rules.count != sourceRules.count
        let tracks = records.filter { record in
            guard record.description != nil else { return false }
            let evidenceAt = record.describedAt ?? record.lastSeen
            return evidenceAt <= time && time.timeIntervalSince(evidenceAt) <= 300
        }
        for ruleIndex in rules.indices {
            for record in tracks where rules[ruleIndex].matches(record, at: time) {
                let alreadyRecorded = alerts.contains {
                    $0.watchID == rules[ruleIndex].id && $0.sourceTrackID == record.trackID
                }
                if !alreadyRecorded, let description = record.description {
                    let evidence = ([description.summary] + description.attributes.values.flatMap { [$0.value, $0.evidence] })
                        .filter { !Set(OperationsWatchMatcher.terms($0)).isDisjoint(with: rules[ruleIndex].terms) }
                        .joined(separator: " · ")
                    alerts.insert(VLMAlert(
                        cameraID: record.cameraID, cameraName: record.cameraName,
                        condition: rules[ruleIndex].text, evidence: String(evidence.prefix(500)),
                        watchID: rules[ruleIndex].id, sourceTrackID: record.trackID
                    ), at: 0)
                    if alerts.count > max(1, historyLimit) { alerts.removeLast(alerts.count - max(1, historyLimit)) }
                }
                rules[ruleIndex].markFired(trackID: record.trackID)
                changed = true
            }
        }
        return OperationsWatchEvaluationResult(rules: rules, alerts: alerts, changed: changed)
    }
}

enum OperationsPreferencesStore {
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CameraWall/operations.json")
    }

    static func load(from url: URL = defaultURL) throws -> OperationsPreferences {
        guard FileManager.default.fileExists(atPath: url.path) else { return OperationsPreferences() }
        let preferences = try JSONDecoder().decode(OperationsPreferences.self, from: Data(contentsOf: url))
        try preferences.validate()
        return preferences
    }

    static func save(_ preferences: OperationsPreferences, to url: URL = defaultURL) throws {
        try preferences.validate()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preferences).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

struct CrowdAlertEvaluator {
    private var aboveThresholdSince: [UUID: TimeInterval] = [:]
    private var lastAlertAt: [UUID: TimeInterval] = [:]

    mutating func shouldAlert(
        cameraID: UUID,
        personCount: Int,
        threshold: Int,
        now: TimeInterval,
        holdSeconds: TimeInterval,
        cooldownSeconds: TimeInterval
    ) -> Bool {
        guard personCount >= threshold else {
            aboveThresholdSince[cameraID] = nil
            return false
        }
        let start = aboveThresholdSince[cameraID] ?? now
        aboveThresholdSince[cameraID] = start
        guard now - start >= holdSeconds,
              now - (lastAlertAt[cameraID] ?? -.infinity) >= cooldownSeconds else { return false }
        lastAlertAt[cameraID] = now
        return true
    }
}

enum LocalMonitorProbeStatus: String, Codable {
    case healthy
    case warning
    case down
    case inactive
}

struct LocalMonitorProbe: Codable, Equatable, Identifiable {
    let id: String
    let label: String
    let status: LocalMonitorProbeStatus
    let detail: String
    let checkedAt: Date
}

struct LocalMonitorEvent: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case fault, recovered }
    let id: UUID
    let occurredAt: Date
    let probeID: String
    let label: String
    let kind: Kind
    let detail: String

    init(id: UUID = UUID(), occurredAt: Date, probeID: String, label: String, kind: Kind, detail: String) {
        self.id = id
        self.occurredAt = occurredAt
        self.probeID = String(probeID.prefix(80))
        self.label = String(label.prefix(120))
        self.kind = kind
        self.detail = String(detail.prefix(500))
    }
}

struct LocalMonitorSnapshot: Equatable {
    enum Verdict: String { case ok, warning, fault, inactive }
    let verdict: Verdict
    let probes: [LocalMonitorProbe]
    let checkedAt: Date?

    static let empty = LocalMonitorSnapshot(probes: [], checkedAt: nil)

    init(probes: [LocalMonitorProbe], checkedAt: Date?) {
        self.probes = probes
        self.checkedAt = checkedAt
        if probes.contains(where: { $0.status == .down }) { verdict = .fault }
        else if probes.contains(where: { $0.status == .warning }) { verdict = .warning }
        else if probes.allSatisfy({ $0.status == .inactive }) || probes.isEmpty { verdict = .inactive }
        else { verdict = .ok }
    }
}

struct LocalMonitorCheckReceipt: Equatable {
    let id: UUID
    let snapshot: LocalMonitorSnapshot
    let history: [LocalMonitorEvent]
    let historyWritten: Bool
}

enum LocalMonitorCheckError: LocalizedError {
    case disabled
    case busy
    case historyUnavailable
    case observationFailed
    case historyWriteFailed

    var errorDescription: String? {
        switch self {
        case .disabled: return "FEATURE_DISABLED: The in-app monitor is disabled."
        case .busy: return "ACTION_BUSY: A monitor check is already in progress."
        case .historyUnavailable: return "HISTORY_UNAVAILABLE: Monitor history could not be trusted; no check was requested."
        case .observationFailed: return "OBSERVATION_FAILED: The new monitor snapshot could not be verified; state may have changed."
        case .historyWriteFailed: return "HISTORY_WRITE_FAILED: Monitor counters and history changed in memory; the history file may have been partially written."
        }
    }
}

struct LocalOperationsMonitor {
    static let pollIntervalSeconds: TimeInterval = 5
    static let failureThreshold = 3
    static let recoveryThreshold = 2
    static let maximumHistory = 120

    private(set) var snapshot = LocalMonitorSnapshot.empty
    private(set) var history: [LocalMonitorEvent] = []
    private var consecutiveFailures: [String: Int] = [:]
    private var consecutiveSuccesses: [String: Int] = [:]
    private var confirmedFaults = Set<String>()

    init(history: [LocalMonitorEvent] = []) {
        self.history = Array(history.suffix(Self.maximumHistory))
    }

    mutating func update(_ probes: [LocalMonitorProbe], at time: Date) -> [LocalMonitorEvent] {
        guard time.timeIntervalSince1970.isFinite,
              Set(probes.map(\.id)).count == probes.count,
              probes.allSatisfy({ $0.checkedAt.timeIntervalSince1970.isFinite }) else { return [] }
        snapshot = LocalMonitorSnapshot(probes: probes, checkedAt: time)
        var changes: [LocalMonitorEvent] = []
        for probe in probes {
            switch probe.status {
            case .down:
                consecutiveFailures[probe.id, default: 0] += 1
                consecutiveSuccesses[probe.id] = 0
                if consecutiveFailures[probe.id, default: 0] >= Self.failureThreshold,
                   confirmedFaults.insert(probe.id).inserted {
                    changes.append(LocalMonitorEvent(occurredAt: time, probeID: probe.id, label: probe.label,
                                                     kind: .fault, detail: probe.detail))
                }
            case .healthy:
                consecutiveFailures[probe.id] = 0
                consecutiveSuccesses[probe.id, default: 0] += 1
                if consecutiveSuccesses[probe.id, default: 0] >= Self.recoveryThreshold,
                   confirmedFaults.remove(probe.id) != nil {
                    changes.append(LocalMonitorEvent(occurredAt: time, probeID: probe.id, label: probe.label,
                                                     kind: .recovered, detail: probe.detail))
                }
            case .warning, .inactive:
                consecutiveFailures[probe.id] = 0
                consecutiveSuccesses[probe.id] = 0
            }
        }
        history = Array((history + changes).suffix(Self.maximumHistory))
        return changes
    }
}

enum LocalOperationsMonitorStore {
    static let maximumBytes = 256 * 1024
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CameraWall/monitor-history.json")
    }

    static func load(from url: URL = defaultURL) throws -> [LocalMonitorEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= maximumBytes else {
            throw ConfigurationError.invalid("Local monitor history exceeds its size limit.")
        }
        let events = try JSONDecoder().decode([LocalMonitorEvent].self, from: Data(contentsOf: url))
        guard events.count <= LocalOperationsMonitor.maximumHistory,
              events.allSatisfy({
                  $0.occurredAt.timeIntervalSince1970.isFinite && $0.probeID.count <= 80
                      && $0.label.count <= 120 && $0.detail.count <= 500
              }) else { throw ConfigurationError.invalid("Local monitor history is invalid.") }
        return events
    }

    static func save(_ events: [LocalMonitorEvent], to url: URL = defaultURL) throws {
        let bounded = Array(events.suffix(LocalOperationsMonitor.maximumHistory))
        let data = try JSONEncoder().encode(bounded)
        guard data.count <= maximumBytes else { throw ConfigurationError.invalid("Local monitor history exceeds its size limit.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}