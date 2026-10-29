import Foundation

let suite = "peel-direct-port-checks.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
for input in ["", "0", "65536", "-1", "+80", "1.5", "１２３", "1 2", "123456"] {
    precondition(PeelDirectConnectionSettings.parsePort(input) == nil, input)
}
precondition(PeelDirectConnectionSettings.parsePort(" 49752\n") == 49752)
precondition(PeelDirectConnectionSettings.parsePort("65535") == 65535)
precondition(PeelDirectConnectionSettings.preferredPort(defaults: defaults) == nil)
PeelDirectConnectionSettings.setPreferredPort(49752, defaults: defaults)
precondition(PeelDirectConnectionSettings.preferredPort(defaults: defaults) == 49752)
PeelDirectConnectionSettings.setPreferredPort(nil, defaults: defaults)
precondition(defaults.object(forKey: PeelDirectConnectionSettings.defaultsKey) == nil)
defaults.set("corrupt", forKey: PeelDirectConnectionSettings.defaultsKey)
precondition(PeelDirectConnectionSettings.preferredPort(defaults: defaults) == nil)
print("PeelDirectConnectionSettings: PASS")
