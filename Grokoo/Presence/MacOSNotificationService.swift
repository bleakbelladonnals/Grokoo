import AppKit
import CryptoKit
import Foundation
import UserNotifications

enum NotificationAuthorizationState: String, Equatable, Sendable {
    case notDetermined, authorized, denied, provisional, unavailable

    var permitsDelivery: Bool { self == .authorized || self == .provisional }
}

enum NotificationDeliveryOutcome: Equatable, Sendable {
    case submitted, permissionRequired, denied, failed
}

@MainActor
protocol NotificationCenterClient: AnyObject {
    var delegate: (any UNUserNotificationCenterDelegate)? { get set }
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

@MainActor
final class SystemNotificationCenterClient: NotificationCenterClient {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    var delegate: (any UNUserNotificationCenterDelegate)? {
        get { center.delegate }
        set { center.delegate = newValue }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }

    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
}

/// The system notification contains only generated copy and an opaque target.
/// URL construction happens after a click, never inside the notification payload.
enum PresenceNotificationRequest {
    private static let destinationKey = "grokling.destination.v1"

    static func make(_ event: PresenceNotification) -> UNNotificationRequest {
        let payload: SafeNotificationPayload
        let eventIDs: [String]
        let kind: String
        switch event {
        case .blocked(let id, let value):
            payload = value
            eventIDs = [id]
            kind = "blocked"
        case .done(let ids, let value):
            payload = value
            eventIDs = ids
            kind = "done"
        }
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.threadIdentifier = "grokling.\(kind)"
        if let encoded = try? JSONEncoder().encode(payload.destination) {
            content.userInfo = [destinationKey: encoded]
        }
        // No sound or badge: preserve the quiet desktop companion experience.
        // The identifier is stable without exposing source event IDs to macOS.
        let keyData = (try? JSONEncoder().encode(eventIDs)) ?? Data()
        let destinationData = (try? JSONEncoder().encode(payload.destination)) ?? Data()
        let digest = SHA256.hash(data: keyData + destinationData).map { String(format: "%02x", $0) }.joined()
        return UNNotificationRequest(identifier: "grokling.\(kind).\(digest)", content: content, trigger: nil)
    }

    static func destination(from userInfo: [AnyHashable: Any]) -> NotificationDestination {
        guard let data = userInfo[destinationKey] as? Data,
              let destination = try? JSONDecoder().decode(NotificationDestination.self, from: data) else {
            return .mainWindow
        }
        return destination
    }
}

@MainActor
final class MacOSNotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center: any NotificationCenterClient
    private let router: any GrokBotNotificationOpening
    private var activationObserver: NSObjectProtocol?
    private(set) var authorizationStatus: NotificationAuthorizationState = .notDetermined
    private(set) var lastDeliveryOutcome: NotificationDeliveryOutcome?
    var onAuthorizationChange: ((NotificationAuthorizationState) -> Void)?
    var onDelivery: ((NotificationDeliveryOutcome) -> Void)?
    var onOpenDestination: ((Bool) -> Void)?

    init(
        center: any NotificationCenterClient = SystemNotificationCenterClient(),
        router: any GrokBotNotificationOpening = GrokBotNotificationRouter()
    ) {
        self.center = center
        self.router = router
        super.init()
    }

    /// Reading settings is safe on launch; only the explicit Settings action
    /// below can request macOS permission.
    func start() {
        center.delegate = self
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshAuthorization() }
        }
        Task { [weak self] in await self?.refreshAuthorization() }
    }

    func stop() {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        center.delegate = nil
    }

    func refreshAuthorization() async {
        switch await center.authorizationStatus() {
        case .notDetermined: authorizationStatus = .notDetermined
        case .denied: authorizationStatus = .denied
        case .authorized: authorizationStatus = .authorized
        case .provisional: authorizationStatus = .provisional
        @unknown default: authorizationStatus = .unavailable
        }
        onAuthorizationChange?(authorizationStatus)
    }

    func requestAuthorization() async {
        await refreshAuthorization()
        guard authorizationStatus == .notDetermined else { return }
        do {
            _ = try await center.requestAuthorization(options: [.alert])
            await refreshAuthorization()
        } catch {
            authorizationStatus = .unavailable
            onAuthorizationChange?(authorizationStatus)
        }
    }

    @discardableResult
    func deliver(_ event: PresenceNotification) async -> NotificationDeliveryOutcome {
        await refreshAuthorization()
        let outcome: NotificationDeliveryOutcome
        if authorizationStatus == .notDetermined {
            outcome = .permissionRequired
        } else if authorizationStatus == .denied {
            outcome = .denied
        } else if !authorizationStatus.permitsDelivery {
            outcome = .failed
        } else {
            do {
                try await center.add(PresenceNotificationRequest.make(event))
                outcome = .submitted
            } catch {
                outcome = .failed
            }
        }
        lastDeliveryOutcome = outcome
        onDelivery?(outcome)
        return outcome
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    func openDestination(_ destination: NotificationDestination) async -> Bool {
        let opened = await router.open(destination)
        onOpenDestination?(opened)
        return opened
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
            completionHandler()
            return
        }
        let destination = PresenceNotificationRequest.destination(from: response.notification.request.content.userInfo)
        Task { @MainActor [weak self] in await self?.openDestination(destination) }
        completionHandler()
    }
}
