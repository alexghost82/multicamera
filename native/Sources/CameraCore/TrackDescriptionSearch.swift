import Foundation

public struct TrackDescriptionSearchResult: Sendable {
    public let records: [TrackedObjectRecord]
    public let matchCount: Int
}

public enum TrackDescriptionSearch {
    public static func search(store: LocalTrackingStore, query: String,
                              limit: Int = 250, pageSize: Int = 1000) throws -> TrackDescriptionSearchResult {
        let resultLimit = min(1000, max(1, limit))
        var records: [TrackedObjectRecord] = []
        var matchCount = 0
        try store.forEachRecentTrackPage(pageSize: pageSize) { page in
            try Task.checkCancellation()
            let matches = filter(page, query: query)
            matchCount += matches.count
            records.append(contentsOf: matches)
            records.sort {
                if $0.lastSeen != $1.lastSeen { return $0.lastSeen > $1.lastSeen }
                return $0.trackID.uuidString < $1.trackID.uuidString
            }
            if records.count > resultLimit { records.removeLast(records.count - resultLimit) }
        }
        return TrackDescriptionSearchResult(records: records, matchCount: matchCount)
    }

    public static func filter(_ records: [TrackedObjectRecord], query: String) -> [TrackedObjectRecord] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return records }
        return records.filter { record in
            let descriptionFields = record.description.map { description in
                [description.summary] + description.attributes.flatMap { name, attribute in
                    [name, attribute.value, attribute.evidence]
                }
            } ?? []
            let searchableText = ([record.label, record.cameraName] + descriptionFields).joined(separator: " ")
            return terms.allSatisfy { searchableText.localizedStandardContains($0) }
        }
    }
}