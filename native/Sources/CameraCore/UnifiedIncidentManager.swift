import Foundation
import Darwin

public enum SecondaryVerificationStatus: String, Codable, CaseIterable, Sendable {
    case notRequested = "NOT_REQUESTED"
    case pending = "PENDING"
    case confirmed = "CONFIRMED"
    case rejected = "REJECTED"
    case unavailable = "UNAVAILABLE"
    case inconclusive = "INCONCLUSIVE"
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
    public var suppressedUntil: Date? = nil
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
        case incidentNoteUpdated = "INCIDENT_NOTE_UPDATED"
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
    private enum CoordinationError: LocalizedError {
        case busy, pendingOverflow, recoveryRequired

        var errorDescription: String? {
            switch self {
            case .busy: return "Operator audit history is busy in another writer."
            case .pendingOverflow: return "Pending operator audit entries exceed the history limit; they cannot be saved without truncation."
            case .recoveryRequired: return "Incident/audit transaction recovery is required before accessing audit history."
            }
        }
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CameraWall/operator-audit-log.json")
    }

    public let url: URL
    public let maxEntries: Int
    private let lock = NSLock()
    private let loadEntries: () throws -> [OperatorAuditEntry]
    private let saveEntries: ([OperatorAuditEntry]) throws -> Void
    private let coordinated: Bool
    private let startupRecoveryEnabled: Bool
    private var persistenceError: String?
    private var loadFailed = false
    private var pendingEntries: [OperatorAuditEntry] = []

    /// A failed load is sticky: never overwrite an unreadable history with an empty snapshot.
    public var lastPersistenceError: String? {
        lock.lock()
        defer { lock.unlock() }
        return persistenceError
    }

    private var entries: [OperatorAuditEntry] = []

    public convenience init(url: URL = OperatorAuditLog.defaultURL, maxEntries: Int = 1000) {
        self.init(url: url, maxEntries: maxEntries,
                  load: { try Self.loadFromDisk(url: url) },
                  save: { try Self.saveToDisk($0, url: url) }, coordinated: true,
                  startupRecoveryEnabled: true)
    }

    // The injected in-memory store retains its existing single-instance semantics.
    init(url: URL, maxEntries: Int = 1000, load: @escaping () throws -> [OperatorAuditEntry],
         save: @escaping ([OperatorAuditEntry]) throws -> Void) {
        self.url = url
        self.maxEntries = max(50, maxEntries)
        self.loadEntries = load
        self.saveEntries = save
        self.coordinated = false
        self.startupRecoveryEnabled = false
        do { self.entries = try load() }
        catch {
            loadFailed = true
            persistenceError = "Cannot load operator audit history: \(error.localizedDescription)"
        }
    }

    // Internal injection permits testing failures before and after publication.
    init(url: URL, maxEntries: Int = 1000, load: @escaping () throws -> [OperatorAuditEntry],
         save: @escaping ([OperatorAuditEntry]) throws -> Void, coordinated: Bool,
         startupRecoveryEnabled: Bool = false) {
        self.url = url
        self.maxEntries = max(50, maxEntries)
        self.loadEntries = load
        self.saveEntries = save
        self.coordinated = coordinated
        self.startupRecoveryEnabled = startupRecoveryEnabled
        refreshCoordinatedLocked()
    }

    fileprivate var participatesInStartupRecovery: Bool { startupRecoveryEnabled }

    fileprivate func commitIncidentMutation(
        store: IncidentAuditTransactionStore, expected: Data?, incidents: Data,
        entry: OperatorAuditEntry
    ) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard !loadFailed, pendingEntries.isEmpty, persistenceError == nil else {
            throw ConfigurationError.invalid("Operator audit history must be reconciled before changing incidents.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var savedAudit: [OperatorAuditEntry] = []
        let result = try store.update(refusingPendingJournal: true) { before in
            guard before.incidents == expected else {
                throw IncidentAuditTransactionStore.StoreError.recoveryConflict
            }
            let diskEntries = try before.audit.map { try decoder.decode([OperatorAuditEntry].self, from: $0) } ?? []
            savedAudit = Array(([entry] + diskEntries).prefix(maxEntries))
            return .init(incidents: incidents, audit: try encoder.encode(savedAudit))
        }
        entries = savedAudit
        guard let savedIncidents = result.incidents else {
            throw IncidentAuditTransactionStore.StoreError.invalidDocument
        }
        return savedIncidents
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
        if coordinated {
            pendingEntries.insert(entry, at: 0)
            persistCoordinatedLocked()
        } else {
            entries.insert(entry, at: 0)
            if entries.count > maxEntries {
                entries.removeLast(entries.count - maxEntries)
            }
            persistLocked()
        }
        lock.unlock()
    }

    public func recentEntries(limit: Int = 200) -> [OperatorAuditEntry] {
        lock.lock()
        defer { lock.unlock() }
        if coordinated {
            if pendingEntries.isEmpty {
                refreshCoordinatedLocked()
            } else {
                persistCoordinatedLocked()
            }
        }
        return Array(entries.prefix(max(1, limit)))
    }

    private func merged(_ disk: [OperatorAuditEntry]) -> [OperatorAuditEntry] {
        let pendingIDs = Set(pendingEntries.map(\.id))
        return pendingEntries + disk.filter { !pendingIDs.contains($0.id) }
    }

    private func readCoordinatedLocked() throws -> [OperatorAuditEntry] {
        do { return try loadEntries() }
        catch {
            loadFailed = true
            persistenceError = "Cannot load operator audit history: \(error.localizedDescription)"
            throw error
        }
    }

    private func refreshCoordinatedLocked() {
        guard !loadFailed else {
            entries = merged(entries)
            return
        }
        do {
            try withDiskLock {
                entries = merged(try readCoordinatedLocked())
                if pendingEntries.isEmpty { persistenceError = nil }
            }
        } catch {
            entries = merged(entries)
            if !loadFailed && pendingEntries.isEmpty {
                persistenceError = "Cannot access operator audit history: \(error.localizedDescription)"
            } else if !loadFailed && persistenceError == nil {
                persistenceError = "Cannot access operator audit history: \(error.localizedDescription)"
            }
        }
    }

    private func persistCoordinatedLocked() {
        guard !loadFailed else {
            entries = merged(entries)
            return
        }
        guard pendingEntries.count <= maxEntries else {
            entries = merged(entries)
            persistenceError = "Cannot save operator audit history: \(CoordinationError.pendingOverflow.localizedDescription)"
            return
        }
        do {
            try withDiskLock {
                let combined = merged(try readCoordinatedLocked())
                entries = combined
                let snapshot = Array(combined.prefix(maxEntries))
                try saveEntries(snapshot)
                pendingEntries.removeAll()
                entries = snapshot
                persistenceError = nil
            }
        } catch {
            entries = merged(entries)
            if !loadFailed {
                persistenceError = "Cannot save operator audit history: \(error.localizedDescription)"
            }
        }
    }

    // Lock a stable sidecar, not the JSON inode replaced by atomic writes.
    // Every writer must cooperate; old versions and external editors do not.
    private func withDiskLock<T>(_ body: () throws -> T) throws -> T {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(dir) }
        let fd = try IncidentAuditTransactionStore.openCoordinationLock(
            directory: dir, name: IncidentAuditTransactionStore.auditLockName(for: url.lastPathComponent))
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno == EWOULDBLOCK { throw CoordinationError.busy }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(fd, LOCK_UN) }
        try IncidentAuditTransactionStore.verifyCoordinationLock(
            directory: dir, name: IncidentAuditTransactionStore.auditLockName(for: url.lastPathComponent), fd: fd)
        // An interrupted transaction must recover before independent audit access resumes.
        var journal = stat()
        if fstatat(dir, IncidentAuditTransactionStore.journalName, &journal, AT_SYMLINK_NOFOLLOW) == 0 {
            throw CoordinationError.recoveryRequired
        }
        guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try body()
    }

    private func persistLocked() {
        guard !loadFailed else { return }
        do {
            try saveEntries(entries)
            persistenceError = nil
        } catch { persistenceError = "Cannot save operator audit history: \(error.localizedDescription)" }
    }

    private static func loadFromDisk(url: URL) throws -> [OperatorAuditEntry] {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return [] }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw CocoaError(.fileReadUnknown)
        }
        let data = try handle.readToEnd() ?? Data()
        try IncidentAuditTransactionStore.validateCompatibility(data, .audit)
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

/// A point-in-time revision of one manager's memory only. Other manager
/// instances, audit writes, disk edits and other processes are not coordinated.
public struct IncidentLocalRevisionSnapshot: Sendable {
    public let revision: UUID
    public let incident: SafetyIncident
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
    private let saveIncidents: ([SafetyIncident]) throws -> Void
    private var localRevision = UUID()
    private var persistenceError: String?
    private var loadFailed = false
    private struct LegacyWriteFence {
        let store: IncidentAuditTransactionStore
        var expected: Data?
    }
    private var legacyWriteFence: LegacyWriteFence?
    private var legacyWriteIndeterminate = false

    /// A failed load is sticky: never overwrite an unreadable history with an empty snapshot.
    public var lastPersistenceError: String? {
        lock.lock()
        defer { lock.unlock() }
        return persistenceError
    }

    private var incidents: [SafetyIncident] = []
    private var suppressionUntilByKey: [String: Date] = [:]

    public convenience init(
        storageURL: URL = UnifiedIncidentManager.defaultURL,
        maxIncidents: Int = 500,
        auditLog: OperatorAuditLog = OperatorAuditLog()
    ) {
        self.init(storageURL: storageURL, maxIncidents: maxIncidents, auditLog: auditLog,
                  transactionFault: { _ in })
    }

    convenience init(storageURL: URL, maxIncidents: Int = 500, auditLog: OperatorAuditLog,
                     transactionFault: @escaping (IncidentAuditTransactionStore.Boundary) throws -> Void) {
        var fence: LegacyWriteFence?
        self.init(storageURL: storageURL, maxIncidents: maxIncidents, auditLog: auditLog,
                  load: {
                      let loaded = try Self.loadAfterStartupRecovery(url: storageURL, auditLog: auditLog,
                                                                     transactionFault: transactionFault)
                      fence = loaded.fence
                      return loaded.incidents
                  },
                  save: { try Self.saveToDisk($0, url: storageURL) })
        self.legacyWriteFence = fence
    }

    init(storageURL: URL, maxIncidents: Int = 500, auditLog: OperatorAuditLog,
         load: () throws -> [SafetyIncident], save: @escaping ([SafetyIncident]) throws -> Void) {
        self.storageURL = storageURL
        self.maxIncidents = max(50, maxIncidents)
        self.auditLog = auditLog
        self.saveIncidents = save
        do { self.incidents = try load() }
        catch {
            loadFailed = true
            persistenceError = "Cannot load incident history: \(error.localizedDescription)"
        }
        for incident in incidents where incident.status == .suppressed {
            if let until = incident.suppressedUntil, until > Date() {
                let key = "\(incident.cameraID.uuidString):\(incident.type.rawValue)"
                suppressionUntilByKey[key] = max(suppressionUntilByKey[key] ?? .distantPast, until)
            }
        }
    }

    /// Called once by application startup. An interrupted secondary request must
    /// not remain pending forever or be mistaken for a completed verification.
    public func recoverInterruptedVerifications() {
        lock.lock()
        defer { lock.unlock() }
        let previous = incidents
        var changed = false
        for index in incidents.indices where incidents[index].secondaryVLMStatus == .pending {
            incidents[index].secondaryVLMStatus = .unavailable
            incidents[index].secondaryVLMSummary = "Secondary verification interrupted; primary detection preserved"
            changed = true
        }
        if changed {
            persistLocked()
            if persistenceError != nil { incidents = previous }
        }
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

    /// Not a commit permit: it does not observe audit, disk or other processes.
    public func localRevisionSnapshot(incidentID: UUID) -> IncidentLocalRevisionSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard !loadFailed, persistenceError == nil else { return nil }
        let matches = incidents.filter { $0.id == incidentID }
        guard matches.count == 1, let incident = matches.first else { return nil }
        return IncidentLocalRevisionSnapshot(revision: localRevision, incident: incident)
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
            finishIncidentMutationAndAudit(
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
            persistLocked()
            lock.unlock()
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
        finishIncidentMutationAndAudit(
            action: .incidentCreated,
            incidentID: newIncident.id,
            cameraID: newIncident.cameraID,
            summary: "\(newIncident.type.rawValue) [\(newIncident.severity.rawValue)] on \(cameraName)",
            details: newIncident.explanation,
            at: now
        )
        return newIncident
    }

    /// Deduplicate first, then create at most one bundle under the canonical incident ID.
    /// Evidence failures never suppress the primary safety incident.
    @discardableResult
    public func ingestWithEvidence(candidate: BehaviorSafetyCandidate, cameraName: String,
                                   evidenceStore: SafetyEvidenceStore, triggerSnapshotJPEG: Data?,
                                   enableEvidence: Bool, postEventBufferSeconds: Double = 6,
                                   maxDiskQuotaMB: Int = 2048, cooldownSeconds: Double = 30) -> SafetyIncident? {
        guard let incident = ingest(candidate: candidate, cameraName: cameraName, cooldownSeconds: cooldownSeconds) else { return nil }
        guard enableEvidence, incident.clipID == nil else { return incident }
        do {
            let bundle = try evidenceStore.createEvidenceBundle(for: candidate, incidentID: incident.id,
                cameraName: cameraName, triggerSnapshotJPEG: triggerSnapshotJPEG,
                postEventBufferSeconds: postEventBufferSeconds, maxDiskQuotaMB: maxDiskQuotaMB, now: candidate.occurredAt)
            return attachEvidence(incidentID: incident.id, clipID: bundle.bundleID,
                snapshotRelativePath: bundle.snapshotRelativePath) ?? incident
        } catch {
            // The evidence store exposes the error; keep the original alert visible.
            return incident
        }
    }

    public func updateOperatorNote(incidentID: UUID, note: String) {
        lock.lock()
        guard let index = incidents.firstIndex(where: { $0.id == incidentID }) else { lock.unlock(); return }
        let previous = incidents[index]
        let value = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        incidents[index].operatorNotes = value
        incidents[index].updatedAt = Date()
        let cameraID = incidents[index].cameraID
        finishIncidentMutationAndAudit(action: .incidentNoteUpdated, incidentID: incidentID, cameraID: cameraID,
            summary: "Updated operator incident note", details: value,
            onFailure: { incidents[index] = previous })
    }

    public func clearEvidenceReferences(incidentID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = incidents.firstIndex(where: { $0.id == incidentID }) else { return }
        let previous = incidents[index]
        incidents[index].clipID = nil
        incidents[index].snapshotRelativePath = nil
        persistLocked()
        if persistenceError != nil { incidents[index] = previous }
    }

    /// Call only after verifying that the evidence bundle was removed.
    @discardableResult
    public func clearEvidenceReferencesAndAudit(incidentID: UUID) -> Bool {
        lock.lock()
        guard let index = incidents.firstIndex(where: { $0.id == incidentID }) else {
            lock.unlock()
            return false
        }
        let previous = incidents[index]
        incidents[index].clipID = nil
        incidents[index].snapshotRelativePath = nil
        return finishIncidentMutationAndAudit(
            action: .evidenceDeleted, incidentID: incidentID, cameraID: previous.cameraID,
            summary: "Operator deleted stored evidence bundle for incident \(incidentID.uuidString.prefix(8))",
            details: "", onFailure: { incidents[index] = previous })
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
        let previous = incidents[idx]
        if let clipID { incidents[idx].clipID = clipID }
        if let snapshotRelativePath { incidents[idx].snapshotRelativePath = snapshotRelativePath }
        incidents[idx].updatedAt = Date()
        persistLocked()
        if persistenceError != nil {
            incidents[idx] = previous
            lock.unlock()
            return nil
        }
        let updated = incidents[idx]
        lock.unlock()
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
        let previous = incidents[idx]
        var item = previous
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
        let committed = finishIncidentMutationAndAudit(
            action: .secondaryVLMVerified,
            incidentID: item.id,
            cameraID: item.cameraID,
            summary: "Secondary VLM verification: \(status.rawValue)",
            details: summary,
            at: now,
            onFailure: { incidents[idx] = previous }
        )
        return committed ? item : nil
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
        let previousIncidents = incidents
        let previousSuppression = suppressionUntilByKey
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
            item.suppressedUntil = now.addingTimeInterval(duration)
            suppressionUntilByKey[key] = item.suppressedUntil
        default:
            break
        }
        if newStatus.isOpen {
            let key = "\(item.cameraID.uuidString):\(item.type.rawValue)"
            suppressionUntilByKey.removeValue(forKey: key)
            for index in incidents.indices where incidents[index].cameraID == item.cameraID && incidents[index].type == item.type {
                incidents[index].suppressedUntil = nil
            }
            item.suppressedUntil = nil
        }
        incidents[idx] = item
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
        let committed = finishIncidentMutationAndAudit(
            action: auditAction,
            incidentID: item.id,
            cameraID: item.cameraID,
            summary: "Incident status -> \(newStatus.rawValue) (\(item.title))",
            details: item.operatorNotes,
            at: now,
            onFailure: {
                incidents = previousIncidents
                suppressionUntilByKey = previousSuppression
            }
        )
        return committed ? item : nil
    }

    @discardableResult
    private func finishIncidentMutationAndAudit(action: OperatorAuditEntry.ActionType, incidentID: UUID,
                                                cameraID: UUID, summary: String, details: String,
                                                at date: Date = Date(), onFailure: () -> Void = {}) -> Bool {
        if var fence = legacyWriteFence {
            localRevision = UUID()
            if !loadFailed && !legacyWriteIndeterminate {
                do {
                    let data = try Self.encodeIncidents(incidents)
                    let entry = OperatorAuditEntry(occurredAt: date, action: action, incidentID: incidentID,
                                                  cameraID: cameraID, summary: summary, details: details)
                    fence.expected = try auditLog.commitIncidentMutation(
                        store: fence.store, expected: fence.expected, incidents: data, entry: entry)
                    legacyWriteFence = fence
                    persistenceError = nil
                } catch {
                    legacyWriteIndeterminate = true
                    persistenceError = "Cannot save incident history and audit: \(error.localizedDescription)"
                }
            }
            let committed = !loadFailed && persistenceError == nil
            if !committed { onFailure() }
            lock.unlock()
            return committed
        } else {
            persistLocked()
            let committed = !loadFailed && persistenceError == nil
            if !committed { onFailure() }
            lock.unlock()
            if committed {
                auditLog.record(action: action, incidentID: incidentID, cameraID: cameraID,
                                summary: summary, details: details, at: date)
            }
            return committed
        }
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
        let previous = incidents
        incidents.removeAll { !$0.status.isOpen }
        persistLocked()
        if persistenceError != nil { incidents = previous }
        lock.unlock()
    }

    private func persistLocked() {
        localRevision = UUID()
        guard !loadFailed else { return }
        guard !legacyWriteIndeterminate else { return }
        do {
            if var fence = legacyWriteFence {
                let data = try Self.encodeIncidents(incidents)
                fence.expected = try fence.store.writeLegacyIncidents(expected: fence.expected, proposed: data) {
                    try Self.saveIncidentData(data, url: storageURL)
                }
                legacyWriteFence = fence
            } else {
                try saveIncidents(incidents)
            }
            persistenceError = nil
        } catch {
            if legacyWriteFence != nil { legacyWriteIndeterminate = true }
            persistenceError = "Cannot save incident history: \(error.localizedDescription)"
        }
    }

    private static func loadFromDisk(url: URL) throws -> [SafetyIncident] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([SafetyIncident].self, from: data)
    }

    private static func loadAfterStartupRecovery(
        url: URL, auditLog: OperatorAuditLog,
        transactionFault: @escaping (IncidentAuditTransactionStore.Boundary) throws -> Void
    ) throws
        -> (incidents: [SafetyIncident], fence: LegacyWriteFence?) {
        guard auditLog.participatesInStartupRecovery, url.isFileURL, auditLog.url.isFileURL else {
            return (try loadFromDisk(url: url), nil)
        }
        let incidentComponents = url.path.split(separator: "/")
        let auditComponents = auditLog.url.path.split(separator: "/")
        if lexicalParent(incidentComponents) == lexicalParent(auditComponents),
           (incidentComponents.contains(".") || incidentComponents.contains("..") ||
            auditComponents.contains(".") || auditComponents.contains("..")) {
            throw ConfigurationError.invalid("Incident or audit path cannot be safely normalized for startup recovery.")
        }
        let incident = url.standardizedFileURL
        let audit = auditLog.url.standardizedFileURL
        guard incident.deletingLastPathComponent() == audit.deletingLastPathComponent() else {
            return (try loadFromDisk(url: url), nil)
        }
        guard url.path == incident.path, auditLog.url.path == audit.path else {
            throw ConfigurationError.invalid("Incident or audit path cannot be safely normalized for startup recovery.")
        }
        let directory = incident.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let store = try IncidentAuditTransactionStore(incidentURL: url, auditURL: auditLog.url,
                                                       fault: transactionFault)
        let result = try store.readAfterStartupRecovery { data -> ([SafetyIncident], Data?) in
            guard let data else { return ([], nil) }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try decoder.decode([SafetyIncident].self, from: data), data)
        }
        if result.recovered {
            _ = auditLog.recentEntries()
            if let error = auditLog.lastPersistenceError {
                throw ConfigurationError.invalid("Audit refresh after incident recovery failed: \(error)")
            }
        }
        return (result.value.0, LegacyWriteFence(store: store, expected: result.value.1))
    }

    private static func lexicalParent(_ components: [Substring]) -> [Substring] {
        var result: [Substring] = []
        for component in components {
            if component == "." { continue }
            if component == ".." {
                if !result.isEmpty { result.removeLast() }
            } else {
                result.append(component)
            }
        }
        if !result.isEmpty { result.removeLast() }
        return result
    }

    private static func saveToDisk(_ incidents: [SafetyIncident], url: URL) throws {
        try saveIncidentData(encodeIncidents(incidents), url: url)
    }

    private static func encodeIncidents(_ incidents: [SafetyIncident]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(incidents)
    }

    private static func saveIncidentData(_ data: Data, url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
