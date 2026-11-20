import CameraCore
import Foundation

/// A sheet retains the exact domain observation from when it was opened.
@MainActor
final class ACTACameraEditorDraft {
    fileprivate let domain: ACTACoordinatedCameraDomain
    private let expected: ACTACoordinatedCameraDomain.Draft
    let configuration: WallConfiguration

    init(domain: ACTACoordinatedCameraDomain, displayed: WallConfiguration) throws {
        let expected = try domain.draft()
        guard expected.configuration == displayed else { throw Failure.stale }
        self.domain = domain
        self.expected = expected
        configuration = expected.configuration
    }

    private init(domain: ACTACoordinatedCameraDomain, expected: ACTACoordinatedCameraDomain.Draft) {
        self.domain = domain
        self.expected = expected
        configuration = expected.configuration
    }

    func refreshAfterRuntime() throws -> ACTACameraEditorDraft {
        ACTACameraEditorDraft(domain: domain, expected: try domain.refreshAfterRuntime(expected))
    }

    func saveCamera(_ camera: Camera, original: Camera?) throws {
        try camera.validate()
        var next = configuration
        let existing = next.cameras.first { $0.id == camera.id }
        guard existing == original, original == nil || original?.id == camera.id else { throw Failure.stale }
        guard !next.cameras.contains(where: {
            $0.id != camera.id &&
            ((camera.localDeviceID != nil && $0.localDeviceID == camera.localDeviceID) ||
             (camera.screenDisplayID != nil && $0.screenDisplayID == camera.screenDisplayID))
        }) else { throw ConfigurationError.invalid("This camera or display is already in the wall.") }
        if let index = next.cameras.firstIndex(where: { $0.id == camera.id }) {
            next.cameras[index] = camera
        } else {
            next.cameras.append(camera)
        }
        try domain.save(next, expected: expected)
    }

    func saveSettings(_ draft: WallConfiguration, includePorts: Bool) throws {
        var next = try configuration.applyingSettings(from: draft)
        if includePorts {
            next.apiPort = draft.apiPort
            next.rtspPort = draft.rtspPort
        }
        try domain.save(next, expected: expected)
    }

    enum Failure: LocalizedError {
        case unavailable, stale

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Camera editing is unavailable until camera coordination is active."
            case .stale: return "Camera configuration changed; close the editor and try again."
            }
        }
    }
}

/// The model owns the domain. The registry does not prolong its runtime lease.
@MainActor
enum ACTACameraEditorDraftRegistry {
    /// Install only after the host coordinates all writers and runtime starts.
    /// Network saves must join discovery and commit this draft under the same domain.
    typealias NetworkSave = @MainActor (ACTACameraEditorDraft, String, Credentials, Camera, Camera?,
                                        @escaping @MainActor (String) -> Void) async throws -> Void

    private final class Entry {
        weak var owner: AnyObject?
        weak var domain: ACTACoordinatedCameraDomain?
        let networkSave: NetworkSave?
        init(owner: AnyObject, domain: ACTACoordinatedCameraDomain, networkSave: NetworkSave?) {
            self.owner = owner
            self.domain = domain
            self.networkSave = networkSave
        }
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]

    static func install(owner: AnyObject, domain: ACTACoordinatedCameraDomain, networkSave: NetworkSave? = nil) {
        entries = entries.filter { $0.value.owner != nil && $0.value.domain != nil }
        entries[ObjectIdentifier(owner)] = Entry(owner: owner, domain: domain, networkSave: networkSave)
    }

    static func remove(owner: AnyObject) {
        entries.removeValue(forKey: ObjectIdentifier(owner))
    }

    static func open(owner: AnyObject, displayed: WallConfiguration) throws -> ACTACameraEditorDraft {
        guard let entry = entries[ObjectIdentifier(owner)], entry.owner === owner,
              let domain = entry.domain else { throw ACTACameraEditorDraft.Failure.unavailable }
        return try ACTACameraEditorDraft(domain: domain, displayed: displayed)
    }

    static func saveNetwork(owner: AnyObject, draft: ACTACameraEditorDraft, ip: String,
                            credentials: Credentials, camera: Camera, original: Camera?,
                            progress: @escaping @MainActor (String) -> Void) async throws {
        guard let entry = entries[ObjectIdentifier(owner)], entry.owner === owner,
              entry.domain === draft.domain, let networkSave = entry.networkSave else {
            throw ACTACameraEditorDraft.Failure.unavailable
        }
        try await networkSave(draft, ip, credentials, camera, original, progress)
    }
}
