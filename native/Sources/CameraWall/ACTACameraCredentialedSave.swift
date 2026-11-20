import CameraCore
import Foundation

@MainActor
enum ACTACameraCredentialedSave {
    static func run(cameraID: UUID, credentials: Credentials, store: any CameraCredentialStore,
                    beforeWrite: () -> Void, commit: () throws -> Void) throws {
        let previous = try store.read(cameraID)
        beforeWrite()
        try store.save(credentials, for: cameraID)
        do {
            try commit()
        } catch ACTAGUISettingsWriter.Failure.reconciliationRequired {
            throw ConfigurationError.invalid("Camera configuration and credentials may have changed; reconcile both before retrying.")
        } catch {
            let failure = error
            do {
                if let previous { try store.save(previous, for: cameraID) }
                else { try store.remove(cameraID) }
            } catch {
                throw ConfigurationError.invalid("Camera save failed and credential rollback failed.")
            }
            throw failure
        }
    }
}
