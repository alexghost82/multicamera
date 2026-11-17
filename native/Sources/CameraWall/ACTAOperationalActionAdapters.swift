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

    @MainActor
    static func listIncidents(parameters: [String: String], manager: UnifiedIncidentManager,
                              persistenceError: String?,
                              localizeTitle: (String) -> String) throws -> [SafetyIncident] {
        if let error = persistenceError { throw ConfigurationError.invalid(error) }
        var incidents = manager.allIncidents()
        if let value = parameters["camera_id"] {
            guard let cameraID = UUID(uuidString: value) else {
                throw ConfigurationError.invalid("INVALID_ARGUMENT: camera_id must be a UUID.")
            }
            incidents = incidents.filter { $0.cameraID == cameraID }
        }
        if parameters["open_only"] == "true" { incidents = incidents.filter { $0.status.isOpen } }
        if let query = parameters["query"], !query.isEmpty {
            incidents = incidents.filter {
                [$0.cameraName, localizeTitle($0.title), $0.explanation, $0.operatorNotes]
                    .contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }
        let limit = Int(parameters["limit"] ?? "50") ?? 50
        guard (1...100).contains(limit) else { throw ConfigurationError.invalid("Limit must be 1...100.") }
        return Array(incidents.prefix(limit))
    }

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
                let language = parameters["query"].flatMap { $0.isEmpty ? nil : AppLanguage.current }
                let incidents = try Self.listIncidents(parameters: parameters, manager: engine.incidentManager,
                                                       persistenceError: engine.persistenceError,
                                                       localizeTitle: { language?.localizedMessage($0) ?? $0 })
                return success("Listed recorded safety incidents.", "{\"incidents\":\(try encoded(incidents))}")

            case "incident.delete_evidence":
                try engine.deleteIncidentEvidenceChecked(uuid("incident_id"))
                return success("Evidence directory and incident references deleted and verified.", "{\"deleted\":true}")

            case "incident.update_note":
                try specification.validate(parameters: parameters)
                guard context.isConfirmed else {
                    throw ConfigurationError.invalid("Operator confirmation is required.")
                }
                try Task.checkCancellation()
                let incidentID = try uuid("incident_id")
                guard let rawNote = parameters["note"] else {
                    throw ConfigurationError.invalid("INVALID_ARGUMENT: Incident note is required.")
                }
                let note = rawNote.trimmingCharacters(in: .whitespacesAndNewlines)
                let manager = engine.incidentManager
                let audit = engine.auditLog
                @MainActor func checkErrors() throws {
                    if let error = manager.lastPersistenceError ?? audit.lastPersistenceError ?? engine.persistenceError {
                        throw ConfigurationError.invalid(error)
                    }
                }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                func normalized(_ incident: SafetyIncident) throws -> SafetyIncident {
                    try decoder.decode(SafetyIncident.self, from: encoder.encode(incident))
                }
                func diskIncidents() throws -> [SafetyIncident] {
                    try decoder.decode([SafetyIncident].self, from: Data(contentsOf: manager.storageURL))
                }
                func diskAudit() throws -> [OperatorAuditEntry] {
                    guard FileManager.default.fileExists(atPath: audit.url.path) else { return [] }
                    return try decoder.decode([OperatorAuditEntry].self, from: Data(contentsOf: audit.url))
                }
                func normalizedAudit(_ entries: [OperatorAuditEntry]) throws -> [OperatorAuditEntry] {
                    try decoder.decode([OperatorAuditEntry].self, from: encoder.encode(entries))
                }
                try checkErrors()
                let beforeDisk = try diskIncidents().filter { $0.id == incidentID }
                guard beforeDisk.count == 1, let before = beforeDisk.first,
                      let runtime = manager.incident(id: incidentID),
                      let gui = engine.incidents.first(where: { $0.id == incidentID }),
                      try normalized(runtime) == before, try normalized(gui) == before else {
                    throw ConfigurationError.invalid("Incident missing or incident state is inconsistent.")
                }
                let previousAudit = try diskAudit()
                guard try normalizedAudit(audit.recentEntries(limit: audit.maxEntries)) == previousAudit,
                      try normalizedAudit(engine.auditEntries) == Array(previousAudit.prefix(200)) else {
                    throw ConfigurationError.invalid("Incident audit state is inconsistent.")
                }
                let previousIDs = Set(previousAudit.map(\.id))
                engine.updateIncidentNote(incidentID, note: note)
                try checkErrors()
                let afterDisk = try diskIncidents().filter { $0.id == incidentID }
                guard afterDisk.count == 1, let saved = afterDisk.first,
                      let current = manager.incident(id: incidentID),
                      let displayed = engine.incidents.first(where: { $0.id == incidentID }) else {
                    throw ConfigurationError.invalid("Incident note persistence verification failed.")
                }
                var expected = before
                expected.operatorNotes = note
                expected.updatedAt = saved.updatedAt
                guard saved == expected, try normalized(current) == saved,
                      try normalized(displayed) == saved else {
                    throw ConfigurationError.invalid("Incident note persistence verification failed.")
                }
                let writtenAudit = try diskAudit()
                guard let entry = writtenAudit.first,
                      !previousIDs.contains(entry.id), entry.action == .incidentNoteUpdated,
                      entry.incidentID == incidentID, entry.cameraID == saved.cameraID,
                      entry.details == note,
                      Array(writtenAudit.dropFirst()) == Array(previousAudit.prefix(audit.maxEntries - 1)),
                      try normalizedAudit(audit.recentEntries(limit: audit.maxEntries)) == writtenAudit,
                      try normalizedAudit(engine.auditEntries) == Array(writtenAudit.prefix(200)) else {
                    throw ConfigurationError.invalid("Incident note audit verification failed.")
                }
                try checkErrors()
                return success("Reviewed incident note saved and verified.")

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
