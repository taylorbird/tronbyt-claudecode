import Foundation
import Security

/// A Claude Code OAuth credential. We only ever read one — renewal is Claude
/// Code's job, which is the entire reason this app runs on the Mac. See the design
/// doc: refreshing it ourselves is what made the off-Mac deployment unworkable.
struct Credential: Equatable {
    let accessToken: String
    /// Absolute expiry, or nil when the stored credential omits it.
    let expiresAt: Date?

    func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

enum CredentialError: Error, CustomStringConvertible {
    case notFound
    case accessDenied(OSStatus)
    case keychainError(OSStatus)
    case notJSON
    case noAccessToken

    var description: String {
        switch self {
        case .notFound:
            return "no Claude Code credential in the Keychain — is Claude Code logged in?"
        case .accessDenied:
            return "Keychain access denied — approve the prompt, or re-run and choose Always Allow"
        case let .keychainError(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "Keychain read failed (\(status)): \(message)"
        case .notJSON:
            return "Keychain item was not JSON"
        case .noAccessToken:
            return "credential JSON has no accessToken"
        }
    }
}

enum CredentialReader {

    /// The Keychain item Claude Code stores its OAuth credential in.
    static let service = "Claude Code-credentials"

    /// Read and parse the credential. The item belongs to Claude Code, so the
    /// first read triggers a macOS consent prompt; "Always Allow" makes it
    /// persistent for this signing identity.
    static func read(service: String = Self.service) throws -> Credential {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw CredentialError.notJSON }
            return try parse(data)
        case errSecItemNotFound:
            throw CredentialError.notFound
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            throw CredentialError.accessDenied(status)
        default:
            throw CredentialError.keychainError(status)
        }
    }

    /// Accepts both the nested shape Claude Code writes and a flat one.
    static func parse(_ data: Data) throws -> Credential {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any] else {
            throw CredentialError.notJSON
        }
        let oauth = (object["claudeAiOauth"] as? [String: Any]) ?? object
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw CredentialError.noAccessToken
        }
        return Credential(accessToken: token, expiresAt: expiry(from: oauth["expiresAt"]))
    }

    /// `expiresAt` is epoch MILLISECONDS. Treating it as seconds puts expiry in
    /// the year 58500 and the token never looks stale — a silent trap, so it is
    /// converted in exactly one place and pinned by a test.
    private static func expiry(from value: Any?) -> Date? {
        guard let milliseconds = (value as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
