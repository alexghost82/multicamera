import Foundation

/// User-facing calendar periods are resolved before retrieval, never guessed by the language model.
enum UnifiedHistoryTimeScope {
    static func resolve(question: String, prior: [TrackResearchMessage], now: Date, calendar: Calendar = .current) throws -> TrackResearchTimeScope? {
        let relative = try NSRegularExpression(pattern: "(?i)(?:последни[а-я]*|last|past)\\s*(\\d{1,3})?\\s*(минут|час|дн|день|недел|minute|hour|day|week)")
        let ns = question as NSString
        if let match = relative.firstMatch(in: question, range: NSRange(location: 0, length: ns.length)) {
            let amount = match.range(at: 1).location == NSNotFound ? 1 : Int(ns.substring(with: match.range(at: 1))) ?? 1
            let unit = ns.substring(with: match.range(at: 2)).lowercased()
            let seconds: Double = unit.hasPrefix("мин") || unit == "minute" ? 60 : unit.hasPrefix("час") || unit == "hour" ? 3600 : unit.hasPrefix("нед") || unit == "week" ? 604800 : 86400
            return TrackResearchTimeScope(start: now.addingTimeInterval(-Double(amount) * seconds), end: now)
        }
        var normalized = question
        let months = ["янв": 1, "фев": 2, "мар": 3, "апр": 4, "май": 5, "мая": 5, "июн": 6, "июл": 7, "авг": 8, "сен": 9, "окт": 10, "ноя": 11, "дек": 12,
                      "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
        let dates = try NSRegularExpression(pattern: "(?i)(?<![0-9])(\\d{1,2})\\s+(январ[ья]|феврал[ья]|март[а]?|апрел[ья]|ма[йя]|июн[ья]|июл[ья]|август[а]?|сентябр[ья]|октябр[ья]|ноябр[ья]|декабр[ья]|January|February|March|April|May|June|July|August|September|October|November|December)(?:\\s+(20[0-9]{2}))?")
        for match in dates.matches(in: question, range: NSRange(location: 0, length: ns.length)).reversed() {
            let day = Int(ns.substring(with: match.range(at: 1))) ?? 0
            let month = months[String(ns.substring(with: match.range(at: 2)).lowercased().prefix(3))] ?? 0
            let year = match.range(at: 3).location == NSNotFound ? calendar.component(.year, from: now) : Int(ns.substring(with: match.range(at: 3))) ?? 0
            normalized = (normalized as NSString).replacingCharacters(in: match.range, with: String(format: "%04d-%02d-%02d", year, month, day))
        }
        let iso = try NSRegularExpression(pattern: "(?<![0-9])[0-9]{4}-[0-9]{2}-[0-9]{2}(?![0-9])")
        let normalizedNS = normalized as NSString
        let matches = iso.matches(in: normalized, range: NSRange(location: 0, length: normalizedNS.length))
        var scope: TrackResearchTimeScope?
        if matches.count == 2 {
            let first = try TrackResearchTimeScope.resolve(question: normalizedNS.substring(with: matches[0].range), priorMessages: [], now: now, calendar: calendar)
            let last = try TrackResearchTimeScope.resolve(question: normalizedNS.substring(with: matches[1].range), priorMessages: [], now: now, calendar: calendar)
            guard let first, let last, first.start < last.end else { throw TrackResearchError.invalidDate }
            scope = TrackResearchTimeScope(start: first.start, end: last.end)
        } else {
            scope = try TrackResearchTimeScope.resolve(question: normalized, priorMessages: prior, now: now, calendar: calendar)
        }
        let hours = try NSRegularExpression(pattern: "(?i)(?:с|from)\\s+(\\d{1,2})(?::(\\d{2}))?\\s*(?:до|по|to|until)\\s*(\\d{1,2})(?::(\\d{2}))?")
        if let match = hours.firstMatch(in: question, range: NSRange(location: 0, length: ns.length)) {
            func number(_ group: Int) -> Int { match.range(at: group).location == NSNotFound ? 0 : Int(ns.substring(with: match.range(at: group))) ?? -1 }
            let h1 = number(1), m1 = number(2), h2 = number(3), m2 = number(4)
            guard (0...23).contains(h1), (0...23).contains(h2), (0...59).contains(m1), (0...59).contains(m2) else { throw TrackResearchError.invalidDate }
            let day = calendar.startOfDay(for: scope?.start ?? now)
            let start = day.addingTimeInterval(Double(h1 * 3600 + m1 * 60))
            let end = day.addingTimeInterval(Double(h2 * 3600 + m2 * 60))
            guard end > start else { throw TrackResearchError.invalidDate }
            scope = TrackResearchTimeScope(start: start, end: end)
        }
        return scope
    }
}
