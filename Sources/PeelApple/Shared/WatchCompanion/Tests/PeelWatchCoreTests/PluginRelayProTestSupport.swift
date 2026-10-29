import Foundation
@testable import PeelWatchCore

// Explicit synthetic authority used ONLY by offline regression fixtures. No
// public production initializer/default grant or locally persisted paid verdict.
func syntheticProBinding(for fence: PluginRelayFence, routed: Bool = true,
                         expiry: Int64 = Int64(Date().timeIntervalSince1970) + 600) -> PluginRelayProBinding {
    .init(provider: fence.binding.route.provider, accountGeneration: fence.binding.route.accountGeneration,
          enrollmentID: UUID(), phoneDeviceID: "synthetic_fixture_phone", phoneKeySHA256: String(repeating: "a", count: 64),
          watchKeySHA256: String(repeating: "b", count: 64), pairingGeneration: fence.binding.pairingEpoch,
          localEpoch: fence.localEpoch, route: routed ? fence.binding.route : nil, applicationSessionExpiresAt: expiry)
}
func syntheticPaidPermit(for fence: PluginRelayFence, routed: Bool = true) throws -> PluginRelayProPermit {
    let registry = PluginRelayProRegistry(), binding = syntheticProBinding(for: fence, routed: routed)
    let now = Int64(Date().timeIntervalSince1970), operation = try registry.begin()
    try registry.install(.init(leaseID: UUID(), verifiedAt: now, expiresAt: now + 300,
                               binding: binding, verified: true), operation: operation)
    return try registry.permit(binding: binding)
}
#if !os(watchOS)
func installSyntheticPro(_ session: PluginRelayEnrolledPhoneSession, fence: PluginRelayFence? = nil) throws {
    let binding = try session.proBinding(fence: fence), now = Int64(Date().timeIntervalSince1970)
    let operation = try session.proRegistry.begin()
    try session.proRegistry.install(.init(leaseID: UUID(), verifiedAt: now, expiresAt: min(now + 300, binding.applicationSessionExpiresAt),
                                         binding: binding, verified: true), operation: operation)
}
#endif
