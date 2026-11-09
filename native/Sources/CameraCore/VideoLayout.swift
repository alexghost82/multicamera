import Foundation

public struct ResizeEdges: OptionSet, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let left = Self(rawValue: 1)
    public static let right = Self(rawValue: 2)
    public static let top = Self(rawValue: 4)
    public static let bottom = Self(rawValue: 8)
}

public struct VideoTileFrame: Codable, Equatable, Sendable {
    public static let minimumWidth: Double = 120
    public static let minimumHeight: Double = 90
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite)
            && (0...65536).contains(x) && (0...65536).contains(y)
            && (Self.minimumWidth...8192).contains(width)
            && (Self.minimumHeight...8192).contains(height)
    }

    public func moved(dx: Double, dy: Double) -> Self {
        guard dx.isFinite, dy.isFinite else { return self }
        return Self(x: min(65536, max(0, x + dx)), y: min(65536, max(0, y + dy)), width: width, height: height)
    }

    public func resized(edges: ResizeEdges, dx: Double, dy: Double) -> Self {
        guard dx.isFinite, dy.isFinite else { return self }
        var left = x
        var top = y
        var right = x + width
        var bottom = y + height
        if edges.contains(.left) { left = max(0, right - 8192, min(right - Self.minimumWidth, x + dx)) }
        if edges.contains(.right) { right = left + min(8192, max(Self.minimumWidth, width + dx)) }
        if edges.contains(.top) { top = max(0, bottom - 8192, min(bottom - Self.minimumHeight, y + dy)) }
        if edges.contains(.bottom) { bottom = top + min(8192, max(Self.minimumHeight, height + dy)) }
        return Self(x: left, y: top, width: right - left, height: bottom - top)
    }
}

public struct VideoWallLayout: Codable, Equatable {
    public var frames: [String: VideoTileFrame] = [:]
    public init() {}

    public static func columnCount(configured: Int, cameraCount: Int, expanded: Bool) -> Int {
        expanded ? 1 : min(max(1, configured), max(1, cameraCount))
    }

    public static func gridTileFrame(index: Int, columns: Int, availableWidth: Double, gap: Double) -> VideoTileFrame {
        let columnCount = max(1, columns)
        let width = max(160, (availableWidth - Double(columnCount + 1) * gap) / Double(columnCount))
        let height = width * 9 / 16
        return VideoTileFrame(
            x: Double(index % columnCount) * (width + gap) + gap,
            y: Double(index / columnCount) * (height + gap) + gap,
            width: width,
            height: height
        )
    }

    public func validate() throws {
        guard frames.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value.isValid }) else {
            throw ConfigurationError.invalid("Invalid saved video window layout.")
        }
    }

    public static func load(from url: URL) throws -> Self {
        let layout = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try layout.validate()
        return layout
    }

    public func save(to url: URL) throws {
        try validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}