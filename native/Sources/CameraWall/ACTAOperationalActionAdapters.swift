import CameraCore
import Foundation

/// Shares GUI domain methods. Each mutation verifies persisted state before returning success.
struct WallOperationalAction: ACTAActionProtocol {
    let specification: any ACTAActionProtocol
    unowned let model: WallModel
    var id: String { specification.id }
    var title: String { specification.title }
    var description: String { specification.description }
    var classification: ACTAActionClassification { specification.classification }
    var parameters: [ACTAActionParameterSchema] { specification.parameters }
    func requiresConfirmation(parameters: [String: String]) -> Bool {
        specification.requiresConfirmation(parameters: parameters)
    }
    func validate(parameters: [String: String]) throws { try specification.validate(parameters: parameters) }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        try await MainActor.run {
            func uuid(_ name: String) throws -> UUID {
                guard let value = parameters[name], let id = UUID(uuidString: value) else {
                    throw ConfigurationError.invalid("INVALID_ARGUMENT: \(name) must be a UUID.")
                }
                return id
            }
            func encoded<T: Encodable>(_ value: T) throws -> String {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                return String(decoding: try encoder.encode(value), as: UTF8.self)
            }
            func success(_ summary: String, _ json: String = "{}") -> ACTAActionResult {
                ACTAActionResult(actionID: id, success: true, summary: summary, outputJSON: json, verified: true)
            }
            let engine = model.localAnalyticsEngine
            switch id {
            case "incident.list":
                if let error = engine.persistenceError { throw ConfigurationError.invalid(error) }
                var incidents = engine.incidentManager.allIncidents()
                if parameters["camera_id"] != nil {
                    let cameraID = try uuid("camera_id")
                    incidents = incidents.filter { $0.cameraID == cameraID }
                }
                if parameters["open_only"] == "true" { incidents = incidents.filter { $0.status.isOpen } }
                let limit = Int(parameters["limit"] ?? "50") ?? 50
                guard (1...100).contains(limit) else { throw ConfigurationError.invalid("Limit must be 1...100.") }
                return success("Listed recorded safety incidents.", "{\"incidents\":\(try encoded(Array(incidents.prefix(limit))))}")

            case "incident.delete_evidence":
                try engine.deleteIncidentEvidenceChecked(uuid("incident_id"))
                return success("Evidence directory and incident references deleted and verified.", "{\"deleted\":true}")

            case "incident.transition_status":
                let incidentID = try uuid("incident_id")
                guard engine.incidentManager.incident(id: incidentID) != nil,
                      let status = SafetyIncidentStatus(rawValue: (parameters["status"] ?? "").uppercased()) else {
                    throw ConfigurationError.invalid("Incident or status does not exist.")
                }
                if let error = engine.persistenceError { throw ConfigurationError.invalid(error) }
                engine.transitionIncident(incidentID, to: status, note: parameters["note"])
                if let error = engine.persistenceError { throw ConfigurationError.invalid(error) }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let saved = try decoder.decode([SafetyIncident].self,
                    from: Data(contentsOf: engine.incidentManager.storageURL))
                guard let persisted = saved.first(where: { $0.id == incidentID }), persisted.status == status,
                      engine.incidentManager.incident(id: incidentID)?.status == status else {
                    throw ConfigurationError.invalid("Incident status persistence verification failed.")
                }
                if let note = parameters["note"], !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   persisted.operatorNotes != note.trimmingCharacters(in: .whitespacesAndNewlines) {
                    throw ConfigurationError.invalid("Incident note persistence verification failed.")
                }
                return success("Incident status saved and verified.", "{\"incident\":\(try encoded(persisted))}")

            case "watch.list", "watch.create", "watch.cancel":
                guard model.featurePreferences.enabledFeatures.contains(.operationalAlerts) else {
                    throw CameraFeatureStoreError.featureDisabled(.operationalAlerts)
                }
                let current = try OperationsWatchStore.load(from: model.operationsWatchURL)
                if id == "watch.list" {
                    return success("Listed active watch rules.", "{\"watch_rules\":\(try encoded(current))}")
                }
                if id == "watch.cancel" {
                    let watchID = try uuid("watch_id")
                    guard current.contains(where: { $0.id == watchID }) else {
                        throw ConfigurationError.invalid("Watch rule does not exist.")
                    }
                    try model.cancelOperationsWatch(watchID)
                    guard try !OperationsWatchStore.load(from: model.operationsWatchURL).contains(where: { $0.id == watchID }),
                          !model.operationsWatchRules.contains(where: { $0.id == watchID }) else {
                        throw ConfigurationError.invalid("Watch cancellation verification failed.")
                    }
                    return success("Watch rule cancelled and verified.")
                }
                let rawIDs = (parameters["camera_ids"] ?? "").split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let cameraIDs = try Set(rawIDs.map { value -> UUID in
                    guard let cameraID = UUID(uuidString: value), model.config.cameras.contains(where: { $0.id == cameraID }) else {
                        throw ConfigurationError.invalid("Watch camera does not exist; specify a configured camera UUID.")
                    }
                    return cameraID
                })
                let ttl = parameters["ttl_minutes"].flatMap(Int.init)
                guard ttl.map({ (1...43200).contains($0) }) ?? true,
                      !(parameters["forever"] == "true" && ttl != nil) else {
                    throw ConfigurationError.invalid("Specify a TTL of 1...43200 minutes or forever, not both.")
                }
                let createdID = try model.addOperationsWatch(text: parameters["text"] ?? "", cameraIDs: cameraIDs,
                    ttlMinutes: ttl, forever: parameters["forever"] == "true")
                let saved = try OperationsWatchStore.load(from: model.operationsWatchURL)
                guard let persisted = saved.first(where: { $0.id == createdID }),
                      model.operationsWatchRules.contains(persisted), persisted.cameraIDs == cameraIDs else {
                    throw ConfigurationError.invalid("Watch creation persistence verification failed.")
                }
                return success("Watch rule saved and verified.", "{\"watch_id\":\(try encoded(createdID.uuidString)),\"watch\":\(try encoded(persisted))}")

            case "memory.delete_frame":
                try model.deleteCameraMemoryFrameChecked(uuid("frame_id"))
                return success("Memory frame index and physical deletion verified.", "{\"deleted\":true}")
            default:
                return .unsupported(actionID: id)
            }
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        // Verification is performed within the MainActor execution above, without a suspension
        // between the domain mutation and its disk/runtime read-back.
        true
    }
}

/// AI-authored operator annotations require human review before operator_marked is set.
struct WallNarrativeAction: ACTAActionProtocol {
    let pin: Bool
    unowned let model: WallModel
    var id: String { pin ? "memory.toggle_pin" : "memory.set_chapter_text" }
    var title: String { id }
    var description: String { pin ? "Set (not invert) the pinned state of a saved chapter after operator review." : "Save or explicitly clear operator text after review, preserving the original AI summary. Use clear=true without text to clear." }
    let classification = ACTAActionClassification.reversible
    var parameters: [ACTAActionParameterSchema] {
        let chapter = ACTAActionParameterSchema(name: "chapter_id", type: "string", description: "Saved narrative chapter ID", isRequired: true)
        if pin { return [chapter, ACTAActionParameterSchema(name: "pinned", type: "boolean", description: "Desired pinned state", isRequired: true)] }
        return [chapter, ACTAActionParameterSchema(name: "text", type: "string", description: "Operator annotation, at most 16000 characters"),
            ACTAActionParameterSchema(name: "clear", type: "boolean", description: "Explicitly clear the existing operator annotation")]
    }
    func requiresConfirmation(parameters: [String: String]) -> Bool { true }
    func validate(parameters: [String: String]) throws {
        if !pin {
            guard (parameters["clear"] == "true") != (parameters["text"] != nil),
                  (parameters["text"]?.count ?? 0) <= 16000 else {
                throw ConfigurationError.invalid("Specify text (at most 16000 characters) or clear=true, not both.")
            }
        }
    }
    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        try await MainActor.run {
            try Task.checkCancellation()
            let chapterID = parameters["chapter_id"] ?? ""
            let saved: ACTANarrativeChapterRecord
            if pin {
                saved = try model.setACTANarrativePinChecked(chapterID: chapterID, pinned: parameters["pinned"] == "true")
            } else {
                try validate(parameters: parameters)
                saved = try model.setACTANarrativeTextChecked(chapterID: chapterID, text: parameters["text"])
            }
            return ACTAActionResult(actionID: id, success: true, summary: "Reviewed narrative change saved and verified.",
                outputJSON: String(decoding: try JSONEncoder().encode(saved), as: UTF8.self))
        }
    }
    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool { true }
}
