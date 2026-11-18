import CryptoKit
import Foundation

/// This contract is for a trusted local UI and publication backend, not model input.
/// A production implementation must bind the displayed destination, directory
/// identity, name, and bytes to its opaque token, and keep the directory namespace
/// and contents isolated from concurrent writers through publication and verification.
protocol ACTAReportExportBackend: Sendable {
    func selectReportAndDestination() async throws -> ACTAReportExportSelection
    func publish(_ selection: ACTAReportExportSelection) async throws
    func verify(_ selection: ACTAReportExportSelection) async throws -> Bool
}

struct ACTAReportExportSelection: Sendable {
    let token: UUID
    let reportKind: String
    let destination: String
    let directoryDevice: UInt64
    let directoryInode: UInt64
    let fileName: String
    let html: Data
}

/// Broker-ready foundation only. It is intentionally not registered in production:
/// ACTAReportHTMLPublisher alone cannot establish the backend's isolation contract.
actor ACTAReportExportAction: ACTAPreparedConfirmationAction {
    nonisolated let id = "monitor.export_report_html"
    nonisolated let title = "Export HTML report"
    nonisolated let description = "The operator selects the report and destination locally; review is required."
    nonisolated let classification = ACTAActionClassification.serviceAffecting
    nonisolated let parameters: [ACTAActionParameterSchema] = []

    struct Snapshot: Sendable {
        let selection: ACTAReportExportSelection
        let digest: String
        let threadID: String
    }

    private let backend: any ACTAReportExportBackend
    private var lastVerified: Snapshot?
    private var publicationInProgress = false

    init(backend: any ACTAReportExportBackend) { self.backend = backend }

    nonisolated func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    nonisolated func validate(parameters: [String: String]) throws {
        guard parameters.isEmpty else { throw Failure.invalidSelection }
    }

    func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws
        -> ACTAPreparedConfirmation<Snapshot> {
        try validate(parameters: parameters)
        try Task.checkCancellation()
        let selected = try await backend.selectReportAndDestination()
        try Task.checkCancellation()
        let html = Data([UInt8](selected.html))
        guard !html.isEmpty, html.count <= 8 * 1024 * 1024,
              String(data: html, encoding: .utf8) != nil,
              ["mission", "operations"].contains(selected.reportKind),
              selected.destination.hasPrefix("/"), selected.destination.utf8.count <= 4096,
              selected.directoryInode != 0,
              Self.validFileName(selected.fileName) else { throw Failure.invalidSelection }
        let selection = ACTAReportExportSelection(
            token: selected.token, reportKind: selected.reportKind, destination: selected.destination,
            directoryDevice: selected.directoryDevice, directoryInode: selected.directoryInode,
            fileName: selected.fileName, html: html)
        let digest = Self.digest(html)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let path = String(decoding: try encoder.encode(selection.destination), as: UTF8.self)
        let name = String(decoding: try encoder.encode(selection.fileName), as: UTF8.self)
        let summary = "Report=\(selection.reportKind), destination=\(path), filename=\(name), "
            + "directory_device=\(selection.directoryDevice), directory_inode=\(selection.directoryInode), "
            + "bytes=\(html.count), sha256=\(digest). Create one private HTML file; no overwrite. "
            + "A failed write may leave an incomplete file; do not retry without checking."
        return ACTAPreparedConfirmation(
            snapshot: Snapshot(selection: selection, digest: digest, threadID: context.threadID),
            reviewSummary: summary)
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        try validate(parameters: parameters)
        return .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Local operator review is required.")
    }

    func executeConfirmed(parameters: [String: String], context: ACTAActionContext,
                          snapshot: Snapshot) async throws -> ACTAActionResult {
        try validate(parameters: parameters)
        guard context.isConfirmed, context.threadID == snapshot.threadID,
              Self.digest(snapshot.selection.html) == snapshot.digest else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Reviewed report does not match.")
        }
        guard !publicationInProgress else {
            return .failed(actionID: id, error: "ACTION_BUSY: A report publication is awaiting verification.")
        }
        publicationInProgress = true
        do {
            try Task.checkCancellation()
            try await backend.publish(snapshot.selection)
            try Task.checkCancellation()
            guard try await backend.verify(snapshot.selection) else {
                publicationInProgress = false
                return .failed(actionID: id, error: "VERIFICATION_FAILED: Reconcile the destination before retrying.")
            }
            lastVerified = snapshot
            return ACTAActionResult(actionID: id, success: true, summary: "Reviewed HTML report saved and verified.")
        } catch {
            publicationInProgress = false
            return .failed(actionID: id, error: "PUBLICATION_FAILED: Publication may be incomplete; reconcile before retrying.")
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        try validate(parameters: parameters)
        guard context.isConfirmed, let snapshot = lastVerified, snapshot.threadID == context.threadID else { return false }
        lastVerified = nil
        defer { publicationInProgress = false }
        return try await backend.verify(snapshot.selection)
    }

    private enum Failure: Error { case invalidSelection }

    private nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func validFileName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        return !bytes.isEmpty && bytes.count <= 255 && name.lowercased().hasSuffix(".html")
            && bytes.allSatisfy { (32...126).contains($0) && $0 != 47 && $0 != 92 }
    }
}
