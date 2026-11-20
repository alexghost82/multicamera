import CameraCore
import CryptoKit
import Foundation

/// Trusted UI returns only after showing the exact frozen bytes and the
/// operator-selected destination. Neither value comes from model arguments.
struct ACTAReviewedHTMLSelection: Sendable {
    let kind: String
    let bytes: Data
    let destination: URL
}

protocol ACTAReviewedHTMLSelectionProvider: Sendable {
    func selectAndReview() async throws -> ACTAReviewedHTMLSelection
}

/// The trusted host authorizes the frozen source and confirmation. Publication
/// must not replace a name and must verify the exact bytes. The selected
/// namespace must not be concurrently modified by untrusted processes.
protocol ACTAReviewedHTMLPublication: Sendable {
    func publish(_ selection: ACTAReviewedHTMLSelection, threadID: String) async throws
    func verify(_ selection: ACTAReviewedHTMLSelection, threadID: String) async throws -> Bool
}

actor ACTAReviewedHTMLExportAction: ACTAPreparedConfirmationAction {
    fileprivate final class Ticket: @unchecked Sendable {
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
        fileprivate let selection: ACTAReviewedHTMLSelection
        fileprivate let threadID: String
        fileprivate let issuedAt: TimeInterval
        fileprivate let ticket: Ticket
        fileprivate let owner: UUID
    }

    nonisolated let id = "monitor.export_report_html"
    nonisolated let title = "Export reviewed HTML report"
    nonisolated let description = "Export a frozen HTML report snapshot. The operator selects and reviews its full contents and destination locally; the file is never replaced."
    nonisolated let classification = ACTAActionClassification.serviceAffecting
    nonisolated let parameters: [ACTAActionParameterSchema] = []

    private let selector: any ACTAReviewedHTMLSelectionProvider
    private let publisher: any ACTAReviewedHTMLPublication
    private let now: @Sendable () -> TimeInterval
    private let owner = UUID()
    private var busy = false
    private var receipt: Snapshot?

    init(selector: any ACTAReviewedHTMLSelectionProvider, publisher: any ACTAReviewedHTMLPublication,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.selector = selector
        self.publisher = publisher
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
        guard ["mission", "operations"].contains(selected.kind),
              !bytes.isEmpty, bytes.count <= 1024 * 1024,
              let text = String(data: bytes, encoding: .utf8), Data(text.utf8) == bytes,
              selected.destination.isFileURL, path.hasPrefix("/"),
              path.utf8.count <= 4096, path.lowercased().hasSuffix(".html") else {
            throw Failure.invalidSelection
        }
        let instant = now()
        guard instant.isFinite, instant >= 0 else { throw Failure.invalidSelection }
        let selection = ACTAReviewedHTMLSelection(kind: selected.kind, bytes: bytes, destination: selected.destination)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let escapedPath = String(decoding: try encoder.encode(path), as: UTF8.self)
        return ACTAPreparedConfirmation(
            snapshot: Snapshot(selection: selection, threadID: context.threadID, issuedAt: instant,
                               ticket: Ticket(), owner: owner),
            reviewSummary: "HTML report=\(selection.kind), destination=\(escapedPath), bytes=\(bytes.count), sha256=\(digest). The full content was reviewed locally. Create only; no replacement.")
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        try validate(parameters: parameters)
        return .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepared operator review is required.")
    }

    func executeConfirmed(parameters: [String: String], context: ACTAActionContext,
                          snapshot: Snapshot) async throws -> ACTAActionResult {
        guard snapshot.owner == owner, snapshot.ticket.consume() else {
            return .failed(actionID: id, error: "CONFIRMATION_CONSUMED: Invalid or previously used review.")
        }
        guard parameters.isEmpty, context.isConfirmed, context.threadID == snapshot.threadID else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Request or thread changed.")
        }
        let instant = now()
        guard instant.isFinite, instant >= snapshot.issuedAt, instant - snapshot.issuedAt < 300 else {
            return .failed(actionID: id, error: "REVIEW_EXPIRED: Review the report again.")
        }
        guard !busy else { return .failed(actionID: id, error: "ACTION_BUSY: Publication is in progress.") }
        busy = true
        do {
            try Task.checkCancellation()
            try await publisher.publish(snapshot.selection, threadID: snapshot.threadID)
            try Task.checkCancellation()
            guard try await publisher.verify(snapshot.selection, threadID: snapshot.threadID) else {
                busy = false
                return .failed(actionID: id, error: "VERIFICATION_FAILED: Reconcile the destination before retrying.")
            }
            receipt = snapshot
            return ACTAActionResult(actionID: id, success: true, summary: "Reviewed HTML publication verified.")
        } catch {
            busy = false
            return .failed(actionID: id, error: "PUBLICATION_FAILED: Outcome may be unknown; reconcile before retrying.")
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        guard parameters.isEmpty, context.isConfirmed, let saved = receipt,
              saved.threadID == context.threadID else { return false }
        receipt = nil
        defer { busy = false }
        return try await publisher.verify(saved.selection, threadID: saved.threadID)
    }

    private enum Failure: Error { case invalidSelection }
}
