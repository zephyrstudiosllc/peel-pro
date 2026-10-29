import Foundation

/// Capability readiness belongs to the set of visible phone scenes, while
/// each scene keeps its own presentation binding and in-flight request.
@MainActor
enum PeelPhoneSceneAvailability {
    private static var registeredRoutes: Set<UUID> = []

    static var isAvailable: Bool { !registeredRoutes.isEmpty }

    static func setRegistered(_ registered: Bool, route: UUID) {
        if registered { registeredRoutes.insert(route) }
        else { registeredRoutes.remove(route) }
        PeelAgentPresentation.setPhoneRouteRegistered(isAvailable)
    }
}
