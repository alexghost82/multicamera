import CameraCore
import CryptoKit
import Foundation

enum ACTAReviewedFileKind: String, Sendable {
    case diagnostics, missionPDF, cameraFrame

    var actionID: String {
        switch self {
        case .diagnostics: "settings.export_diagnostics"
        case .missionPDF: "mission.export_pdf"
        case .cameraFrame: "camera.snapshot"
        }
    }

    var fileExtension: String {
        switch self {
        case .diagnostics: "json"
        case .missionPDF: "pdf"
        case .cameraFrame: "jpg"
        }
    }
}

struct ACTAReviewedFileSelection: Sendable {
    let kind: ACTAReviewedFileKind
    let bytes: Data
    let destination: URL
}

protocol ACTAReviewedFileSelector: Sendable {
    func selectAndReview() async throws -> ACTAReviewedFileSelection
}

/// Selection is trusted UI only. Model arguments never contain source bytes or a path.
actor ACTAReviewedFileExportAction: ACTAPreparedConfirmationAction {
    final class Ticket: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func consume() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !used else { return false }
            used = true
            return true
        }
    }

    struct Snapshot: Sendable {
        fileprivate let selection: ACTAReviewedFileSelection
        fileprivate let threadID: String
        fileprivate let issuedAt: TimeInterval
        fileprivate let owner: UUID
        fileprivate let ticket: Ticket
    }

    nonisolated let id: String
    nonisolated let title: String
    nonisolated let description = "The operator selects the destination and reviews the complete frozen content locally."
    nonisolated let classification = ACTAActionClassification.serviceAffecting
    nonisolated let parameters: [ACTAActionParameterSchema] = []
    private let kind: ACTAReviewedFileKind
    private let selector: any ACTAReviewedFileSelector
    private let now: @Sendable () -> TimeInterval
    private let owner = UUID()
    private var busy = false
    private var receipt: Snapshot?

    init(kind: ACTAReviewedFileKind, selector: any ACTAReviewedFileSelector,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.kind = kind
        self.id = kind.actionID
        switch kind {
        case .diagnostics: self.title = "Export diagnostics"
        case .missionPDF: self.title = "Export mission PDF"
        case .cameraFrame: self.title = "Export camera frame"
        }
        self.selector = selector
        self.now = now
    }

    nonisolated func requiresConfirmation(parameters: [String: String]) -> Bool { true }
    nonisolated func validate(parameters: [String: String]) throws {
        guard parameters.isEmpty else { throw Failure.invalidSelection }
    }

    func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws
        -> ACTAPreparedConfirmation<Snapshot> {
        try validate(parameters: parameters)
        try Task.checkCancellation()
        let selected = try await selector.selectAndReview()
        try Task.checkCancellation()
        let bytes = Data([UInt8](selected.bytes))
        let path = selected.destination.path
        guard selected.kind == kind, !bytes.isEmpty, bytes.count <= 1024 * 1024,
              selected.destination.isFileURL, path.hasPrefix("/"), path.utf8.count <= 4096,
              path.lowercased().hasSuffix("." + kind.fileExtension)
                || (kind == .cameraFrame && path.lowercased().hasSuffix(".jpeg")) else {
            throw Failure.invalidSelection
        }
        let instant = now()
        guard instant.isFinite, instant >= 0 else { throw Failure.invalidSelection }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let escapedPath = String(decoding: try encoder.encode(path), as: UTF8.self)
        let selection = ACTAReviewedFileSelection(kind: kind, bytes: bytes, destination: selected.destination)
        let subject = kind == .cameraFrame ? "Camera frame" : kind.rawValue
        return .init(snapshot: Snapshot(selection: selection, threadID: context.threadID,
                                        issuedAt: instant, owner: owner, ticket: Ticket()),
                     reviewSummary: "\(subject), destination=\(escapedPath), bytes=\(bytes.count), sha256=\(digest). Full content reviewed locally. Create only; no replacement.")
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        try validate(parameters: parameters)
        return .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Local review is required.")
    }

    func executeConfirmed(parameters: [String: String], context: ACTAActionContext,
                          snapshot: Snapshot) async throws -> ACTAActionResult {
        guard snapshot.owner == owner, snapshot.ticket.consume() else {
            return .failed(actionID: id, error: "CONFIRMATION_CONSUMED: Review already used.")
        }
        guard parameters.isEmpty, context.isConfirmed, context.threadID == snapshot.threadID else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Request changed.")
        }
        let instant = now()
        guard instant.isFinite, instant >= snapshot.issuedAt, instant - snapshot.issuedAt < 300 else {
            return .failed(actionID: id, error: "REVIEW_EXPIRED: Review again.")
        }
        guard !busy else { return .failed(actionID: id, error: "ACTION_BUSY: Publication is in progress.") }
        busy = true
        do {
            try Task.checkCancellation()
            try ACTACreateOnlyExport.publish(snapshot.selection.bytes, to: snapshot.selection.destination)
            try Task.checkCancellation()
            guard try ACTACreateOnlyExport.verify(snapshot.selection.bytes, at: snapshot.selection.destination) else {
                busy = false
                return .failed(actionID: id, error: "VERIFICATION_FAILED: Check the destination before retrying.")
            }
            receipt = snapshot
            return ACTAActionResult(actionID: id, success: true, summary: "Reviewed file created and verified.")
        } catch {
            busy = false
            return .failed(actionID: id, error: "PUBLICATION_FAILED: Outcome may be unknown; check the destination before retrying.")
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        guard parameters.isEmpty, context.isConfirmed, let saved = receipt,
              saved.threadID == context.threadID else { return false }
        receipt = nil
        defer { busy = false }
        return try ACTACreateOnlyExport.verify(saved.selection.bytes, at: saved.selection.destination)
    }

    private enum Failure: Error { case invalidSelection }
}
