import Foundation

public struct ACTAEvidenceReference: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var recordID: String
    public var kind: String
    public var sourceTool: String
    public var cameraID: String?
    public var cameraName: String?
    public var occurredAt: String?
}

/// Construct provenance from structured tool results, never from model-supplied citations
/// or from JSON-like strings embedded in OCR/descriptions.
public struct AgentEvidenceLedger: Sendable {
    public private(set) var references: [ACTAEvidenceReference] = []
    public init() {}

    public mutating func record(outputJSON: String, tool: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(outputJSON.utf8)) else { return }
        walk(object, tool: tool)
    }

    private mutating func walk(_ value: Any, tool: String) {
        if let rows = value as? [Any] {
            for row in rows { walk(row, tool: tool) }
        } else if let row = value as? [String: Any] {
            let keys = ["frame_id", "clip_id", "chapter_id", "track_id", "event_id", "alert_id", "run_id", "mission_id", "identity_id"]
            if let key = keys.first(where: { row[$0] is String }), let recordID = row[key] as? String, !recordID.isEmpty {
                let kind = row["type"] as? String ?? String(key.dropLast(3))
                let id = "\(tool):\(kind):\(recordID)"
                if !references.contains(where: { $0.id == id }), references.count < 200 {
                    references.append(ACTAEvidenceReference(id: id, recordID: recordID, kind: kind, sourceTool: tool,
                        cameraID: row["camera_id"] as? String, cameraName: row["camera_name"] as? String,
                        occurredAt: (row["captured_at"] ?? row["at"] ?? row["started_at"] ?? row["created_at"] ?? row["occurred_at"]) as? String))
                }
            }
            for child in row.values where child is [Any] || child is [String: Any] { walk(child, tool: tool) }
        }
    }

    public func catalogueJSON() -> String {
        (try? JSONEncoder().encode(references)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    public func validated(_ answer: ACTAChatPresentAnswer) -> ACTAChatPresentAnswer {
        var result = answer
        let known = Set(references.map(\.id))
        result.citedRecordIDs = Array(Set(answer.citedRecordIDs).intersection(known)).sorted()
        result.evidenceReferences = references.filter { result.citedRecordIDs.contains($0.id) }
        return result
    }
}
