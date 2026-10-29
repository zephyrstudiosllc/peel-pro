// Stand-in for HostNetworkServer's session identity, used only by
// typecheck-source-volume.sh so the CoreAudio backend typechecks alone.
nonisolated struct PeelControlSession: Hashable, Sendable {
    let pairingID: String
    let generation: UInt64
}
