import Foundation
import CameraCore

/// Remove duplicate UUID catalogues and irrelevant tool payloads while retaining source provenance.
enum UnifiedAgentPromptEvidence {
    static func compact(blocks: [String], ledger: AgentEvidenceLedger) -> String {
        let references = ledger.references
        var sourceRows: [[String: Any]] = []
        var seen = Set<String>()
        let identifiers = ["scan_id", "stat_id", "incident_id", "watch_id", "frame_id", "clip_id", "chapter_id", "track_id", "event_id", "alert_id", "run_id", "mission_id", "identity_id"]
        let fields: Set<String> = ["summary", "description_summary", "answer", "label", "first_seen", "last_seen", "observed_at", "captured_at", "created_at", "at", "incident_type", "condition", "evidence", "title", "status", "operator_note", "verification", "explanation", "record_count", "camera_count", "first_record", "last_record", "frame_count", "sighting_count", "identity_count", "ai_summary", "operator_text", "tactical_headline", "precursor_summary", "mission_name", "event_type", "event_state", "description", "image_index", "visual_hit", "attributes", "vehicle_ocr", "operator_group_id"]
        func walk(_ value: Any) {
            if let list = value as? [Any] { list.forEach(walk); return }
            guard let row = value as? [String: Any] else { return }
            if let key = identifiers.first(where: { row[$0] is String }), let id = row[key] as? String,
               let index = references.firstIndex(where: { $0.recordID == id }), seen.insert(id).inserted {
                let ref = references[index]
                var compact: [String: Any] = ["cite": "S\(index + 1)", "kind": ref.kind]
                if let name = ref.cameraName ?? ref.cameraID { compact["camera"] = name }
                else if ref.kind == "stat" { compact["scope"] = "all cameras" }
                if let at = ref.occurredAt { compact["at"] = at }
                if let kind = row["kind"] { compact["record_kind"] = kind }
                for field in fields {
                    if let text = row[field] as? String { compact[field] = String(text.prefix(500)) }
                    else if let value = row[field] { compact[field] = value }
                }
                if let cameras = row["cameras"] as? [[String: Any]] {
                    compact["attached_live_images"] = cameras.map { ["image_index": $0["image_index"] ?? 0, "camera": $0["camera_name"] ?? ""] }
                }
                sourceRows.append(compact)
            }
            for (key, child) in row where !["attributes", "facets", "parameters", "description"].contains(key) && (child is [Any] || child is [String: Any]) { walk(child) }
        }
        for block in blocks { if let object = try? JSONSerialization.jsonObject(with: Data(block.utf8)) { walk(object) } }
        let result: [String: Any] = ["sources": sourceRows, "limits": "Detail records are samples. Statistics count saved records, not unique people or all physical events. No continuous video coverage is asserted. Use first_record and last_record for the actual retained date range."]
        return (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
