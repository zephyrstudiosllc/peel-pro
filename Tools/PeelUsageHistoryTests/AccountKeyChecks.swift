import Foundation

@main
struct AccountKeyChecks {
    static func main() throws {
        let key = DashboardIdentityPayload.historyAccountKey(providerID: "codex", email: "first@example.test")!
        precondition(key == DashboardIdentityPayload.historyAccountKey(providerID: "codex", email: " FIRST@example.test "))
        precondition(key != DashboardIdentityPayload.historyAccountKey(providerID: "codex", email: "second@example.test"))
        precondition(key != DashboardIdentityPayload.historyAccountKey(providerID: "cursor", email: "first@example.test"))
        for invalid: String? in [nil, "", "no-identity", "redacted@example.test", "@example.test", "user@"] {
            precondition(DashboardIdentityPayload.historyAccountKey(providerID: "codex", email: invalid) == nil)
        }
        let accountIDKey = DashboardIdentityPayload.historyAccountKey(providerID: "codex", email: nil,
            accountID: "account-a", organization: "org-a")!
        precondition(accountIDKey != DashboardIdentityPayload.historyAccountKey(providerID: "codex", email: nil,
            accountID: "account-a", organization: "org-b"))
        precondition(accountIDKey != DashboardIdentityPayload.historyAccountKey(providerID: "codex", email: nil,
            accountID: "account-b", organization: "org-a"))
        precondition(accountIDKey == DashboardIdentityPayload.historyAccountKey(providerID: "codex",
            email: "changed@example.test", accountID: "account-a", organization: "org-a"))
        precondition(key != DashboardIdentityPayload.historyAccountKey(providerID: "codex",
            email: "first@example.test", organization: "org-a"))
        let payload = DashboardIdentityPayload(accountEmail: "redacted@example.test", plan: "Plan", accountKey: key)
        let data = try JSONEncoder().encode(payload)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: String]
        precondition(object["accountKey"] == key)
        precondition(object["accountEmail"] == "redacted@example.test")
        precondition(!String(data: data, encoding: .utf8)!.contains("first@example.test"))
        let legacy = try JSONEncoder().encode(DashboardIdentityPayload(accountEmail: nil, plan: "Plan"))
        let legacyObject = try JSONSerialization.jsonObject(with: legacy) as! [String: Any]
        precondition(!legacyObject.keys.contains("accountKey"))
        print("Opaque dashboard account identity checks passed: stable normalization, account/provider separation, absent identity and redaction")
    }
}
