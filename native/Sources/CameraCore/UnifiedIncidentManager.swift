import Foundation

public enum SecondaryVerificationStatus: String, Codable, CaseIterable, Sendable {
    case notRequested = "NOT_REQUESTED"
    case pending = "PENDING"
    case confirmed = "CONFIRMED"
    case rejected = "REJECTED"
    case unavailable = "UNAVAILABLE"
}

public struct SafetyIncident: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let cameraID: UUID
    public var cameraName: String
    public var trackIDs: [UUID]
    public var zoneID: UUID?
    public var zoneName: String?
    public var type: SafetyIncidentType
    public var severity: SafetyIncidentSeverity
    public var status: SafetyIncidentStatus
    public var confidence: Double
    public let createdAt: Date
    public var updatedAt: Date
    public var acknowledgedAt: Date?
    public var resolvedAt: Date?
    public var title: String
    public var explanation: String
    public var detectorSource: String
    public var primaryBox: FallBoundingBox?
    public var keypoints: [FallKeypoint]
    public var metrics: [String: Double]
    public var clipID: UUID?
    public var snapshotRelativePath: String?
    public var secondaryVLMStatus: SecondaryVerificationStatus
    public var secondaryVLMSummary: String?
    public var operatorNotes: String
    public var escalationCount: Int

    public init(
        id: UUID = UUID(),
        cameraID: UUID,
        cameraName: String,
        trackIDs: [UUID],
        zoneID: UUID? = nil,
        zoneName: String? = nil,
        type: SafetyIncidentType,
        severity: SafetyIncidentSeverity,
        status: SafetyIncidentStatus = .active,
        confidence: Double,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        acknowledgedAt: Date? = nil,
        resolvedAt: Date? = nil,
        title: String,
        explanation: String,
        detectorSource: String,
        primaryBox: FallBoundingBox? = nil,
        keypoints: [FallKeypoint] = [],
        metrics: [String: Double] = [:],
        clipID: UUID? = nil,
        snapshotRelativePath: String? = nil,
        secondaryVLMStatus: SecondaryVerificationStatus = .notRequested,
        secondaryVLMSummary: String? = nil,
        operatorNotes: String = "",
        escalationCount: Int = 0
    ) {
        self.id = id
        self.cameraID = cameraID
        self.cameraName = cameraName
        self.trackIDs = trackIDs
        self.zoneID = zoneID
        self.zoneName = zoneName
        self.type = type
        self.severity = severity
        self.status = status
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.acknowledgedAt = acknowledgedAt
        self.resolvedAt = resolvedAt
        self.title = title
        self.explanation = explanation
        self.detectorSource = detectorSource
        self.primaryBox = primaryBox
        self.keypoints = keypoints
        self.metrics = metrics
        self.clipID = clipID
        self.snapshotRelativePath = snapshotRelativePath
        self.secondaryVLMStatus = secondaryVLMStatus
        self.secondaryVLMSummary = secondaryVLMSummary
        self.operatorNotes = operatorNotes
        self.escalationCount = escalationCount
    }
}

public struct OperatorAuditEntry: Codable, Equatable, Identifiable, Sendable {
    public enum ActionType: String, Codable, CaseIterable, Sendable {
        case incidentCreated = "INCIDENT_CREATED"
        case incidentEscalated = "INCIDENT_ESCALATED"
        case incidentAcknowledged = "INCIDENT_ACKNOWLEDGED"
        case incidentConfirmed = "INCIDENT_CONFIRMED"
        case incidentMarkedFalsePositive = "INCIDENT_MARKED_FALSE_POSITIVE"
        case incidentSuppressed = "INCIDENT_SUPPRESSED"
        case incidentResolved = "INCIDENT_RESOLVED"
        case incidentClosed = "INCIDENT_CLOSED"
        case incidentReopened = "INCIDENT_REOPENED"
        case secondaryVLMVerified = "SECONDARY_VLM_VERIFIED"
        case settingsUpdated = "SETTINGS_UPDATED"
        case settingsResetToDefaults = "SETTINGS_RESET_TO_DEFAULTS"
        case engineStateChanged = "ENGINE_STATE_CHANGED"
        case evidenceDeleted = "EVIDENCE_DELETED"
    }

    public let id: UUID
    public let occurredAt: Date
    public let action: ActionType
    public let incidentID: UUID?
    public let cameraID: UUID?
    public let summary: String
    public let details: String

    public init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        action: ActionType,
        incidentID: UUID? = nil,
        cameraID: UUID? = nil,
        summary: String,
        details: String = ""
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.action = action
        self.incidentID = incidentID
        self.cameraID = cameraID
        self.summary = summary
        self.details = details
    }
}

public final class OperatorAuditLog: @unchecked Sendable {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CameraWall/operator-audit-log.json")
    }

    public let url: URL
    public let maxEntries: Int
    private let lock = NSLock()
    private var entries: [OperatorAuditEntry] = []

    public init(url: URL = OperatorAuditLog.defaultURL, maxEntries: Int = 1000) {
        self.url = url
        self.maxEntries = max(50, maxEntries)
        self.entries = (try? Self.loadFromDisk(url: url)) ?? []
    }

    public func record(
        action: OperatorAuditEntry.ActionType,
        incidentID: UUID? = nil,
        cameraID: UUID? = nil,
        summary: String,
        details: String = "",
        at date: Date = Date()
    ) {
        lock.lock()
        let entry = OperatorAuditEntry(
            occurredAt: date,
            action: action,
            incidentID: incidentID,
            cameraID: cameraID,
            summary: summary,
            details: details
        )
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        let snapshot = entries
        lock.unlock()
        try? Self.saveToDisk(snapshot, url: url)
    }

    public func recentEntries(limit: Int = 200) -> [OperatorAuditEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.prefix(max(1, limit)))
    }

    private static func loadFromDisk(url: URL) throws -> [OperatorAuditEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([OperatorAuditEntry].self, from: data)
    }

    private static func saveToDisk(_ entries: [OperatorAuditEntry], url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public final class UnifiedIncidentManager: @unchecked Sendable {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CameraWall/safety-incidents.json")
    }

    public let storageURL: URL
    public let maxIncidents: Int
    public let auditLog: OperatorAuditLog

    private let lock = NSLock()
    private var incidents: [SafetyIncident] = []
    private var suppressionUntilByKey: [String: Date] = [:]

    public init(
        storageURL: URL = UnifiedIncidentManager.defaultURL,
        maxIncidents: Int = 500,
        auditLog: OperatorAuditLog = OperatorAuditLog()
    ) {
        self.storageURL = storageURL
        self.maxIncidents = max(50, maxIncidents)
        self.auditLog = auditLog
        self.incidents = (try? Self.loadFromDisk(url: storageURL)) ?? []
    }

    public func allIncidents() -> [SafetyIncident] {
        lock.lock()
        defer { lock.unlock() }
        return incidents
    }

    public func incident(id: UUID) -> SafetyIncident? {
        lock.lock()
        defer { lock.unlock() }
        return incidents.first { $0.id == id }
    }

    public func openCriticalCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return incidents.filter { $0.status.isOpen && $0.severity == .critical }.count
    }

    public func unacknowledgedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return incidents.filter {
            ($0.status == .candidate || $0.status == .confirmed || $0.status == .active)
        }.count
    }

    /// Ingests a safety candidate, applying suppression, deduplication, and escalation rules.
    /// Returns the created or updated `SafetyIncident`, or `nil` if suppressed.
    @discardableResult
    public func ingest(
        candidate: BehaviorSafetyCandidate,
        cameraName: String,
        clipID: UUID? = nil,
        snapshotRelativePath: String? = nil,
        cooldownSeconds: Double = 30.0
    ) -> SafetyIncident? {
        lock.lock()
        let now = candidate.occurredAt

        // Check suppression rules
        let suppressionKey = "\(candidate.cameraID.uuidString):\(candidate.type.rawValue)"
        if let suppressedUntil = suppressionUntilByKey[suppressionKey], now < suppressedUntil {
            lock.unlock()
            return nil
        }

        // Escalation / deduplication check:
        // 1. If PERSON_DOWN arrives while an open FALL_CONFIRMED exists for the same camera, escalate it.
        if candidate.type == .personDown,
           let idx = incidents.firstIndex(where: {
               $0.cameraID == candidate.cameraID
                   && ($0.type == .fallConfirmed || $0.type == .personDown)
                   && $0.status.isOpen
                   && now.timeIntervalSince($0.createdAt) <= max(cooldownSeconds * 4, 180)
           }) {
            var existing = incidents[idx]
            existing.type = .personDown
            existing.severity = .critical
            existing.title = SafetyIncidentType.personDown.displayTitle
            existing.explanation = candidate.explanation
            existing.updatedAt = now
            existing.escalationCount += 1
            existing.metrics.merge(candidate.metrics) { _, new in new }
            if let clipID { existing.clipID = clipID }
            if let snapshotRelativePath { existing.snapshotRelativePath = snapshotRelativePath }
            incidents[idx] = existing
            let snapshotList = incidents
            lock.unlock()

            try? Self.saveToDisk(snapshotList, url: storageURL)
            auditLog.record(
                action: .incidentEscalated,
                incidentID: existing.id,
                cameraID: existing.cameraID,
                summary: "Escalated incident to PERSON_DOWN on \(cameraName)",
                details: candidate.explanation,
                at: now
            )
            return existing
        }

        // 2. Deduplicate identical incident type on same camera within cooldown window
        if let idx = incidents.firstIndex(where: {
            $0.cameraID == candidate.cameraID
                && $0.type == candidate.type
                && $0.status != .falsePositive
                && now.timeIntervalSince($0.updatedAt) < max(2.0, cooldownSeconds)
        }) {
            var existing = incidents[idx]
            existing.updatedAt = now
            existing.confidence = max(existing.confidence, candidate.confidence)
            existing.escalationCount += 1
            if existing.clipID == nil, let clipID {
                existing.clipID = clipID
            }
            if existing.snapshotRelativePath == nil, let snapshotRelativePath {
                existing.snapshotRelativePath = snapshotRelativePath
            }
            incidents[idx] = existing
            let snapshotList = incidents
            lock.unlock()
            try? Self.saveToDisk(snapshotList, url: storageURL)
            return existing
        }

        let initialStatus: SafetyIncidentStatus = (candidate.type == .possiblePhysicalFight && candidate.requiresSecondaryVLMVerification)
            ? .candidate
            : .active
        let vlmStatus: SecondaryVerificationStatus = candidate.requiresSecondaryVLMVerification ? .pending : .notRequested

        let newIncident = SafetyIncident(
            id: candidate.id,
            cameraID: candidate.cameraID,
            cameraName: cameraName,
            trackIDs: candidate.trackIDs,
            zoneID: candidate.zoneID,
            zoneName: candidate.zoneName,
            type: candidate.type,
            severity: candidate.severity,
            status: initialStatus,
            confidence: candidate.confidence,
            createdAt: now,
            updatedAt: now,
            title: candidate.title,
            explanation: candidate.explanation,
            detectorSource: candidate.detectorSource,
            primaryBox: candidate.primaryBox,
            keypoints: candidate.keypoints,
            metrics: candidate.metrics,
            clipID: clipID,
            snapshotRelativePath: snapshotRelativePath,
            secondaryVLMStatus: vlmStatus
        )

        incidents.insert(newIncident, at: 0)
        if incidents.count > maxIncidents {
            incidents.removeLast(incidents.count - maxIncidents)
        }
        let snapshotList = incidents
        lock.unlock()

        try? Self.saveToDisk(snapshotList, url: storageURL)
        auditLog.record(
            action: .incidentCreated,
            incidentID: newIncident.id,
            cameraID: newIncident.cameraID,
            summary: "\(newIncident.type.rawValue) [\(newIncident.severity.rawValue)] on \(cameraName)",
            details: newIncident.explanation,
            at: now
        )
        return newIncident
    }

    @discardableResult
    public func attachEvidence(
        incidentID: UUID,
        clipID: UUID?,
        snapshotRelativePath: String?
    ) -> SafetyIncident? {
        lock.lock()
        guard let idx = incidents.firstIndex(where: { $0.id == incidentID }) else {
            lock.unlock()
            return nil
        }
        if let clipID { incidents[idx].clipID = clipID }
        if let snapshotRelativePath { incidents[idx].snapshotRelativePath = snapshotRelativePath }
        incidents[idx].updatedAt = Date()
        let updated = incidents[idx]
        let snapshotList = incidents
        lock.unlock()
        try? Self.saveToDisk(snapshotList, url: storageURL)
        return updated
    }

    @discardableResult
    public func recordSecondaryVLMVerification(
        incidentID: UUID,
        status: SecondaryVerificationStatus,
        summary: String,
        at now: Date = Date()
    ) -> SafetyIncident? {
        lock.lock()
        guard let idx = incidents.firstIndex(where: { $0.id == incidentID }) else {
            lock.unlock()
            return nil
        }
        var item = incidents[idx]
        item.secondaryVLMStatus = status
        item.secondaryVLMSummary = summary
        item.updatedAt = now
        if status == .confirmed && item.status == .candidate {
            item.status = .confirmed
        } else if status == .rejected && item.status == .candidate {
            // Only auto-demote candidate heuristics (e.g. Stage-A fight); never auto-dismiss primary fall alerts
            item.status = .falsePositive
        }
        incidents[idx] = item
        let snapshotList = incidents
        lock.unlock()

        try? Self.saveToDisk(snapshotList, url: storageURL)
        auditLog.record(
            action: .secondaryVLMVerified,
            incidentID: item.id,
            cameraID: item.cameraID,
            summary: "Secondary VLM verification: \(status.rawValue)",
            details: summary,
            at: now
        )
        return item
    }

    @discardableResult
    public func transitionStatus(
        incidentID: UUID,
        to newStatus: SafetyIncidentStatus,
        operatorNote: String? = nil,
        suppressDurationSeconds: TimeInterval? = nil,
        at now: Date = Date()
    ) -> SafetyIncident? {
        lock.lock()
        guard let idx = incidents.firstIndex(where: { $0.id == incidentID }) else {
            lock.unlock()
            return nil
        }
        var item = incidents[idx]
        item.status = newStatus
        item.updatedAt = now
        if let operatorNote, !operatorNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.operatorNotes = operatorNote.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch newStatus {
        case .acknowledged:
            item.acknowledgedAt = item.acknowledgedAt ?? now
        case .resolved, .closed:
            item.resolvedAt = item.resolvedAt ?? now
        case .suppressed:
            let duration = suppressDurationSeconds ?? 300
            let key = "\(item.cameraID.uuidString):\(item.type.rawValue)"
            suppressionUntilByKey[key] = now.addingTimeInterval(duration)
        default:
            break
        }
        incidents[idx] = item
        let snapshotList = incidents
        lock.unlock()

        try? Self.saveToDisk(snapshotList, url: storageURL)

        let auditAction: OperatorAuditEntry.ActionType
        switch newStatus {
        case .acknowledged: auditAction = .incidentAcknowledged
        case .confirmed, .active: auditAction = .incidentConfirmed
        case .falsePositive: auditAction = .incidentMarkedFalsePositive
        case .suppressed: auditAction = .incidentSuppressed
        case .resolved: auditAction = .incidentResolved
        case .closed: auditAction = .incidentClosed
        case .candidate: auditAction = .incidentReopened
        }
        auditLog.record(
            action: auditAction,
            incidentID: item.id,
            cameraID: item.cameraID,
            summary: "Incident status -> \(newStatus.rawValue) (\(item.title))",
            details: item.operatorNotes,
            at: now
        )
        return item
    }

    /// Converts and ingests a `WorkerEventEnvelope` from Distributed Mode (`WorkerEventSpool`) into the unified incident store.
    @discardableResult
    public func ingestWorkerEnvelope(
        _ envelope: WorkerEventEnvelope,
        cameraName: String,
        cooldownSeconds: Double = 30.0
    ) -> SafetyIncident? {
        guard let payloadData = envelope.payloadJSON.data(using: .utf8),
              let fallEvent = try? JSONDecoder().decode(FallEvent.self, from: payloadData) else {
            return nil
        }
        let incidentType: SafetyIncidentType = (fallEvent.phase == .personDown) ? .personDown : .fallConfirmed
        var metrics: [String: Double] = [
            "aspectRatio": fallEvent.metrics.aspectRatio,
            "persistenceSeconds": fallEvent.persistenceSeconds
        ]
        if let angle = fallEvent.metrics.torsoAngleDegrees {
            metrics["torsoAngleDegrees"] = angle
        }
        if let ratio = fallEvent.metrics.heightRatio {
            metrics["heightRatio"] = ratio
        }
        let candidate = BehaviorSafetyCandidate(
            id: envelope.id,
            cameraID: envelope.cameraID,
            trackIDs: [fallEvent.trackID],
            type: incidentType,
            severity: .critical,
            confidence: fallEvent.confidence,
            monotonicTimestamp: fallEvent.occurredAt,
            occurredAt: envelope.occurredAt,
            primaryBox: fallEvent.box,
            keypoints: fallEvent.keypoints,
            explanation: String(
                format: "Distributed worker (%@) reported %@ after %.1f s (aspect ratio %.2f).",
                String(envelope.workerID.uuidString.prefix(8)),
                incidentType.rawValue,
                fallEvent.occurredAt - fallEvent.fallStartedAt,
                fallEvent.metrics.aspectRatio
            ),
            detectorSource: "DistributedWorker:\(envelope.workerID.uuidString.prefix(8))",
            requiresSecondaryVLMVerification: false,
            metrics: metrics
        )
        return ingest(candidate: candidate, cameraName: cameraName, cooldownSeconds: cooldownSeconds)
    }

    public func clearResolvedAndClosed() {
        lock.lock()
        incidents.removeAll { !$0.status.isOpen }
        let snapshotList = incidents
        lock.unlock()
        try? Self.saveToDisk(snapshotList, url: storageURL)
    }

    private static func loadFromDisk(url: URL) throws -> [SafetyIncident] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([SafetyIncident].self, from: data)
    }

    private static func saveToDisk(_ incidents: [SafetyIncident], url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(incidents)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
