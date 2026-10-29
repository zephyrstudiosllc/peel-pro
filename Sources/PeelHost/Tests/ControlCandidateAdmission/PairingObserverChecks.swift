import Foundation
import Combine

struct Peer { let id: String; let name: String }
final class PairingStore: ObservableObject { @Published var paired: [Peer] = [] }
final class HostNetworkServer {
    let pairingStore: PairingStore
    let listenerAdmissionLock = NSLock()
    var knownControlPairingIDs = Set<String>()
    var pairingCancellable: AnyCancellable?
    var listenerRepairs = 0
    init(store: PairingStore, observesPairing: Bool) {
        self.pairingStore = store
        /* PRODUCTION_PAIRING_INITIALIZATION */
        /* PRODUCTION_PAIRING_OBSERVER */
    }
    func scheduleListenerRefreshIfPairingMaterialChanged(reason: String) { listenerRepairs += 1 }
    /* PRODUCTION_PAIRING_MEMBERSHIP_UPDATE */
}
var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ description: String) {
    assertions += 1
    if !condition() { print("FAIL: \(description)"); exit(1) }
}
@main struct PairingObserverChecks {
    static func main() async throws {
        let store = PairingStore()
        store.paired = [.init(id: "a", name: "one"), .init(id: "b", name: "two")]
        let server = HostNetworkServer(store: store, observesPairing: false)
        check(server.knownControlPairingIDs == ["a", "b"], "Preview/nonrepair initialization must retain known metadata")
        var sawPreStoreEmission = false
        let observer = store.$paired.sink { peers in
            if peers.map(\.id) == ["a"] {
                sawPreStoreEmission = store.paired.count == 2
            }
        }
        store.paired = [.init(id: "a", name: "one")]
        check(sawPreStoreEmission, "The fixture must exercise actual @Published willSet emission")
        check(server.knownControlPairingIDs == ["a"], "Revoked ID cannot remain admitted during receive(on:main) delay")
        check(server.listenerRepairs == 0, "No listener side effect may be required to publish current admission metadata")
        store.paired = [.init(id: "a", name: "renamed")]
        check(server.knownControlPairingIDs == ["a"], "Metadata-only change preserves membership")
        try await Task.sleep(nanoseconds: 20_000_000)
        check(server.listenerRepairs == 0, "observesPairing:false retains no-listener-repair behavior")
        let live = HostNetworkServer(store: store, observesPairing: true)
        check(live.knownControlPairingIDs == ["a"], "Normal host begins with current membership")
        store.paired = []
        check(live.knownControlPairingIDs.isEmpty && server.knownControlPairingIDs.isEmpty, "All instances revoke synchronously")
        try await Task.sleep(nanoseconds: 20_000_000)
        check(live.listenerRepairs >= 1, "Production main-queue listener refresh remains connected")
        withExtendedLifetime(observer) {}
        print("PairingObserverChecks: PASS (\(assertions) assertions, actual Combine @Published + extracted production observer/init/membership updater; no Keychain/store I/O)")
    }
}
