import CameraCore
import Combine
import Foundation
import SwiftUI

enum ACTACameraScope: String, CaseIterable, Identifiable {
    case all = "All cameras"
    case live = "Live"
    case offline = "Offline"

    var id: String { rawValue }
    var title: LocalizedStringKey { LocalizedStringKey(rawValue) }
}

enum ACTACameraPresentation: String, CaseIterable, Identifiable, Sendable {
    case grid
    case list

    var id: String { rawValue }
    var title: LocalizedStringKey { self == .grid ? "Grid" : "List" }
    var icon: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}

@MainActor
final class ACTACanvasFilterState: @preconcurrency ObservableObject {
    struct Snapshot {
        var cameraScope: ACTACameraScope = .all
        var locationFilter: String?
        var searchText = ""
        var alertsOnly = false
        var favoritesOnly = false
        var selectedCameraIDs: Set<UUID>?
        var arrangeCameras = false
        var presentation: ACTACameraPresentation = .grid
        var analysisSection: VLMPanelSection = .ask
        var analysisChatLifecycle = UUID()
        var analysisScheduleRefreshOnAppear = true
    }

    let objectWillChange = ObservableObjectPublisher()
    private var snapshot = Snapshot()
    private var guiWriteDepth = 0
    private var reviewedCommitInProgress = false
    private(set) var reviewRevision = UUID()
    var cameraScope: ACTACameraScope {
        get { snapshot.cameraScope }
        set { setFromGUI(\.cameraScope, to: newValue) }
    }
    var locationFilter: String? {
        get { snapshot.locationFilter }
        set { setFromGUI(\.locationFilter, to: newValue) }
    }
    var searchText: String {
        get { snapshot.searchText }
        set { setFromGUI(\.searchText, to: newValue) }
    }
    var alertsOnly: Bool {
        get { snapshot.alertsOnly }
        set { setFromGUI(\.alertsOnly, to: newValue) }
    }
    var favoritesOnly: Bool {
        get { snapshot.favoritesOnly }
        set { setFromGUI(\.favoritesOnly, to: newValue) }
    }
    var selectedCameraIDs: Set<UUID>? {
        get { snapshot.selectedCameraIDs }
        set { setFromGUI(\.selectedCameraIDs, to: newValue) }
    }
    var arrangeCameras: Bool {
        get { snapshot.arrangeCameras }
        set { setFromGUI(\.arrangeCameras, to: newValue) }
    }
    var presentation: ACTACameraPresentation {
        get { snapshot.presentation }
        set { setFromGUI(\.presentation, to: newValue) }
    }
    var analysisSection: VLMPanelSection {
        get { snapshot.analysisSection }
        set { setFromGUI(\.analysisSection, to: newValue) }
    }
    var analysisChatLifecycle: UUID { snapshot.analysisChatLifecycle }
    let analysisVoiceInput: LocalVoiceInput
    var analysisVoiceBusy: Bool { analysisVoiceInput.isAttemptActive }
    var analysisScheduleRefreshOnAppear: Bool {
        get { snapshot.analysisScheduleRefreshOnAppear }
        set {
            reviewRevision = UUID()
            snapshot.analysisScheduleRefreshOnAppear = newValue
        }
    }

    init(analysisVoiceInput: LocalVoiceInput? = nil) {
        self.analysisVoiceInput = analysisVoiceInput ?? LocalVoiceInput()
    }

    private func setFromGUI<Value>(_ keyPath: WritableKeyPath<Snapshot, Value>, to value: Value) {
        guiWriteDepth += 1
        defer { guiWriteDepth -= 1 }
        reviewRevision = UUID()
        objectWillChange.send()
        let previousSection = snapshot.analysisSection
        snapshot[keyPath: keyPath] = value
        if snapshot.analysisSection != previousSection {
            snapshot.analysisChatLifecycle = UUID()
        }
        reviewRevision = UUID()
    }

    func commitReviewed(expectedRevision: UUID, isValid: () -> Bool,
                        update: (inout Snapshot) -> Void) -> UUID? {
        guard !reviewedCommitInProgress, guiWriteDepth == 0, reviewRevision == expectedRevision else { return nil }
        reviewedCommitInProgress = true
        defer { reviewedCommitInProgress = false }
        var next = snapshot
        update(&next)
        guard guiWriteDepth == 0, reviewRevision == expectedRevision else { return nil }
        if next.analysisSection != snapshot.analysisSection {
            next.analysisChatLifecycle = UUID()
        }
        objectWillChange.send()
        guard guiWriteDepth == 0, reviewRevision == expectedRevision, isValid(),
              guiWriteDepth == 0, reviewRevision == expectedRevision else { return nil }
        snapshot = next
        reviewRevision = UUID()
        return reviewRevision
    }

    func stopAnalysisVoice() {
        analysisVoiceInput.stop()
    }

    func invalidateAnalysisChatLifecycle() {
        snapshot.analysisChatLifecycle = UUID()
        reviewRevision = UUID()
    }

    func selectAnalysisSectionFromGUI(_ section: VLMPanelSection) {
        if analysisSection == .ask && section != .ask { stopAnalysisVoice() }
        analysisScheduleRefreshOnAppear = true
        analysisSection = section
    }

    static func locationGroup(_ location: String?) -> String {
        let trimmed = location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Other" : trimmed
    }

    func includesCamera(id: UUID) -> Bool {
        selectedCameraIDs?.contains(id) ?? true
    }

    func includes(name: String, location: String?, stale: Bool?, favorite: Bool, hasEvents: Bool) -> Bool {
        guard cameraScope == .all || (cameraScope == .live) == (stale == false) else { return false }
        guard locationFilter == nil || Self.locationGroup(location) == locationFilter else { return false }
        guard !favoritesOnly || favorite else { return false }
        guard !alertsOnly || hasEvents else { return false }
        return searchText.isEmpty || "\(name) \(location ?? "")".localizedCaseInsensitiveContains(searchText)
    }
}

@MainActor
final class ACTACanvasFilterBridge {
    private struct Entry {
        weak var state: ACTACanvasFilterState?
    }
    private var entries: [Entry] = []
    private var voiceInputAllowed: Bool
    init(voiceInputAllowed: Bool = false) { self.voiceInputAllowed = voiceInputAllowed }
    var hasActiveVoiceInput: Bool { entries.contains { $0.state?.analysisVoiceInput.isAttemptActive == true } }
    private(set) var lifecycleRevision = UUID()
    private weak var writtenState: ACTACanvasFilterState?
    private var writtenRevision: UUID?
    private var writtenInventoryRevision: UUID?
    private weak var arrangeWrittenState: ACTACanvasFilterState?
    private weak var presentationWrittenState: ACTACanvasFilterState?
    private var arrangeWrittenRevision: UUID?
    private var presentationWrittenRevision: UUID?
    private weak var analysisWrittenState: ACTACanvasFilterState?
    private var analysisWrittenSection: VLMPanelSection?
    private var analysisWrittenRevision: UUID?
    private var analysisWrittenRefresh: Bool?
    private weak var selectionWrittenState: ACTACanvasFilterState?
    private var selectionInventory: Set<UUID>?
    private var selectionValue: Set<UUID>?
    private var selectionWrittenRevision: UUID?
    private var selectionInventoryRevision: UUID?

    func attach(_ state: ACTACanvasFilterState) {
        lifecycleRevision = UUID()
        clearWrite()
        arrangeWrittenState = nil
        presentationWrittenState = nil
        clearAnalysisWrite()
        clearSelectionWrite()
        entries.removeAll { $0.state == nil || $0.state === state }
        entries.append(Entry(state: state))
        let attempt = state.analysisVoiceInput.setInputAllowed(voiceInputAllowed)
        state.analysisVoiceInput.cancelRevokedAttempt(attempt)
    }

    func setVoiceInputAllowed(_ allowed: Bool) {
        voiceInputAllowed = allowed
        let states = entries.compactMap(\.state)
        // Close every gate before cancellation publishes synchronous UI notifications.
        let attempts = states.map { state in
            (state.analysisVoiceInput, state.analysisVoiceInput.setInputAllowed(allowed))
        }
        for (voice, attempt) in attempts {
            voice.cancelRevokedAttempt(attempt)
        }
    }

    func detach(_ state: ACTACanvasFilterState) {
        lifecycleRevision = UUID()
        clearWrite()
        arrangeWrittenState = nil
        presentationWrittenState = nil
        clearAnalysisWrite()
        clearSelectionWrite()
        entries.removeAll { $0.state == nil || $0.state === state }
    }

    var activeState: ACTACanvasFilterState? {
        let states = entries.compactMap(\.state)
        return states.count == 1 ? states.first : nil
    }

    func clearWrite() {
        writtenState = nil
        writtenRevision = nil
        writtenInventoryRevision = nil
    }

    func recordWrite(to state: ACTACanvasFilterState, inventoryRevision: UUID) {
        writtenState = state
        writtenRevision = state.reviewRevision
        writtenInventoryRevision = inventoryRevision
    }

    var writtenActiveState: ACTACanvasFilterState? {
        guard let state = activeState, state === writtenState, state.reviewRevision == writtenRevision else { return nil }
        return state
    }

    func verifiesFilterInventory(_ revision: UUID?) -> Bool {
        revision != nil && revision == writtenInventoryRevision
    }

    func recordArrangeWrite(to state: ACTACanvasFilterState) {
        arrangeWrittenState = state
        arrangeWrittenRevision = state.reviewRevision
    }

    func clearArrangeWrite() {
        arrangeWrittenState = nil
        arrangeWrittenRevision = nil
    }

    var arrangeWrittenActiveState: ACTACanvasFilterState? {
        guard let state = activeState, state === arrangeWrittenState,
              state.reviewRevision == arrangeWrittenRevision else { return nil }
        return state
    }

    func recordPresentationWrite(to state: ACTACanvasFilterState) {
        presentationWrittenState = state
        presentationWrittenRevision = state.reviewRevision
    }

    func clearPresentationWrite() {
        presentationWrittenState = nil
        presentationWrittenRevision = nil
    }

    var presentationWrittenActiveState: ACTACanvasFilterState? {
        guard let state = activeState, state === presentationWrittenState,
              state.reviewRevision == presentationWrittenRevision else { return nil }
        return state
    }

    func recordAnalysisWrite(to state: ACTACanvasFilterState, section: VLMPanelSection, revision: UUID) {
        analysisWrittenState = state
        analysisWrittenSection = section
        analysisWrittenRevision = revision
        analysisWrittenRefresh = state.analysisScheduleRefreshOnAppear
    }

    func clearAnalysisWrite() {
        analysisWrittenState = nil
        analysisWrittenSection = nil
        analysisWrittenRevision = nil
        analysisWrittenRefresh = nil
    }

    func verifiesAnalysisSection(_ section: VLMPanelSection) -> Bool {
        guard let state = activeState, state === analysisWrittenState else { return false }
        return analysisWrittenSection == section && state.analysisSection == section
            && state.reviewRevision == analysisWrittenRevision
            && state.analysisScheduleRefreshOnAppear == analysisWrittenRefresh
    }

    func clearSelectionWrite() {
        selectionWrittenState = nil
        selectionInventory = nil
        selectionValue = nil
        selectionWrittenRevision = nil
        selectionInventoryRevision = nil
    }

    func recordSelectionWrite(to state: ACTACanvasFilterState, inventory: Set<UUID>, selection: Set<UUID>,
                              inventoryRevision: UUID? = nil) {
        selectionWrittenState = state
        selectionInventory = inventory
        selectionValue = selection
        selectionWrittenRevision = state.reviewRevision
        selectionInventoryRevision = inventoryRevision
    }

    func verifiesSelection(inventory: Set<UUID>, selection: Set<UUID>, inventoryRevision: UUID? = nil) -> Bool {
        guard let state = activeState, state === selectionWrittenState else { return false }
        return selectionInventory == inventory && selectionValue == selection && state.selectedCameraIDs == selection
            && state.reviewRevision == selectionWrittenRevision && selectionInventoryRevision == inventoryRevision
    }
}

struct ACTACanvasSetFilterAction: ACTAPreparedConfirmationAction {
    struct ConfirmationSnapshot: Sendable {
        let lifecycleRevision: UUID
        let stateRevision: UUID
        let search: String
        let location: String?
        let status: String
        let favorites: Bool
        let events: Bool
        let locationGroups: Set<String>?
        let inventoryRevision: UUID
    }
    let id = "canvas.set_filter"
    let title = "Set camera canvas filters"
    let description = "Update only supplied filters in the unique attached security center, even if another section is visible. Search matches camera name and location; events means stored VLM alerts or ISAPI events, not live events. Location names must match an enabled camera group; an empty location clears it. Camera-picker selection is unchanged. Verification checks GUI state, not rendering or camera connectivity."
    let classification = ACTAActionClassification.reversible
    let parameters = [
        ACTAActionParameterSchema(name: "search", type: "string", description: "Exact search text; empty clears search", allowsEmpty: true),
        ACTAActionParameterSchema(name: "location", type: "string", description: "Exact enabled camera location group; empty selects all locations", allowsEmpty: true),
        ACTAActionParameterSchema(name: "status", type: "string", description: "Camera status", allowedValues: ["all", "live", "offline"]),
        ACTAActionParameterSchema(name: "favorites_only", type: "boolean", description: "Show only favorite cameras"),
        ACTAActionParameterSchema(name: "events_only", type: "boolean", description: "Show only cameras with stored VLM alerts or ISAPI events")
    ]
    let bridge: ACTACanvasFilterBridge
    let locationGroups: @MainActor @Sendable () -> Set<String>?
    var inventoryRevision: @MainActor @Sendable () -> UUID? = { nil }

    private func parsed(_ parameters: [String: String]) throws -> (String?, String?, ACTACameraScope?, Bool?, Bool?) {
        guard !parameters.isEmpty, Set(parameters.keys).isSubset(of: ["search", "location", "status", "favorites_only", "events_only"]),
              parameters["search"].map({ $0.utf8.count <= 4096 }) ?? true,
              parameters["location"].map({ value in
                  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                  return value.utf8.count <= 4096 && (value.isEmpty || (!trimmed.isEmpty && value == trimmed && value != "All Locations"))
              }) ?? true else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Provide supported filters; search and location are limited to 4096 UTF-8 bytes.")
        }
        let status: ACTACameraScope?
        switch parameters["status"] {
        case nil: status = nil
        case "all": status = .all
        case "live": status = .live
        case "offline": status = .offline
        default: throw ConfigurationError.invalid("INVALID_ARGUMENT: Invalid status.")
        }
        func boolean(_ key: String) throws -> Bool? {
            switch parameters[key] {
            case nil: return nil
            case "true": return true
            case "false": return false
            default: throw ConfigurationError.invalid("INVALID_ARGUMENT: Invalid \(key).")
            }
        }
        return (parameters["search"], parameters["location"], status, try boolean("favorites_only"), try boolean("events_only"))
    }

    func validate(parameters: [String: String]) throws {
        _ = try parsed(parameters)
    }

    func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws
        -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let (_, location, _, _, _) = try parsed(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            guard let state = bridge.activeState, let inventoryRevision = inventoryRevision() else {
                throw ConfigurationError.invalid("UNAVAILABLE: No unique active camera view.")
            }
            let lifecycleRevision = bridge.lifecycleRevision
            let stateRevision = state.reviewRevision
            let groups = locationGroups()
            guard self.inventoryRevision() == inventoryRevision,
                  bridge.lifecycleRevision == lifecycleRevision, bridge.activeState === state,
                  state.reviewRevision == stateRevision else {
                throw ConfigurationError.invalid("STALE_REVIEW: Camera filters, inventory or window changed.")
            }
            if let location, !location.isEmpty {
                guard let groups else {
                    throw ConfigurationError.invalid("UNAVAILABLE: Camera location inventory is unavailable.")
                }
                guard groups.contains(location) else {
                    throw ConfigurationError.invalid("INVALID_ARGUMENT: Location is not an enabled camera group.")
                }
            }
            let snapshot = ConfirmationSnapshot(
                lifecycleRevision: lifecycleRevision, stateRevision: stateRevision, search: state.searchText,
                location: state.locationFilter, status: state.cameraScope.rawValue,
                favorites: state.favoritesOnly, events: state.alertsOnly, locationGroups: groups,
                inventoryRevision: inventoryRevision)
            let previous: [String: Any] = [
                "search": snapshot.search, "location": snapshot.location as Any? ?? NSNull(),
                "status": snapshot.status, "favorites_only": snapshot.favorites,
                "events_only": snapshot.events
            ]
            let encoded = try JSONSerialization.data(withJSONObject: previous, options: [.sortedKeys])
            return ACTAPreparedConfirmation(snapshot: snapshot,
                reviewSummary: "Unique active camera view. Previous filters: \(String(decoding: encoded, as: UTF8.self)). Only the supplied parameters will change.")
        }
    }

    func executeConfirmed(parameters: [String: String], context: ACTAActionContext,
                          snapshot: ConfirmationSnapshot) async throws -> ACTAActionResult {
        let (search, location, status, favorites, events) = try parsed(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            bridge.clearWrite()
            let sameLocation: Bool
            switch (bridge.activeState?.locationFilter, snapshot.location) {
            case (nil, nil): sameLocation = true
            case let (left?, right?): sameLocation = left.utf8.elementsEqual(right.utf8)
            default: sameLocation = false
            }
            guard bridge.lifecycleRevision == snapshot.lifecycleRevision, let state = bridge.activeState,
                  state.reviewRevision == snapshot.stateRevision,
                  state.searchText.utf8.elementsEqual(snapshot.search.utf8), sameLocation,
                  state.cameraScope.rawValue == snapshot.status, state.favoritesOnly == snapshot.favorites,
                  state.alertsOnly == snapshot.events else {
                return .failed(actionID: id, error: "STALE_REVIEW: Camera filters, inventory or window changed.")
            }
            if let location, !location.isEmpty, snapshot.locationGroups?.contains(location) != true {
                return .failed(actionID: id, error: "STALE_REVIEW: Camera location inventory changed.")
            }
            guard let revision = state.commitReviewed(expectedRevision: snapshot.stateRevision, isValid: {
                guard !Task.isCancelled,
                      self.inventoryRevision() == snapshot.inventoryRevision,
                      self.locationGroups() == snapshot.locationGroups,
                      self.inventoryRevision() == snapshot.inventoryRevision else { return false }
                return self.bridge.lifecycleRevision == snapshot.lifecycleRevision && self.bridge.activeState === state
            }, update: {
                if let search { $0.searchText = search }
                if let location { $0.locationFilter = location.isEmpty ? nil : location }
                if let status { $0.cameraScope = status }
                if let favorites { $0.favoritesOnly = favorites }
                if let events { $0.alertsOnly = events }
            }) else {
                try Task.checkCancellation()
                return .failed(actionID: id, error: "STALE_REVIEW: Camera filters, inventory or window changed.")
            }
            bridge.recordWrite(to: state, inventoryRevision: snapshot.inventoryRevision)
            guard state.reviewRevision == revision, bridge.writtenActiveState === state,
                  matches(state, search: search, location: location, status: status, favorites: favorites, events: events) else {
                bridge.clearWrite()
                return .failed(actionID: id, error: "Camera filter state readback failed.")
            }
            return ACTAActionResult(actionID: id, success: true,
                summary: "Camera view filter state updated; rendering and camera connectivity were not verified.",
                outputJSON: "{}")
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        await MainActor.run { bridge.clearWrite() }
        do {
            let prepared = try await prepareConfirmation(parameters: parameters, context: context)
            return try await executeConfirmed(parameters: parameters, context: context, snapshot: prepared.snapshot)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed(actionID: id, error: error.localizedDescription)
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let (search, location, status, favorites, events) = try parsed(parameters)
        return await MainActor.run {
            guard bridge.writtenActiveState != nil else { return false }
            if let location, !location.isEmpty {
                guard let groups = locationGroups(), groups.contains(location) else { return false }
            }
            guard bridge.verifiesFilterInventory(inventoryRevision()),
                  let state = bridge.writtenActiveState else { return false }
            return matches(state, search: search, location: location, status: status, favorites: favorites, events: events)
        }
    }

    @MainActor
    private func matches(_ state: ACTACanvasFilterState, search: String?, location: String?, status: ACTACameraScope?,
                         favorites: Bool?, events: Bool?) -> Bool {
        (search == nil || state.searchText == search)
            && (location == nil || state.locationFilter == (location == "" ? nil : location))
            && (status == nil || state.cameraScope == status)
            && (favorites == nil || state.favoritesOnly == favorites)
            && (events == nil || state.alertsOnly == events)
    }
}
