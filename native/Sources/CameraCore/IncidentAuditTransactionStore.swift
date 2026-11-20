import CryptoKit
import Darwin
import Foundation

/// Coordinates participating incident and audit writes and journal recovery.
/// All readers and writers of a pair must participate before its guarantees fully apply.
public final class IncidentAuditTransactionStore {
    public struct Snapshot {
        public let incidents: Data?
        public let audit: Data?

        public init(incidents: Data?, audit: Data?) {
            self.incidents = incidents
            self.audit = audit
        }
    }

    public enum StoreError: Error, LocalizedError {
        case invalidPaths, busy, invalidDocument, invalidJournal, recoveryConflict, recoveryRequired

        public var errorDescription: String? {
            switch self {
            case .invalidPaths: return "Incident and audit files must be distinct files in one directory."
            case .busy: return "The incident/audit transaction store is busy."
            case .invalidDocument: return "Incident and audit documents must be compatible JSON arrays without data loss."
            case .invalidJournal: return "The incident/audit transaction journal is invalid."
            case .recoveryConflict: return "Incident or audit history changed outside the transaction."
            case .recoveryRequired: return "Incident/audit transaction recovery is required before writing incident history."
            }
        }
    }

    enum Boundary: CaseIterable {
        case beforeJournalStaging, afterJournalStaging, afterJournalPublication, afterJournalDurable
        case afterIncidentStaging, afterIncidentPublication, afterIncidentDurable
        case afterAuditStaging, afterAuditPublication, afterAuditDurable
        case afterJournalRemoval, afterJournalRemovalDurable
    }

    enum Document {
        case incidents, audit
    }

    private struct Payload: Codable {
        let version: Int
        let incidentName: String
        let auditName: String
        let previousIncidents: Data?
        let previousAudit: Data?
        let incidents: Data
        let audit: Data
    }

    private struct Journal: Codable {
        let payload: Payload
        let checksum: Data
    }

    private static let lockName = ".incident-audit.transaction.lock"
    static let journalName = ".incident-audit.transaction.json"
    private static let temporaryPrefix = ".incident-audit.transaction.tmp."
    private let directory: URL
    private let incidentName: String
    private let auditName: String
    private let validateCompatibility: (Data, Document) throws -> Void
    private let fault: (Boundary) throws -> Void

    public convenience init(incidentURL: URL, auditURL: URL) throws {
        try self.init(incidentURL: incidentURL, auditURL: auditURL, fault: { _ in })
    }

    // The compatibility override is only for synthetic journal-mechanics tests.
    init(incidentURL: URL, auditURL: URL,
         validateCompatibility: ((Data, Document) throws -> Void)? = nil,
         fault: @escaping (Boundary) throws -> Void) throws {
        guard incidentURL.isFileURL, auditURL.isFileURL else { throw StoreError.invalidPaths }
        let incident = incidentURL.standardizedFileURL, audit = auditURL.standardizedFileURL
        let names = [incident.lastPathComponent, audit.lastPathComponent]
        let folded = names.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        let auditLock = Self.auditLockName(for: names[1]).precomposedStringWithCanonicalMapping.lowercased()
        guard incident.deletingLastPathComponent() == audit.deletingLastPathComponent(),
              folded[0] != folded[1],
              auditLock != folded[0], auditLock != folded[1],
              auditLock != Self.lockName, auditLock != Self.journalName,
              !auditLock.hasPrefix(Self.temporaryPrefix),
              folded.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." &&
                  $0 != Self.lockName && $0 != Self.journalName &&
                  !$0.hasPrefix(Self.temporaryPrefix) }) else { throw StoreError.invalidPaths }
        self.directory = incident.deletingLastPathComponent()
        self.incidentName = names[0]
        self.auditName = names[1]
        self.validateCompatibility = validateCompatibility ?? Self.validateCompatibility
        self.fault = fault
    }

    /// Reads only after recovering any published transaction. Missing files stay nil.
    /// Documents that cannot round-trip without losing fields or values are rejected.
    public func snapshot() throws -> Snapshot {
        try withLock { dir in
            try recover(dir)
            return try readSnapshot(dir)
        }
    }

    /// Runs under the shared lock. Return complete JSON arrays for both files.
    /// An error can mean the commit happened; call snapshot() to reconcile before retrying.
    @discardableResult
    public func update(_ transform: (Snapshot) throws -> Snapshot) throws -> Snapshot {
        try update(refusingPendingJournal: false, transform)
    }

    @discardableResult
    func update(refusingPendingJournal: Bool, _ transform: (Snapshot) throws -> Snapshot) throws -> Snapshot {
        try withLock { dir in
            if refusingPendingJournal {
                guard try read(Self.journalName, directory: dir) == nil else {
                    throw StoreError.recoveryRequired
                }
            } else {
                try recover(dir)
            }
            let before = try readSnapshot(dir)
            let after = try transform(before)
            guard let incidents = after.incidents, let audit = after.audit else {
                throw StoreError.invalidDocument
            }
            try validate(incidents, as: .incidents)
            try validate(audit, as: .audit)
            let payload = Payload(version: 1, incidentName: incidentName, auditName: auditName,
                                  previousIncidents: before.incidents, previousAudit: before.audit,
                                  incidents: incidents, audit: audit)
            let payloadData = try encode(payload)
            let journal = try encode(Journal(payload: payload, checksum: Data(SHA256.hash(data: payloadData))))
            try fault(.beforeJournalStaging)
            try publish(journal, as: Self.journalName, directory: dir,
                        staged: .afterJournalStaging, published: .afterJournalPublication,
                        durable: .afterJournalDurable)
            try apply(payload, directory: dir)
            return after
        }
    }

    @discardableResult
    private func recover(_ dir: Int32) throws -> Bool {
        guard let data = try read(Self.journalName, directory: dir) else { return false }
        let journal: Journal
        do {
            journal = try JSONDecoder().decode(Journal.self, from: data)
            guard journal.payload.version == 1, journal.payload.incidentName == incidentName,
                  journal.payload.auditName == auditName,
                  journal.checksum == Data(SHA256.hash(data: try encode(journal.payload))) else {
                throw StoreError.invalidJournal
            }
        } catch { throw StoreError.invalidJournal }
        if let previous = journal.payload.previousIncidents { try validate(previous, as: .incidents) }
        if let previous = journal.payload.previousAudit { try validate(previous, as: .audit) }
        try validate(journal.payload.incidents, as: .incidents)
        try validate(journal.payload.audit, as: .audit)
        let currentIncidents = try read(incidentName, directory: dir)
        let currentAudit = try read(auditName, directory: dir)
        guard (currentIncidents == journal.payload.previousIncidents || currentIncidents == journal.payload.incidents),
              (currentAudit == journal.payload.previousAudit || currentAudit == journal.payload.audit) else {
            throw StoreError.recoveryConflict
        }
        try apply(journal.payload, directory: dir)
        return true
    }

    func readAfterStartupRecovery<T>(_ read: (Data?) throws -> T) throws -> (value: T, recovered: Bool) {
        try withLock { dir in
            let recovered = try recover(dir)
            return (try read(try self.read(incidentName, directory: dir)), recovered)
        }
    }

    // A legacy incident write is not a transaction, but must never overwrite
    // a published journal or a snapshot changed by another cooperating writer.
    func writeLegacyIncidents(expected: Data?, proposed: Data, save: () throws -> Void) throws -> Data {
        try withLock { dir in
            guard try read(Self.journalName, directory: dir) == nil else {
                throw StoreError.recoveryRequired
            }
            let current = try read(incidentName, directory: dir)
            guard current == expected else { throw StoreError.recoveryConflict }
            if let current { try validate(current, as: .incidents) }
            try validate(proposed, as: .incidents)
            try save()
            let written = try read(incidentName, directory: dir)
            guard written == proposed else { throw StoreError.recoveryConflict }
            return proposed
        }
    }

    private func apply(_ payload: Payload, directory dir: Int32) throws {
        try publish(payload.incidents, as: incidentName, directory: dir,
                    staged: .afterIncidentStaging, published: .afterIncidentPublication,
                    durable: .afterIncidentDurable)
        try publish(payload.audit, as: auditName, directory: dir,
                    staged: .afterAuditStaging, published: .afterAuditPublication,
                    durable: .afterAuditDurable)
        guard unlinkat(dir, Self.journalName, 0) == 0 else { throw posixError() }
        try fault(.afterJournalRemoval)
        guard fsync(dir) == 0 else { throw posixError() }
        try fault(.afterJournalRemovalDurable)
    }

    private func readSnapshot(_ dir: Int32) throws -> Snapshot {
        let incidents = try read(incidentName, directory: dir)
        let audit = try read(auditName, directory: dir)
        if let incidents { try validate(incidents, as: .incidents) }
        if let audit { try validate(audit, as: .audit) }
        return Snapshot(incidents: incidents, audit: audit)
    }

    private func validate(_ data: Data, as document: Document) throws {
        guard (try? JSONSerialization.jsonObject(with: data)) is [Any] else {
            throw StoreError.invalidDocument
        }
        try validateCompatibility(data, document)
    }

    static func validateCompatibility(_ data: Data, _ document: Document) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded: Data
        do {
            switch document {
            case .incidents:
                encoded = try encoder.encode(decoder.decode([SafetyIncident].self, from: data))
            case .audit:
                let entries = try decoder.decode([OperatorAuditEntry].self, from: data)
                if data.count > 4_000_000 {
                    let valid = try data.withUnsafeBytes { bytes in
                        var scanner = LargeAuditCompatibilityScanner(bytes)
                        return try scanner.preservesFields(entries)
                    }
                    guard valid else { throw StoreError.invalidDocument }
                    return
                }
                encoded = try encoder.encode(entries)
            }
        } catch { throw StoreError.invalidDocument }
        guard CameraConfigurationRoundTrip.preservesFields(original: data, encoded: encoded) else {
            throw StoreError.invalidDocument
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func withLock<T>(_ body: (Int32) throws -> T) throws -> T {
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw posixError() }
        defer { close(dir) }
        // Audit-only operations take the same first lock; transactions then take the journal lock.
        let auditFD = try Self.openCoordinationLock(directory: dir, name: Self.auditLockName(for: auditName))
        defer { close(auditFD) }
        guard flock(auditFD, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw StoreError.busy }
            throw posixError()
        }
        defer { flock(auditFD, LOCK_UN) }
        try Self.verifyCoordinationLock(directory: dir, name: Self.auditLockName(for: auditName), fd: auditFD)
        let transactionFD = try Self.openCoordinationLock(directory: dir, name: Self.lockName)
        defer { close(transactionFD) }
        guard flock(transactionFD, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw StoreError.busy }
            throw posixError()
        }
        defer { flock(transactionFD, LOCK_UN) }
        try Self.verifyCoordinationLock(directory: dir, name: Self.auditLockName(for: auditName), fd: auditFD)
        try Self.verifyCoordinationLock(directory: dir, name: Self.lockName, fd: transactionFD)
        return try body(dir)
    }

    static func auditLockName(for auditName: String) -> String {
        ".\(auditName).lock"
    }

    static func openCoordinationLock(directory: Int32, name: String) throws -> Int32 {
        let fd = openat(directory, name, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(fd)
            throw error
        }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1 else {
            close(fd)
            throw POSIXError(.EINVAL)
        }
        return fd
    }

    static func verifyCoordinationLock(directory: Int32, name: String, fd: Int32) throws {
        var opened = stat(), named = stat()
        guard fstat(fd, &opened) == 0, fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard opened.st_mode & S_IFMT == S_IFREG, named.st_mode & S_IFMT == S_IFREG,
              opened.st_nlink == 1, named.st_nlink == 1,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
            throw POSIXError(.EINVAL)
        }
    }

    private func read(_ name: String, directory: Int32) throws -> Data? {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw posixError() }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw StoreError.invalidDocument }
        return try handle.readToEnd() ?? Data()
    }

    private func publish(_ data: Data, as name: String, directory: Int32,
                         staged: Boundary, published: Boundary, durable: Boundary) throws {
        let temp = Self.temporaryPrefix + UUID().uuidString
        let fd = openat(directory, temp, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw posixError() }
        var renamed = false
        defer {
            close(fd)
            if !renamed { _ = unlinkat(directory, temp, 0) }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw posixError() }
        try fault(staged)
        guard renameat(directory, temp, directory, name) == 0 else { throw posixError() }
        renamed = true
        try fault(published)
        guard fsync(directory) == 0 else { throw posixError() }
        try fault(durable)
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// Audit records contain only string-valued fields. Validate each original key
/// and value without building a second copy of the complete encoded history.
private struct LargeAuditCompatibilityScanner {
    private let bytes: UnsafeRawBufferPointer
    private var position = 0

    init(_ bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { position = 3 }
    }

    mutating func preservesFields(_ entries: [OperatorAuditEntry]) throws -> Bool {
        whitespace()
        guard consume(91) else { return false }
        whitespace()
        if entries.isEmpty {
            guard consume(93) else { return false }
        } else {
            for (index, entry) in entries.enumerated() {
                if index > 0 {
                    whitespace()
                    guard consume(44) else { return false }
                }
                guard try record(entry) else { return false }
            }
            whitespace()
            guard consume(93) else { return false }
        }
        whitespace()
        return position == bytes.count
    }

    private mutating func record(_ entry: OperatorAuditEntry) throws -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let date = try JSONDecoder().decode(String.self, from: encoder.encode(entry.occurredAt))
        var expected = [
            "id": entry.id.uuidString,
            "occurredAt": date,
            "action": entry.action.rawValue,
            "summary": entry.summary,
            "details": entry.details
        ]
        if let id = entry.incidentID { expected["incidentID"] = id.uuidString }
        if let id = entry.cameraID { expected["cameraID"] = id.uuidString }
        whitespace()
        guard consume(123) else { return false }
        whitespace()
        if consume(125) { return true }
        var seen = Set<String>()
        while true {
            whitespace()
            let key = try string()
            guard seen.insert(key).inserted, let value = expected[key] else { return false }
            whitespace()
            guard consume(58) else { return false }
            whitespace()
            let original = try string()
            guard original.utf8.elementsEqual(value.utf8) else { return false }
            whitespace()
            if consume(125) { return true }
            guard consume(44) else { return false }
        }
    }

    private mutating func string() throws -> String {
        guard position < bytes.count, bytes[position] == 34 else {
            throw IncidentAuditTransactionStore.StoreError.invalidDocument
        }
        let start = position
        position += 1
        while position < bytes.count {
            let byte = bytes[position]
            position += 1
            if byte == 34 {
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<position]))
            }
            guard byte >= 32 else { throw IncidentAuditTransactionStore.StoreError.invalidDocument }
            if byte == 92 {
                guard position < bytes.count else { throw IncidentAuditTransactionStore.StoreError.invalidDocument }
                position += 1
            }
        }
        throw IncidentAuditTransactionStore.StoreError.invalidDocument
    }

    private mutating func whitespace() {
        while position < bytes.count, [9, 10, 13, 32].contains(bytes[position]) { position += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard position < bytes.count, bytes[position] == byte else { return false }
        position += 1
        return true
    }
}
