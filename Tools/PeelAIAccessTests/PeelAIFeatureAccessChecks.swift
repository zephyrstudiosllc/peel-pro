import Foundation

private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}

@main
enum PeelAIFeatureAccessChecks {
    static func main() {
        let notifications = NotificationCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: PeelAIFeatureAccess.didChangeNotification, object: nil, queue: nil
        ) { _ in notifications.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }

        precondition(!PeelAIFeatureAccess.isDevelopmentPreview, "Debug and Release must use the commercial gate")
        precondition(!PeelAIFeatureAccess.isAllowed)
        assertManualConsentRequiresPro(expected: false)
        PeelAIFeatureAccess.update(subscriptionExpiration: nil)
        precondition(!PeelAIFeatureAccess.isAllowed && notifications.count == 0)
        let expired = Date(timeIntervalSinceNow: -60)
        PeelAIFeatureAccess.update(subscriptionExpiration: expired)
        precondition(!PeelAIFeatureAccess.isAllowed && notifications.count == 1)
        PeelAIFeatureAccess.update(subscriptionExpiration: expired)
        precondition(notifications.count == 1)
        let future = Date(timeIntervalSinceNow: 60)
        PeelAIFeatureAccess.update(subscriptionExpiration: future)
        precondition(PeelAIFeatureAccess.isAllowed && notifications.count == 2)
        assertManualConsentRequiresPro(expected: true)
        PeelAIFeatureAccess.update(subscriptionExpiration: future)
        precondition(notifications.count == 2)
        PeelAIFeatureAccess.update(subscriptionExpiration: nil)
        precondition(!PeelAIFeatureAccess.isAllowed && notifications.count == 3)
        assertManualConsentRequiresPro(expected: false)
        PeelAIFeatureAccess.update(lifetimeAccess: true, subscriptionExpiration: nil)
        precondition(PeelAIFeatureAccess.isAllowed && notifications.count == 4,
                     "Old and new lifetime ownership must activate actual remote-feature access")
        assertManualConsentRequiresPro(expected: true)
        PeelAIFeatureAccess.update(lifetimeAccess: true, subscriptionExpiration: expired)
        precondition(PeelAIFeatureAccess.isAllowed && notifications.count == 5,
                     "An expired subscription must not take away lifetime Pro")
        PeelAIFeatureAccess.update(lifetimeAccess: false, subscriptionExpiration: expired)
        precondition(!PeelAIFeatureAccess.isAllowed && notifications.count == 6,
                     "Verified lifetime revocation removes the paid gate")
        assertManualConsentRequiresPro(expected: false)
        PeelAIFeatureAccess.update(lifetimeAccess: true, subscriptionExpiration: future)
        PeelAIFeatureAccess.update(lifetimeAccess: false, subscriptionExpiration: future)
        precondition(PeelAIFeatureAccess.isAllowed, "A separate active subscription survives lifetime revocation")
        PeelAIFeatureAccess.update(subscriptionExpiration: nil)
        precondition(!PeelAIFeatureAccess.isAllowed)
        assertManualConsentRequiresPro(expected: false)
        // Consent stays enabled when payment access expires; runtime permission
        // must deny immediately without relying on a disabled Settings toggle.
        PeelAIFeatureAccess.update(subscriptionExpiration: Date(timeIntervalSinceNow: -1))
        assertManualConsentRequiresPro(expected: false)
        print("PeelAIFeatureAccessChecks: passed (Debug/Release commercial access, lifetime + timed Pro, manual consent cannot bypass expiry/revocation)")
    }

    private static func assertManualConsentRequiresPro(expected: Bool) {
        precondition(PeelManualAgentControl.allows(platformSupported: true, optedIn: true) == expected)
        precondition(!PeelManualAgentControl.allows(platformSupported: true, optedIn: false),
                     "Purchasing Pro must not grant consent")
        precondition(!PeelManualAgentControl.allows(platformSupported: false, optedIn: true),
                     "Purchasing Pro must not bypass platform support")
    }
}
