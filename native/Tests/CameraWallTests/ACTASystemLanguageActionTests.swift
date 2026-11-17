import CameraCore
import XCTest
@testable import CameraWall

@MainActor
final class InMemoryLanguageStorage: LanguageSettingsStorage {
    var values: [String: String] = [:]
    var acceptsWrites = true

    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) {
        if acceptsWrites { values[key] = value }
    }
}

private actor InMemorySystemProvider: ACTASystemSettingsProvider {
    var config = WallConfiguration()
    var saves = 0
    var failSaves = false
    var discardSaves = false

    func loadConfiguration() -> WallConfiguration { config }
    func saveConfiguration(_ config: WallConfiguration) throws {
        if failSaves { throw ConfigurationError.invalid("Save failed.") }
        if !discardSaves { self.config = config }
        saves += 1
    }
    func setFailSaves() { failSaves = true }
    func setDiscardSaves() { discardSaves = true }
    func snapshot() -> (WallConfiguration, Int) { (config, saves) }
}

@MainActor
final class ACTASystemLanguageActionTests: XCTestCase {
    func testLanguageUsesLiveInstanceAndReadAfterWriteWithoutSavingConfiguration() async throws {
        let storage = InMemoryLanguageStorage()
        let language = LanguageSettings(storage: storage)
        let provider = InMemorySystemProvider()
        let registry = ACTAActionRegistry()
        await registry.register(ACTASystemLanguageAction(settingsProvider: provider, languageSettings: language))
        var changes = 0
        language.onChange = { changes += 1 }

        let result = try await registry.execute(actionID: "settings.update_system", parameters: ["language": "ru"])
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(language.language, .russian)
        XCTAssertEqual(storage.values["ACTA.interfaceLanguage"], "ru")
        XCTAssertEqual(changes, 1)
        let (_, saves) = await provider.snapshot()
        XCTAssertEqual(saves, 0)

        language.setLanguage(.english)
        let action = ACTASystemLanguageAction(settingsProvider: provider, languageSettings: language)
        let verified = try await action.verify(parameters: ["language": "ru"], context: ACTAActionContext())
        XCTAssertFalse(verified)
    }

    func testMixedUpdateAndInvalidLanguageAreRejectedWithoutWrites() async throws {
        let storage = InMemoryLanguageStorage()
        let language = LanguageSettings(storage: storage)
        let provider = InMemorySystemProvider()
        let registry = ACTAActionRegistry()
        await registry.register(ACTASystemLanguageAction(settingsProvider: provider, languageSettings: language))
        let (before, _) = await provider.snapshot()

        let invalid = try await registry.execute(actionID: "settings.update_system",
                                                 parameters: ["columns": "7", "language": "de"])
        XCTAssertFalse(invalid.success)
        let (unchanged, savesBefore) = await provider.snapshot()
        XCTAssertEqual(unchanged.columns, before.columns)
        XCTAssertEqual(savesBefore, 0)
        XCTAssertEqual(language.language, .english)
        XCTAssertTrue(storage.values.isEmpty)

        let result = try await registry.execute(actionID: "settings.update_system",
                                                parameters: ["columns": "99", "language": "ru"])
        XCTAssertFalse(result.success)
        let (saved, savesAfter) = await provider.snapshot()
        XCTAssertEqual(saved.columns, before.columns)
        XCTAssertEqual(saved.detectionFPS, before.detectionFPS)
        XCTAssertEqual(saved.detectionThreshold, before.detectionThreshold)
        XCTAssertEqual(saved.staleAfterMilliseconds, before.staleAfterMilliseconds)
        XCTAssertEqual(savesAfter, 0)
        XCTAssertEqual(language.language, .english)
        XCTAssertNil(language.storedLanguage)
    }

    func testFailedSystemSaveDoesNotChangeLanguageAndLostLanguageWriteFailsVerification() async throws {
        let storage = InMemoryLanguageStorage()
        let language = LanguageSettings(storage: storage)
        let provider = InMemorySystemProvider()
        await provider.setFailSaves()
        let registry = ACTAActionRegistry()
        await registry.register(ACTASystemLanguageAction(settingsProvider: provider, languageSettings: language))

        let failedSave = try await registry.execute(actionID: "settings.update_system",
                                                    parameters: ["columns": "7", "language": "ru"])
        XCTAssertFalse(failedSave.success)
        XCTAssertEqual(language.language, .english)
        XCTAssertTrue(storage.values.isEmpty)

        storage.acceptsWrites = false
        let lostWrite = try await registry.execute(actionID: "settings.update_system", parameters: ["language": "ru"])
        XCTAssertFalse(lostWrite.success)
        XCTAssertFalse(lostWrite.verified)
        XCTAssertEqual(language.language, .russian)
        XCTAssertNil(language.storedLanguage)
    }

    func testFailedSystemVerificationDoesNotChangeLanguage() async throws {
        let storage = InMemoryLanguageStorage()
        let language = LanguageSettings(storage: storage)
        let provider = InMemorySystemProvider()
        await provider.setDiscardSaves()
        let registry = ACTAActionRegistry()
        await registry.register(ACTASystemLanguageAction(settingsProvider: provider, languageSettings: language))

        let result = try await registry.execute(actionID: "settings.update_system",
                                                parameters: ["columns": "9"])
        XCTAssertFalse(result.success)
        XCTAssertEqual(language.language, .english)
        XCTAssertTrue(storage.values.isEmpty)
    }

    func testSystemOnlyUpdateDoesNotWriteLanguage() async throws {
        let storage = InMemoryLanguageStorage()
        let language = LanguageSettings(storage: storage)
        let provider = InMemorySystemProvider()
        let registry = ACTAActionRegistry()
        await registry.register(ACTASystemLanguageAction(settingsProvider: provider, languageSettings: language))

        let result = try await registry.execute(actionID: "settings.update_system", parameters: ["detection_fps": "7"])
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.verified)
        let (config, saves) = await provider.snapshot()
        XCTAssertEqual(config.detectionFPS, 5)
        XCTAssertEqual(saves, 1)
        XCTAssertTrue(storage.values.isEmpty)
    }
}
