import AppKit
import Foundation
import XCTest
@testable import CameraWall

final class LanguageSettingsTests: XCTestCase {
    func testEveryDetectionClassHasRussianDisplayName() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/CameraWall/YOLO26Detector.swift"), encoding: .utf8)
        let expression = try NSRegularExpression(pattern: #"private static let labels = \"([^\"]+)\""#)
        let match = try XCTUnwrap(expression.firstMatch(in: source, range: NSRange(source.startIndex..<source.endIndex, in: source)))
        let labels = (source as NSString).substring(with: match.range(at: 1)).components(separatedBy: ",")
        XCTAssertEqual(labels.count, 80)
        for label in labels { XCTAssertNotEqual(AppLanguage.russian.localized(label), label, label) }
    }

    func testRussianPermissionResourceCoversEveryUsageDescription() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let info = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Info.plist")), format: nil) as? [String: Any])
        let translations = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Resources/ru.lproj/InfoPlist.strings")), format: nil) as? [String: String])
        for key in info.keys where key.hasSuffix("UsageDescription") {
            let translated = try XCTUnwrap(translations[key], key)
            XCTAssertTrue(translated.unicodeScalars.contains { (0x0410...0x044F).contains($0.value) }, key)
        }
    }

    @MainActor
    func testNativeSavePanelUsesRussianLabelsWithoutOpeningIt() {
        _ = NSApplication.shared
        let panel = NSSavePanel()
        InterfaceLocalization.configure(panel, title: "Export diagnostics", language: .russian)
        XCTAssertEqual(panel.title, "Экспортировать диагностику")
        XCTAssertEqual(panel.prompt, "Сохранить")
        XCTAssertEqual(panel.nameFieldLabel, "Имя файла:")
    }

    func testFallExplanationTranslatesMetricsWithoutTranslatingOperatorNames() {
        let language = AppLanguage.russian
        let explanation = "Fall confirmed after 0.8 s transition (horizontal posture, height 97% of upright baseline, aspect ratio 1.39)."
        let translated = language.localizedMessage(explanation)
        XCTAssertFalse(translated.contains("horizontal posture"))
        XCTAssertFalse(translated.contains("upright baseline"))
        XCTAssertTrue(translated.contains("0.8"))
        XCTAssertTrue(translated.contains("97%"))
        XCTAssertTrue(translated.contains("1.39"))
        let namedZone = language.localizedMessage("Person entered restricted zone 'Fall Confirmed' for 1.0 s (hold threshold 0.5 s).")
        XCTAssertTrue(namedZone.contains("Fall Confirmed"), "Operator-supplied names remain data")
        XCTAssertEqual(language.localizedMessage("Unknown external error 123"), "Unknown external error 123")
    }

    func testRussianRuntimeTemplatesAndNestedErrorsAreTranslated() {
        let language = AppLanguage.russian
        XCTAssertEqual(language.localizedMessage("YOLO26n · 12 ms"), "YOLO26n · 12 мс")
        XCTAssertEqual(language.localizedMessage("Analyzing 2 camera(s)…"), "Анализ камер: 2…")
        XCTAssertEqual(language.localizedMessage("Local mission complete: Gate % 12"), "Локальная задача завершена: Gate % 12")
        XCTAssertEqual(language.localizedMessage("Local VLM request failed: The native VLM returned an empty response."),
            "Не удалось выполнить запрос к локальной VLM: Нативная VLM вернула пустой ответ.")
        XCTAssertEqual(language.localizedMessage("No description jobs."), "Нет заданий описания.")
        XCTAssertEqual(language.localizedMessage("Unknown external detail 123"), "Unknown external detail 123")
    }

    func testRussianFavoriteAndEvidenceFailureMessages() {
        let language = AppLanguage.russian
        XCTAssertEqual(language.localized("Favorite settings unavailable"), "Настройки избранного недоступны")
        XCTAssertEqual(language.localizedMessage("Camera shutdown did not finish: detail"),
                       "Остановка камер не завершена: detail")
        let message = "Evidence deletion failed: Evidence may have been deleted; check the bundle, incident and audit before retrying: detail"
        XCTAssertEqual(language.localizedMessage(message),
            "Не удалось удалить материалы инцидента: Материалы могли быть удалены; проверьте файлы, инцидент и журнал аудита перед повторной попыткой: detail")
        let nested = "Evidence deletion failed: Evidence may have been deleted; check the bundle, incident and audit before retrying: Evidence bundle path is not a directory."
        XCTAssertTrue(language.localizedMessage(nested).contains("Путь к материалам инцидента не является каталогом."))
        XCTAssertEqual(language.localized("Cannot read evidence snapshot: %@", arguments: [
            language.localizedMessage("Evidence snapshot path is not a regular file.")
        ]), "Не удалось прочитать снимок инцидента: Путь к снимку инцидента не является обычным файлом.")
        XCTAssertEqual(language.localized("Cannot read evidence clip frames: %@", arguments: [
            language.localizedMessage("Evidence clip frame path is not a regular file.")
        ]), "Не удалось прочитать кадры инцидента: Путь к кадру инцидента не является обычным файлом.")
    }

    func testRussianCompilerCatalogHasNoMissingKeys() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try XCTUnwrap(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: root.appendingPathComponent("Resources/ru.lproj/Localizable.strings")), format: nil) as? [String: String])
        let audit = root.appendingPathComponent(".build/localization-audit/compiler-keys.json")
        guard FileManager.default.fileExists(atPath: audit.path) else {
            throw XCTSkip("Run the documented compiler localization audit to verify the exact current UI key set.")
        }
        let keys = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: audit)) as? [String])
        XCTAssertGreaterThan(keys.count, 400)
        XCTAssertTrue(keys.filter { catalog[$0]?.isEmpty != false }.isEmpty,
            "Missing Russian keys: \(keys.filter { catalog[$0]?.isEmpty != false })")
    }

    func testRussianCatalogPreservesFormatArgumentTypes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try XCTUnwrap(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: root.appendingPathComponent("Resources/ru.lproj/Localizable.strings")), format: nil) as? [String: String])
        let tokens = try NSRegularExpression(pattern: #"%%|%(?:[1-9][0-9]*\$)?[-+0-9.#]*(?:hh|ll|[hlLzjt])?[@diuoxXfFeEgGcs]"#)
        func types(_ text: String) -> [String] {
            let source = text as NSString
            return tokens.matches(in: text, range: NSRange(location: 0, length: source.length))
                .map { source.substring(with: $0.range) }.filter { $0 != "%%" }.sorted()
        }
        for (key, value) in catalog { XCTAssertEqual(types(key), types(value), key) }
    }

    func testRegionalLocalesKeepTheSelectedInterfaceLanguage() {
        for identifier in ["ru", "ru_RU", "ru-RU"] {
            XCTAssertEqual(Locale(identifier: identifier).appLanguage, .russian)
        }
        for identifier in ["en", "en_US", "en_GB"] {
            XCTAssertEqual(Locale(identifier: identifier).appLanguage, .english)
        }
    }

    func testMissingTranslationStillSubstitutesDynamicArguments() {
        XCTAssertEqual(AppLanguage.english.localized("Synthetic audit count: %lld", arguments: [7]), "Synthetic audit count: 7")
        XCTAssertEqual(AppLanguage.russian.localized("Synthetic audit name: %@", arguments: ["fixture"]), "Synthetic audit name: fixture")
    }

    func testLanguageSelectionTogglesAndPersists() async {
        await MainActor.run {
            let suiteName = "CameraWall.LanguageSettingsTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let settings = LanguageSettings(defaults: defaults)
            XCTAssertEqual(settings.language, .english)

            settings.toggle()
            XCTAssertEqual(settings.language, .russian)
            XCTAssertEqual(defaults.string(forKey: "ACTA.interfaceLanguage"), "ru")
            XCTAssertEqual(LanguageSettings(defaults: defaults).language, .russian)

            settings.toggle()
            XCTAssertEqual(settings.language, .english)
        }
    }
}