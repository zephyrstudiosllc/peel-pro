import Foundation

/// Internal metadata policy only; not a credential, authority or wake interface.
/// Exactly one serialized owner must own the dedicated directory and store.
protocol PluginRelayPhoneFileProtection: Sendable {
    func establish(at url: URL) throws
    func verify(at url: URL) throws
}

#if os(iOS)
/// Phone-only storage for background relay messages after first unlock. Other
/// stores retain their existing policy and no credential accessibility changes.
struct PluginRelayIOSPhoneFileProtection: PluginRelayPhoneFileProtection {
    func establish(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
        try verify(at: url)
    }

    func verify(at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let value = attributes[.protectionKey]
        let raw = (value as? FileProtectionType)?.rawValue ?? (value as? String)
        guard raw == FileProtectionType.completeUntilFirstUserAuthentication.rawValue else {
            throw PluginRelayError.storageFailure
        }
    }
}
#endif
