import Foundation
import Combine

enum AppLanguage: String {
    case english = "en"
    case russian = "ru"

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "ACTA.interfaceLanguage") ?? "en") ?? .english
    }

    var locale: Locale { Locale(identifier: rawValue) }
    var buttonTitle: String { rawValue.uppercased() }
    var next: AppLanguage { self == .english ? .russian : .english }
    var switchLabelKey: String {
        self == .english ? "Switch interface language to Russian" : "Switch interface language to English"
    }

    func localized(_ key: String, arguments: [CVarArg] = []) -> String {
        InterfaceLocalization.shared(for: self).localized(key, arguments: arguments)
    }

    func localizedMessage(_ message: String) -> String {
        InterfaceLocalization.shared(for: self).message(message)
    }
}

extension Locale {
    var appLanguage: AppLanguage {
        AppLanguage(rawValue: language.languageCode?.identifier ?? identifier) ?? .english
    }
}

extension Date {
    func formatted(date dateStyle: Date.FormatStyle.DateStyle,
                   time timeStyle: Date.FormatStyle.TimeStyle,
                   locale: Locale) -> String {
        formatted(Date.FormatStyle(date: dateStyle, time: timeStyle).locale(locale))
    }
}

@MainActor
protocol LanguageSettingsStorage {
    func string(forKey key: String) -> String?
    func set(_ value: String, forKey key: String)
}

@MainActor
private struct UserDefaultsLanguageStorage: LanguageSettingsStorage {
    let defaults: UserDefaults

    func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    func set(_ value: String, forKey key: String) { defaults.set(value, forKey: key) }
}

@MainActor
final class LanguageSettings: @preconcurrency ObservableObject {
    private static let storageKey = "ACTA.interfaceLanguage"
    private let storage: any LanguageSettingsStorage

    let objectWillChange = ObservableObjectPublisher()
    private(set) var language: AppLanguage
    private(set) var reviewRevision = UUID()
    private var guiWriteDepth = 0
    private var reviewedCommitInProgress = false
    private var storageWriteInProgress = false
    private var deferredLanguages: [AppLanguage] = []

    var onChange: (() -> Void)?
    var locale: Locale { language.locale }
    var storedLanguage: String? { storage.string(forKey: Self.storageKey) }

    convenience init(defaults: UserDefaults = .standard) {
        self.init(storage: UserDefaultsLanguageStorage(defaults: defaults))
    }

    init(storage: any LanguageSettingsStorage) {
        self.storage = storage
        language = AppLanguage(rawValue: storage.string(forKey: Self.storageKey) ?? "") ?? .english
    }

    func setLanguage(_ value: AppLanguage) {
        if storageWriteInProgress {
            reviewRevision = UUID()
            deferredLanguages.append(value)
            return
        }
        guiWriteDepth += 1
        reviewRevision = UUID()
        objectWillChange.send()
        language = value
        reviewRevision = UUID()
        persistLanguage(value)
        guiWriteDepth -= 1
        drainDeferredLanguages()
    }

    func commitReviewedLanguage(_ value: AppLanguage, expectedRevision: UUID,
                                expectedStoredLanguage: String?) -> UUID? {
        guard !reviewedCommitInProgress, guiWriteDepth == 0,
              reviewRevision == expectedRevision else { return nil }
        reviewedCommitInProgress = true
        defer { reviewedCommitInProgress = false }
        objectWillChange.send()
        guard !Task.isCancelled, guiWriteDepth == 0, reviewRevision == expectedRevision,
              storedLanguage == expectedStoredLanguage,
              !Task.isCancelled, guiWriteDepth == 0, reviewRevision == expectedRevision else { return nil }
        language = value
        reviewRevision = UUID()
        let committedRevision = reviewRevision
        persistLanguage(value)
        drainDeferredLanguages()
        return reviewRevision == committedRevision && storedLanguage == value.rawValue
            ? committedRevision : nil
    }

    private func persistLanguage(_ value: AppLanguage) {
        storageWriteInProgress = true
        storage.set(value.rawValue, forKey: Self.storageKey)
        storageWriteInProgress = false
        onChange?()
    }

    private func drainDeferredLanguages() {
        guard !storageWriteInProgress, guiWriteDepth == 0 else { return }
        while !deferredLanguages.isEmpty {
            setLanguage(deferredLanguages.removeFirst())
        }
    }

    func toggle() {
        setLanguage(language.next)
    }

    func localized(_ key: String) -> String {
        language.localized(key)
    }

    func localized(_ key: String, arguments: [CVarArg]) -> String {
        language.localized(key, arguments: arguments)
    }

    func localizedMessage(_ message: String) -> String {
        language.localizedMessage(message)
    }
}