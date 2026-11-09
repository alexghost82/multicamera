import Foundation
import Darwin

public struct CameraAddress: Equatable {
    public let host: String
    public let port: Int?

    public init(_ input: String) throws {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, text, &ipv6) == 1 { text = "[\(text)]" }
        guard let parts = URLComponents(string: "http://" + text),
              let parsedHost = parts.host, !parsedHost.isEmpty,
              parts.user == nil, parts.password == nil, parts.path.isEmpty,
              parts.query == nil, parts.fragment == nil,
              parts.port == nil || (1...65535).contains(parts.port!) else {
            throw ConfigurationError.invalid("Enter a camera IP address, optionally followed by :port.")
        }
        let host = parsedHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        var ipv4 = in_addr()
        let isIPv4 = inet_pton(AF_INET, host, &ipv4) == 1
        let isIPv6 = inet_pton(AF_INET6, host, &ipv6) == 1
        let isHostname = host.count <= 253 && host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
        let looksNumeric = host.allSatisfy { $0.isNumber || $0 == "." }
        guard isIPv4 || isIPv6 || (isHostname && !looksNumeric) else {
            throw ConfigurationError.invalid("Enter a valid camera IP address or hostname.")
        }
        self.host = host
        self.port = parts.port
    }

    public var display: String { authority(port: port) }

    public func authority(port: Int?) -> String {
        let address = host.contains(":") ? "[\(host)]" : host
        return address + (port.map { ":\($0)" } ?? "")
    }

    public func onvifURL(port: Int) -> String { "onvif://" + authority(port: port) }

    public func rtspURL(path: String) -> String { "rtsp://" + authority(port: 554) + path }
}