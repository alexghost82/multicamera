import Foundation

public struct VideoFileBookmarkResolution: Equatable, Sendable {
    public let url: URL
    public let bookmarkData: Data?
    public let wasStale: Bool
}

public enum VideoFileBookmark {
    public static func create(for url: URL) throws -> Data {
        guard url.isFileURL else {
            throw ConfigurationError.invalid("A local file URL is required for a bookmark.")
        }
        if isSandboxed {
            return try url.bookmarkData(options: [.withSecurityScope])
        }
        do {
            return try url.bookmarkData(options: [.withSecurityScope])
        } catch {
            return try url.bookmarkData(options: [])
        }
    }

    public static func resolve(_ data: Data?, fallbackURL: URL) throws -> VideoFileBookmarkResolution {
        guard fallbackURL.isFileURL else {
            throw ConfigurationError.invalid("A local file URL is required.")
        }
        guard let data else {
            return VideoFileBookmarkResolution(url: fallbackURL, bookmarkData: nil, wasStale: false)
        }
        var stale = false
        let url: URL
        if isSandboxed {
            url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } else {
            do {
                url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
            } catch {
                stale = false
                url = try URL(
                    resolvingBookmarkData: data,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
            }
        }
        let refreshedData = stale ? (try? create(for: url)) ?? data : data
        return VideoFileBookmarkResolution(url: url, bookmarkData: refreshedData, wasStale: stale)
    }

    private static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }
}