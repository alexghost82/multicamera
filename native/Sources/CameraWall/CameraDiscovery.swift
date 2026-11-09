import Foundation
import CoreVideo
import CameraCore

struct DetectedStream: Equatable {
    var source: String
    var width: Int
    var height: Int
    var pixels: Int64 { Int64(width) * Int64(height) }
}

struct DetectedCamera: Equatable {
    var substream: String
    var mainstream: String?
}

@MainActor
struct CameraDiscovery {
    var profiles: (CameraAddress, Credentials) async throws -> [String]
    var probe: (String, Credentials) async throws -> DetectedStream?

    func discover(address: CameraAddress, credentials: Credentials, preferred: Camera? = nil,
                  progress: (String) -> Void) async throws -> DetectedCamera {
        if let preferred, let host = URLComponents(string: preferred.substream)?.host,
           host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased() == address.host {
            progress("Checking saved streams")
            if let sub = try await probe(preferred.substream, credentials) {
                try Task.checkCancellation()
                var main: String?
                if let source = preferred.mainstream, let stream = try await probe(source, credentials) { main = stream.source }
                try Task.checkCancellation()
                return DetectedCamera(substream: sub.source, mainstream: main)
            }
        }
        progress("Discovering ONVIF profiles")
        let sources = try await profiles(address, credentials)
        var detected: [DetectedStream] = []
        var seen = Set<String>()
        for source in sources where seen.insert(source).inserted {
            try Task.checkCancellation()
            progress("Checking video profile \(detected.count + 1)")
            try Camera(name: "Probe", substream: source).validate()
            if let stream = try await probe(source, credentials) { detected.append(stream) }
        }
        try Task.checkCancellation()
        if let result = Self.select(detected) { return result }

        let paths: [(String, String)] = [
            ("/Streaming/Channels/102", "/Streaming/Channels/101"),
            ("/cam/realmonitor?channel=1&subtype=1", "/cam/realmonitor?channel=1&subtype=0"),
            ("/h264Preview_01_sub", "/h264Preview_01_main"),
            ("/live/ch00_1", "/live/ch00_0"),
            ("/axis-media/media.amp", "/axis-media/media.amp"),
            ("/live", "/live")
        ]
        for (subpath, mainpath) in paths {
            try Task.checkCancellation()
            progress("Checking standard RTSP streams")
            let subURL = address.rtspURL(path: subpath)
            guard let sub = try await probe(subURL, credentials) else { continue }
            var streams = [sub]
            if mainpath != subpath, let main = try await probe(address.rtspURL(path: mainpath), credentials) { streams.append(main) }
            try Task.checkCancellation()
            if let result = Self.select(streams) { return result }
        }
        throw ConfigurationError.invalid("No supported video stream found. Check the IP, credentials, camera network access and ONVIF/RTSP settings. Some cameras require a separate ONVIF user.")
    }

    static func select(_ streams: [DetectedStream]) -> DetectedCamera? {
        let sorted = streams.filter { $0.width > 0 && $0.height > 0 }.sorted {
            $0.pixels == $1.pixels ? $0.source < $1.source : $0.pixels < $1.pixels
        }
        guard let sub = sorted.first, let main = sorted.last else { return nil }
        return DetectedCamera(substream: sub.source, mainstream: main.source == sub.source ? nil : main.source)
    }

    static func detect(ip: String, credentials: Credentials, config: WallConfiguration, preferred: Camera?,
                       progress: (String) -> Void) async throws -> DetectedCamera {
        let address = try CameraAddress(ip)
        let relay = Go2RTC()
        defer { relay.stop() }
        var temporary = config
        temporary.apiPort = Int.random(in: 20000...29999)
        temporary.rtspPort = Int.random(in: 30000...39999)
        temporary.cameras = []
        progress("Starting camera discovery")
        try await relay.start(config: temporary)
        let discovery = CameraDiscovery(profiles: { address, credentials in
            try await relay.profiles(address: address, credentials: credentials)
        }, probe: { source, credentials in
            try Task.checkCancellation()
            let name = "probe_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let localURL = try await relay.register(source: source, name: name, credentials: credentials)
            let session = CameraSession()
            defer { session.stop() }
            session.start(url: localURL)
            let deadline = ProcessInfo.processInfo.systemUptime + 4
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                if let pixel = session.snapshot().pixel {
                    return DetectedStream(source: source, width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            return nil
        })
        return try await discovery.discover(address: address, credentials: credentials, preferred: preferred, progress: progress)
    }
}