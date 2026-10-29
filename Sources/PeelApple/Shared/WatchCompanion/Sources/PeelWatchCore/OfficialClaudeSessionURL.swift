import Foundation

/// Validates a handoff link only. Opening a link neither connects Peel to Claude
/// nor grants permission to control a remote Claude Code session.
public enum OfficialClaudeSessionURL {
    public static func validated(_ rawValue: String) throws -> URL {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 2_048,
              !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "claude.ai",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              !components.percentEncodedPath.contains("%"),
              isCodePath(components.path),
              let url = components.url else {
            throw CompanionValidationError.invalidSessionURL
        }
        return url
    }

    private static func isCodePath(_ path: String) -> Bool {
        if path == "/code" || path == "/code/" { return true }
        guard path.hasPrefix("/code/") else { return false }
        let suffix = path.dropFirst("/code/".count)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return suffix.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { segment in
            !segment.isEmpty && segment.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }
}
