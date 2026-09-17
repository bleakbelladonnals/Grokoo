import Foundation
import os

enum GatewayLogLevel: Sendable {
    case debug
    case info
    case error
}

protocol GatewayLogging: Sendable {
    func log(_ level: GatewayLogLevel, _ message: String)
}

struct GatewayLogger: GatewayLogging, Sendable {
    private let logger = Logger(subsystem: "app.grokling.local", category: "Gateway")

    func log(_ level: GatewayLogLevel, _ message: String) {
        let safe = GatewayRedaction.sanitize(message)
        switch level {
        case .debug: logger.debug("\(safe, privacy: .public)")
        case .info: logger.info("\(safe, privacy: .public)")
        case .error: logger.error("\(safe, privacy: .public)")
        }
    }
}

struct NullGatewayLogger: GatewayLogging, Sendable {
    func log(_: GatewayLogLevel, _: String) {}
}

enum GatewayRedaction {
    /// Last-resort protection for fixed diagnostic strings. Production call sites
    /// never pass server response bodies, tokens, decrypted data, or header values.
    static func sanitize(_ value: String) -> String {
        var result = value
        let patterns = [
            #"(?i)(authorization\s*[:=]\s*)([^\s,;]+)"#,
            #"(?i)(bearer\s+)([^\s,;]+)"#,
            #"(?i)((?:token|password|secret|cookie)\s*[:=]\s*)([^\s,;]+)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1<redacted>")
        }
        return String(result.prefix(500))
    }
}
