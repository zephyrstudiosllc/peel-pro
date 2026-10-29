import Foundation

@MainActor
enum PeelAgentPresentation {
    static var phoneRegistered = false
    static func setPhoneRouteRegistered(_ registered: Bool) { phoneRegistered = registered }
}

@MainActor
final class SceneHarness {
    struct Route { let claimID = UUID() }
    final class Browser {
        var refreshes = 0
        func refreshAgentPresentationCapabilities() { refreshes += 1 }
    }
    var browser: Browser? = Browser()
    var sceneRouteID = UUID()
    var isRouteRegistered = false
    var inFlightRoute: Route?
    var declines = 0
    var finished = 0
    var drains = 0
    var availability: [Bool] = []
    func declinePendingRequests(reason: String) { declines += 1 }
    func finishCurrentRoute(claimID: UUID, status: String, reason: String) { finished += 1; inFlightRoute = nil }
    func onRouteAvailabilityChanged(_ value: Bool) { availability.append(value) }
    func drainPendingRequests() { drains += 1 }
    // ROUTE METHOD
}

@main
@MainActor
struct SceneChecks {
    static func main() {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            count += 1
            guard value() else { fatalError(message) }
        }
        let first = SceneHarness(), second = SceneHarness()
        check(!PeelPhoneSceneAvailability.isAvailable, "phone capability starts absent")
        first.setRouteRegistered(true)
        second.setRouteRegistered(true)
        check(PeelAgentPresentation.phoneRegistered && PeelPhoneSceneAvailability.isAvailable, "two scene-specific routes advertise one aggregate capability")
        first.inFlightRoute = SceneHarness.Route()
        first.setRouteRegistered(false)
        check(first.finished == 1 && first.declines == 0, "retiring scene finishes only its own in-flight claim while sibling can drain")
        check(PeelAgentPresentation.phoneRegistered && second.isRouteRegistered, "retiring one scene preserves sibling binding/capability")
        second.setRouteRegistered(true)
        check(second.drains == 2 && second.browser?.refreshes == 1, "repeated registration drains without duplicate capability refresh")
        second.setRouteRegistered(false)
        check(second.declines == 1 && !PeelAgentPresentation.phoneRegistered, "last scene declines pending requests and removes capability")
        second.setRouteRegistered(false)
        check(second.declines == 1, "repeat disconnect cannot decline twice")
        PeelPhoneSceneAvailability.setRegistered(false, route: UUID())
        check(!PeelPhoneSceneAvailability.isAvailable, "unknown/deinit cleanup cannot resurrect capability")
        print("Phone scene routing: PASS (\(count) checks)")
    }
}
