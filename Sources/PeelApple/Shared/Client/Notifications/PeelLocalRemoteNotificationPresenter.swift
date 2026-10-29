#if os(iOS) || os(visionOS)
import Foundation
import Combine
@preconcurrency import UserNotifications

/// Enqueues an already-admitted remote notification in the local platform
/// notification center.
///
/// This type intentionally does not set `UNUserNotificationCenter.delegate`.
/// The app's existing global delegate remains the owner of delegate wiring;
/// it can call `foregroundPresentationOptions(for:)` from its existing
/// `willPresent` method when it wants banners for Peel-owned requests.
@MainActor
public final class PeelLocalRemoteNotificationPresenter: ObservableObject {
    /// One app-owned presenter is shared by the main chooser and every peeled
    /// scene. Creating it has no authorization or delivery side effect.
    public static let shared = PeelLocalRemoteNotificationPresenter()

    public enum AuthorizationError: Error, Equatable, Sendable, LocalizedError {
        case requestFailed(String)

        public var errorDescription: String? {
            switch self {
            case .requestFailed(let message):
                return "The local notification authorization request failed: \(message)"
            }
        }
    }

    public typealias AuthorizationCompletion =
        @MainActor @Sendable (Result<Bool, AuthorizationError>) -> Void

    public typealias DeliveryCompletion =
        @MainActor @Sendable (Result<DeliveryReceipt, DeliveryError>) -> Void

    /// The receiver supplies this callback so the presenter can re-check the
    /// exact source connection, pairing, visible session, and opt-in after the
    /// asynchronous notification-center call returns.
    public typealias IsCurrent =
        @MainActor @Sendable (PeelRemoteNotificationAdmission) -> Bool

    public struct DeliveryReceipt: Equatable, Sendable {
        public let requestId: UUID
        public let sessionId: UUID
        public let acceptedAt: TimeInterval

        public init(
            requestId: UUID,
            sessionId: UUID,
            acceptedAt: TimeInterval
        ) {
            self.requestId = requestId
            self.sessionId = sessionId
            self.acceptedAt = acceptedAt
        }
    }

    public enum DeliveryError: Error, Equatable, Sendable, LocalizedError {
        case disabled
        case stale
        case admission(PeelRemoteNotificationAdmissionRejection)
        case notificationCenterFailure(String)

        public var errorDescription: String? {
            switch self {
            case .disabled:
                return "Remote notifications are not enabled on this device."
            case .stale:
                return "The notification session is no longer current."
            case .admission(let rejection):
                return rejection.errorDescription
            case .notificationCenterFailure(let message):
                return "The local notification center rejected the request: \(message)"
            }
        }
    }

    public static let notificationIdentifierPrefix = "peel.remote."
    public static let sourceRequestIdKey = "peel.remote.sourceRequestId"
    public static let sourceSessionIdKey = "peel.remote.sourceSessionId"

    private let notificationCenter: UNUserNotificationCenter
    private var admissionPolicy: PeelRemoteNotificationAdmissionPolicy

    /// Shared app-owned foreground history. Pass one instance to the
    /// presenter and all client scenes that need the banner or inbox sheet.
    public let inbox: PeelRemoteNotificationInbox

    /// This flag is local delivery state, not an OS authorization query. It is
    /// set only by an explicit user authorization action or a read-only refresh.
    @Published public private(set) var isEnabled = false

    /// A disable invalidates every in-flight request. Each request captures the
    /// generation before calling `UNUserNotificationCenter.add` and is removed
    /// by its own identifier if that generation becomes stale.
    private var deliveryGeneration = UUID()

    /// Optional app-owned foreground/inbox sink. It is called on the main
    /// actor only after `UNUserNotificationCenter.add` accepts the request, so
    /// an in-app banner can remain visible when iOS suppresses foreground OS
    /// presentation.
    public var onAdmitted: ((PeelRemoteNotificationAdmission) -> Void)?

    public var latestNotifications: [PeelRemoteNotificationInbox.Entry] {
        inbox.entries
    }

    public init(
        notificationCenter: UNUserNotificationCenter = .current(),
        admissionPolicy: PeelRemoteNotificationAdmissionPolicy = .init(),
        inbox: PeelRemoteNotificationInbox? = nil
    ) {
        self.notificationCenter = notificationCenter
        self.admissionPolicy = admissionPolicy
        self.inbox = inbox ?? PeelRemoteNotificationInbox()
    }

    /// Call this only from a user-initiated settings action. Enqueueing a
    /// remote request never prompts for authorization implicitly.
    public func requestAuthorizationFromUser(
        completion: @escaping AuthorizationCompletion
    ) {
        notificationCenter.requestAuthorization(options: [.alert]) {
            [weak self] granted, error in
            let errorMessage = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let errorMessage {
                    self.disableLocalDelivery()
                    completion(.failure(.requestFailed(errorMessage)))
                    return
                }

                if granted {
                    self.isEnabled = true
                } else {
                    self.disableLocalDelivery()
                }
                completion(.success(granted))
            }
        }
    }

    /// Refreshes the current OS authorization state without presenting a
    /// prompt. This is suitable for app activation and settings screens.
    public func refreshAuthorizationStatus(
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        notificationCenter.getNotificationSettings { [weak self] settings in
            let enabled = Self.isDeliverable(settings.authorizationStatus)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if enabled, PeelAgentNotifications.isOptedIn {
                    self.isEnabled = true
                } else {
                    self.disableLocalDelivery()
                }
                completion(enabled)
            }
        }
    }

    /// Disables this feature locally. It does not revoke the user's OS-level
    /// notification permission and does not prompt or open Settings.
    public func disableLocalDelivery() {
        isEnabled = false
        deliveryGeneration = UUID()
    }

    /// Admit and enqueue one request. A successful completion means only that
    /// `UNUserNotificationCenter.add` accepted the request for delivery; it
    /// does not mean that a banner was presented or that a user saw it.
    public func enqueue(
        _ message: PeelRemoteNotificationMessage,
        now: TimeInterval = Date().timeIntervalSince1970,
        completion: @escaping DeliveryCompletion
    ) {
        enqueue(
            message,
            now: now,
            isCurrent: { _ in true },
            completion: completion
        )
    }

    /// Admit and enqueue one request while preserving the source-session
    /// identity supplied by the caller. `isCurrent` is evaluated both before
    /// enqueueing and after the notification-center completion callback.
    public func enqueue(
        _ message: PeelRemoteNotificationMessage,
        now: TimeInterval = Date().timeIntervalSince1970,
        isCurrent: @escaping IsCurrent,
        completion: @escaping DeliveryCompletion
    ) {
        guard isEnabled, PeelAgentNotifications.isOptedIn else {
            completion(.failure(.disabled))
            return
        }

        let admission: PeelRemoteNotificationAdmission
        switch admissionPolicy.admit(message, now: now) {
        case .success(let accepted):
            admission = accepted
        case .failure(let rejection):
            completion(.failure(.admission(rejection)))
            return
        }

        enqueue(
            admission: admission,
            isCurrent: isCurrent,
            completion: completion
        )
    }

    /// Enqueue a value admitted by the session-owned policy. Keeping policy
    /// state with `PeelHostSession` lets a control-socket reset clear its
    /// dedupe and rate state without affecting another Mac session.
    public func enqueue(
        admission: PeelRemoteNotificationAdmission,
        isCurrent: @escaping IsCurrent,
        completion: @escaping DeliveryCompletion
    ) {
        guard isEnabled, PeelAgentNotifications.isOptedIn else {
            completion(.failure(.disabled))
            return
        }

        guard isCurrent(admission) else {
            completion(.failure(.stale))
            return
        }

        let generation = deliveryGeneration
        let identifier = Self.notificationIdentifier(
            requestId: admission.requestId,
            sessionId: admission.sessionId
        )

        // Only fixed plain-text fields and normalized source IDs cross into
        // UserNotifications. URL-looking text remains inert text: there are
        // no actions, attachments, custom sounds, scripts, or caller-provided
        // arbitrary userInfo values.
        let content = UNMutableNotificationContent()
        content.title = admission.title
        content.body = admission.body
        content.userInfo = [
            Self.sourceRequestIdKey: admission.requestId.uuidString,
            Self.sourceSessionIdKey: admission.sessionId.uuidString,
        ]

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            // A nil trigger asks iOS to deliver the local request immediately.
            // Expiration is enforced at admission time and is never used as a
            // remotely controlled delayed trigger.
            trigger: nil
        )

        notificationCenter.add(request) { [weak self] error in
            let errorMessage = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let errorMessage {
                    completion(
                        .failure(
                            .notificationCenterFailure(errorMessage)
                        )
                    )
                    return
                }

                guard self.deliveryGeneration == generation,
                      self.isEnabled,
                      PeelAgentNotifications.isOptedIn,
                      isCurrent(admission) else {
                    self.removeOwnedNotification(identifier: identifier)
                    completion(.failure(.stale))
                    return
                }

                self.inbox.insert(admission)
                self.onAdmitted?(admission)
                completion(
                    .success(
                        DeliveryReceipt(
                            requestId: admission.requestId,
                            sessionId: admission.sessionId,
                            acceptedAt: Date().timeIntervalSince1970
                        )
                    )
                )
            }
        }
    }

    /// Remove only the exact request created by this presenter. This is used
    /// when a socket, pairing, visibility state, or opt-in changes while the
    /// asynchronous local enqueue is completing.
    private func removeOwnedNotification(identifier: String) {
        guard identifier.hasPrefix(Self.notificationIdentifierPrefix) else {
            return
        }
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [identifier])
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// Hook for the app's existing global notification delegate. The presenter
    /// does not install or replace that delegate. Return these options only for
    /// identifiers created by this presenter; callers may union them with the
    /// app's existing foreground options.
    public func foregroundPresentationOptions(
        for notification: UNNotification
    ) -> UNNotificationPresentationOptions {
        Self.foregroundPresentationOptions(
            forIdentifier: notification.request.identifier
        )
    }

    public static func foregroundPresentationOptions(
        forIdentifier identifier: String
    ) -> UNNotificationPresentationOptions {
        guard identifier.hasPrefix(notificationIdentifierPrefix) else {
            return []
        }
        return [.banner, .list]
    }

    public static func notificationIdentifier(
        requestId: UUID,
        sessionId: UUID
    ) -> String {
        "\(notificationIdentifierPrefix)\(sessionId.uuidString).\(requestId.uuidString)"
    }

    nonisolated private static func isDeliverable(
        _ status: UNAuthorizationStatus
    ) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }
}
#endif
