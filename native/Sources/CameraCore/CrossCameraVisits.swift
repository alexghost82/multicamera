import Foundation

public struct CrossCameraVisitGroup: Equatable, Identifiable, Sendable {
    public let identityID: UUID
    public let visits: [TrackedObjectRecord]

    public var id: UUID { identityID }
    public var cameraCount: Int { Set(visits.map(\.cameraID)).count }
    public var latestSeen: Date { visits.map(\.lastSeen).max() ?? .distantPast }

    public var route: [CrossCameraPresence] {
        var result: [CrossCameraPresence] = []
        for visit in visits.sorted(by: {
            if $0.firstSeen != $1.firstSeen { return $0.firstSeen < $1.firstSeen }
            return $0.trackID.uuidString < $1.trackID.uuidString
        }) {
            guard visit.firstSeen <= visit.lastSeen else { continue }
            if let previous = result.last, previous.cameraID == visit.cameraID,
               visit.firstSeen <= previous.lastSeen {
                result[result.count - 1] = CrossCameraPresence(
                    cameraID: previous.cameraID, cameraName: previous.cameraName,
                    firstSeen: previous.firstSeen, lastSeen: max(previous.lastSeen, visit.lastSeen),
                    trackIDs: previous.trackIDs + [visit.trackID]
                )
            } else {
                result.append(CrossCameraPresence(
                    cameraID: visit.cameraID, cameraName: visit.cameraName,
                    firstSeen: visit.firstSeen, lastSeen: visit.lastSeen, trackIDs: [visit.trackID]
                ))
            }
        }
        return result
    }

    public func attributeFacets(minimumConfidence: Double = 0.5) -> [CrossCameraAttributeFacet] {
        guard minimumConfidence.isFinite, (0...1).contains(minimumConfidence) else { return [] }
        var grouped: [String: [String: Set<UUID>]] = [:]
        for visit in visits {
            for (name, attribute) in visit.description?.attributes ?? [:] {
                let value = attribute.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard attribute.confidence.isFinite, attribute.confidence >= minimumConfidence,
                      attribute.confidence <= 1, !value.isEmpty,
                      value.caseInsensitiveCompare("unknown") != .orderedSame else { continue }
                grouped[name, default: [:]][value, default: []].insert(visit.trackID)
            }
        }
        return grouped.keys.sorted().flatMap { name in
            grouped[name, default: [:]].keys.sorted().map { value in
                CrossCameraAttributeFacet(
                    name: name, value: value,
                    trackIDs: grouped[name]?[value, default: []].sorted { $0.uuidString < $1.uuidString } ?? []
                )
            }
        }
    }
}

public struct CrossCameraPresence: Equatable, Sendable {
    public let cameraID: UUID
    public let cameraName: String
    public let firstSeen: Date
    public let lastSeen: Date
    public let trackIDs: [UUID]
}

public struct CrossCameraAttributeFacet: Equatable, Sendable {
    public let name: String
    public let value: String
    public let trackIDs: [UUID]
}

public struct CrossCameraPresenceQuery: Equatable, Sendable {
    public var cameraIDs: Set<UUID>
    public var interval: DateInterval?
    public var objectClass: String?
    public var attributes: [String: String]
    public var minimumAttributeConfidence: Double
    public var cameraSequence: [UUID]

    public init(
        cameraIDs: Set<UUID> = [], interval: DateInterval? = nil, objectClass: String? = nil,
        attributes: [String: String] = [:], minimumAttributeConfidence: Double = 0.5,
        cameraSequence: [UUID] = []
    ) {
        self.cameraIDs = cameraIDs
        self.interval = interval
        self.objectClass = objectClass
        self.attributes = attributes
        self.minimumAttributeConfidence = minimumAttributeConfidence
        self.cameraSequence = cameraSequence
    }

    public func matches(_ group: CrossCameraVisitGroup) -> Bool {
        guard minimumAttributeConfidence.isFinite, (0...1).contains(minimumAttributeConfidence) else { return false }
        let visits = group.visits.filter { visit in
            guard visit.firstSeen <= visit.lastSeen else { return false }
            if !cameraIDs.isEmpty, !cameraIDs.contains(visit.cameraID) { return false }
            if let interval, visit.lastSeen < interval.start || visit.firstSeen > interval.end { return false }
            if let objectClass, visit.label.caseInsensitiveCompare(objectClass) != .orderedSame { return false }
            return attributes.allSatisfy { name, value in
                guard let attribute = visit.description?.attributes[name],
                      attribute.confidence.isFinite,
                      attribute.confidence >= minimumAttributeConfidence, attribute.confidence <= 1 else { return false }
                let actual = attribute.value.trimmingCharacters(in: .whitespacesAndNewlines)
                let requested = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return !requested.isEmpty && actual.caseInsensitiveCompare("unknown") != .orderedSame
                    && actual.caseInsensitiveCompare(requested) == .orderedSame
            }
        }
        guard !visits.isEmpty else { return false }
        guard !cameraSequence.isEmpty else { return true }
        let route = CrossCameraVisitGroup(identityID: group.identityID, visits: visits).route
        var earliestEnds = [Date?](repeating: nil, count: cameraSequence.count)
        for presence in route {
            for sequenceIndex in cameraSequence.indices.reversed() {
                guard presence.cameraID == cameraSequence[sequenceIndex] else { continue }
                if sequenceIndex > 0 {
                    guard let previousEnd = earliestEnds[sequenceIndex - 1],
                          presence.firstSeen >= previousEnd else { continue }
                }
                if earliestEnds[sequenceIndex].map({ presence.lastSeen < $0 }) ?? true {
                    earliestEnds[sequenceIndex] = presence.lastSeen
                }
            }
        }
        return earliestEnds[cameraSequence.count - 1] != nil
    }
}

public enum CrossCameraVisitIndex {
    public static func groups(
        records: [TrackedObjectRecord],
        identityByTrackID: [UUID: UUID]
    ) -> [CrossCameraVisitGroup] {
        let grouped = Dictionary(grouping: records.compactMap { record -> (UUID, TrackedObjectRecord)? in
            guard let identityID = identityByTrackID[record.trackID] else { return nil }
            return (identityID, record)
        }, by: \.0)
        return grouped.map { identityID, entries in
            CrossCameraVisitGroup(
                identityID: identityID,
                visits: entries.map(\.1).sorted {
                    if $0.firstSeen != $1.firstSeen { return $0.firstSeen < $1.firstSeen }
                    return $0.trackID.uuidString < $1.trackID.uuidString
                }
            )
        }
        .sorted {
            if $0.latestSeen != $1.latestSeen { return $0.latestSeen > $1.latestSeen }
            return $0.identityID.uuidString < $1.identityID.uuidString
        }
    }
}