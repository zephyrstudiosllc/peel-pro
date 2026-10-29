import Foundation

// Compile with the production shared model, TLS model and Host controller.
// No store/controller initialization, networking, defaults or Keychain access.
private var checks = 0
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fatalError("FAIL: \(message)") }
}

let hostID = "00000000-0000-4000-8000-000000000001"
let epoch = "00000000-0000-4000-8000-000000000002"
let deviceID = "A0000000-0000-4000-8000-000000000003"
let otherDevice = "00000000-0000-4000-8000-000000000004"
let pairingID = "00000000-0000-4000-8000-000000000005"
let requestID = "00000000-0000-4000-8000-000000000006"
let oldEpoch = "00000000-0000-4000-8000-000000000007"
let fakeKey = Data(repeating: 0x35, count: 32)
let now = Date(timeIntervalSince1970: 1_800_000_000)
let record = try PeelICloudHostRecord(hostID: hostID, enrollmentID: epoch, displayName: "Test Mac",
    endpointHost: "100.90.1.2", controlPort: 49752, pairingPort: 49753, bootstrapSecret: fakeKey, updatedAt: now)

func request(id: String = requestID, device: String = deviceID, name: String = "Test Phone", enrollment: String = epoch) -> PeelICloudPairRequest {
    PeelICloudPairRequest(hostID: hostID, enrollmentID: enrollment, requestID: id,
        clientDeviceID: device, clientName: name)
}
func peer(id: String = pairingID, device: String = deviceID, enrollment: String? = epoch,
          remoteHost: String? = nil) -> PeelPairedPeer {
    PeelPairedPeer(id: id, displayName: "Test Phone", serviceName: device, stableHostId: remoteHost,
        iCloudEnrollmentID: enrollment)
}
func rejection(_ req: PeelICloudPairRequest = request(), peers: [PeelPairedPeer] = [], blocked: Set<String> = []) -> String? {
    PeelICloudHostEnrollmentPolicy.rejection(for: req, record: record, peers: peers, blockedDeviceIDs: blocked,
        ownedEnrollmentIDs: [epoch, oldEpoch])
}

expect(rejection() == nil, "new valid device can enroll")
expect(rejection(blocked: [deviceID.lowercased()]) != nil, "Host-revoked installation is blocked case-insensitively")
expect(rejection(request(enrollment: oldEpoch)) != nil, "old bootstrap epoch cannot enroll")
expect(rejection(request(device: "not-a-uuid")) != nil, "untrusted installation identity rejected")
expect(rejection(request(name: "Phone\nControl")) != nil, "control characters rejected")
expect(rejection(peers: [peer(enrollment: nil)]) != nil, "manual pairing is never replaced")
expect(rejection(peers: [peer()]) != nil, "installation label cannot export an existing cloud key")
expect(rejection(peers: [peer(enrollment: oldEpoch)]) != nil, "old cloud pairing is not silently replaced")
expect(rejection(peers: [peer(device: deviceID.lowercased(), enrollment: nil)]) != nil, "case variation cannot replace manual pair")
expect(rejection(peers: [peer(device: otherDevice)]) == nil, "different installation receives separate pairing")
let full = (0..<32).map { _ in peer(id: UUID().uuidString, device: UUID().uuidString) }
expect(rejection(peers: full) != nil, "bounded account trust count")
expect(rejection(peers: Array(full.prefix(31))) == nil, "last account device slot available")
let outbound = full.map { peer(id: $0.id, device: $0.serviceName!, remoteHost: otherDevice) }
expect(rejection(peers: outbound) == nil, "outbound Mac receiver pairs do not consume this Host's enrollment slots")

let owned: Set<String> = [epoch, oldEpoch]
expect(PeelICloudHostEnrollmentPolicy.isLocallyIssued(peer(), ownedEnrollmentIDs: owned), "current own inbound epoch eligible for rotation")
expect(PeelICloudHostEnrollmentPolicy.isLocallyIssued(peer(enrollment: oldEpoch), ownedEnrollmentIDs: owned), "older own inbound epoch eligible for rotation")
expect(!PeelICloudHostEnrollmentPolicy.isLocallyIssued(peer(enrollment: nil), ownedEnrollmentIDs: owned), "rotation preserves code pairings")
expect(!PeelICloudHostEnrollmentPolicy.isLocallyIssued(peer(enrollment: UUID().uuidString), ownedEnrollmentIDs: owned), "rotation preserves foreign epoch")
expect(!PeelICloudHostEnrollmentPolicy.isLocallyIssued(peer(remoteHost: otherDevice), ownedEnrollmentIDs: owned), "rotation preserves outbound Mac receiver even with epoch collision")

let accepted = PeelICloudPairResponse(hostID: hostID, enrollmentID: epoch, requestID: requestID,
    hostName: "Test Mac", accepted: true, pairingID: pairingID, psk: fakeKey)
var cache = PeelICloudHostEnrollmentRetryCache()
cache.insert(request: request(), response: accepted, now: now)
func lookup(_ req: PeelICloudPairRequest = request(), peers: [PeelPairedPeer] = [peer()],
            blocked: Set<String> = [], time: Date = now, key: Data? = fakeKey) -> PeelICloudPairResponse? {
    cache.response(for: req, record: record, peers: peers, blockedDeviceIDs: blocked,
        now: time, keyForPairing: { _ in key })
}
expect(cache.count == 1, "only successful response enters retry cache")
expect(lookup()?.pairingID == pairingID, "same request may retry without creating/replacing trust")
expect(lookup(request(id: UUID().uuidString)) == nil, "new requestID cannot export existing key")
expect(lookup(request(device: otherDevice)) == nil, "different installation cannot reuse requestID")
expect(lookup(request(name: "Renamed Phone")) == nil, "changed tuple cannot reuse requestID")
expect(lookup(request(enrollment: oldEpoch)) == nil, "old enrollment cannot reuse requestID")
expect(lookup(peers: []) == nil, "removed peer invalidates response")
expect(lookup(peers: [peer(enrollment: oldEpoch)]) == nil, "changed trust epoch invalidates response")
expect(lookup(peers: [peer(device: otherDevice)]) == nil, "changed peer association invalidates response")
expect(lookup(peers: [peer(remoteHost: otherDevice)]) == nil, "outbound peer cannot satisfy retry")
expect(lookup(blocked: [deviceID.lowercased()]) == nil, "revocation blocks cached retry")
expect(lookup(key: nil) == nil, "deleted local key invalidates response")
expect(lookup(key: Data(repeating: 0x36, count: 32)) == nil, "replaced local key invalidates response")
expect(lookup(time: now.addingTimeInterval(299)) != nil, "bounded retry window available")
expect(lookup(time: now.addingTimeInterval(300)) == nil, "retry expires at five minutes")
expect(cache.count == 0, "expired credential material is dropped on next access")
cache.insert(request: request(), response: accepted, now: now)
cache.remove(pairingID: pairingID)
expect(cache.count == 0, "explicit peer revoke clears its cached key")
for index in 0..<33 {
    let id = UUID().uuidString
    let req = request(id: id, device: UUID().uuidString)
    let response = PeelICloudPairResponse(hostID: hostID, enrollmentID: epoch, requestID: id,
        hostName: "Test Mac", accepted: true, pairingID: UUID().uuidString, psk: fakeKey)
    cache.insert(request: req, response: response, now: now.addingTimeInterval(Double(index)))
}
expect(cache.count == 32, "retry secrets bounded to 32")
cache.removeAll()
expect(cache.count == 0, "disable/rotation clears all cached response keys")
let rejected = PeelICloudPairResponse(hostID: hostID, enrollmentID: epoch, requestID: requestID,
    hostName: "Test Mac", accepted: false, reason: "Not approved.")
cache.insert(request: request(), response: rejected, now: now)
expect(cache.count == 0, "denied requests do not retain credentials")
print("PASS: \(checks) Host account-enrollment policy and retry-cache checks (no Keychain/network access)")
