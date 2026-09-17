import AppKit
import Foundation

/// Routes verified against the installed Grok Bot 0.53.0 application on
/// 2026-09-17: Info.plist and both main-core.cjs / renderer route declarations.
/// The application exposes an agent route, but no task route.
enum GrokBotNotificationRoute {
    static let bundleIdentifier = "com.anysphere.sand"
    static let mainWindowURL = URL(string: "grokbot://app/v1/open")!

    static func url(for destination: NotificationDestination) -> URL {
        guard case .bot(let id) = destination,
              id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
            return mainWindowURL
        }
        var components = URLComponents()
        components.scheme = "grokbot"
        components.host = "app"
        components.path = "/v1/agent"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url ?? mainWindowURL
    }
}

@MainActor
protocol GrokBotNotificationOpening: AnyObject {
    func open(_ destination: NotificationDestination) async -> Bool
}

@MainActor
final class GrokBotNotificationRouter: GrokBotNotificationOpening {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func open(_ destination: NotificationDestination) async -> Bool {
        guard let applicationURL = workspace.urlForApplication(
            withBundleIdentifier: GrokBotNotificationRoute.bundleIdentifier
        ) else { return false }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        do {
            _ = try await workspace.open(
                [GrokBotNotificationRoute.url(for: destination)],
                withApplicationAt: applicationURL,
                configuration: configuration
            )
            return true
        } catch {
            // If a route could not be dispatched, launch/reopen the real app.
            // Never invent a task URL or open an unrelated web fallback.
            do {
                _ = try await workspace.openApplication(at: applicationURL, configuration: configuration)
                return true
            } catch {
                return false
            }
        }
    }
}
