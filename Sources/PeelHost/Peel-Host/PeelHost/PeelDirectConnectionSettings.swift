import Foundation

/// An optional fixed TLS listener port. Existing installations retain automatic
/// allocation until the user explicitly saves a port in Direct Connections.
nonisolated enum PeelDirectConnectionSettings {
    static let defaultsKey = "PeelHost.directConnectionPort"

    static func parsePort(_ text: String) -> UInt16? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 5,
              value.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = UInt16(value), port != 0 else { return nil }
        return port
    }

    static func preferredPort(defaults: UserDefaults = .standard) -> UInt16? {
        guard let raw = defaults.string(forKey: defaultsKey) else { return nil }
        return parsePort(raw)
    }

    static func setPreferredPort(_ port: UInt16?, defaults: UserDefaults = .standard) {
        if let port, port != 0 {
            defaults.set(String(port), forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }
}
