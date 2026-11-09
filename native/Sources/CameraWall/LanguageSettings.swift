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
final class LanguageSettings: ObservableObject {
    private static let storageKey = "ACTA.interfaceLanguage"
    private let defaults: UserDefaults

    @Published private(set) var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Self.storageKey)
            onChange?()
        }
    }

    var onChange: (() -> Void)?
    var locale: Locale { language.locale }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = AppLanguage(rawValue: defaults.string(forKey: Self.storageKey) ?? "") ?? .english
    }

    func toggle() {
        language = language.next
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