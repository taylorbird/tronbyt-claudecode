import Foundation
import Observation
import Security

/// Persisted configuration.
///
/// Non-secret fields live in UserDefaults; the API key lives in the Keychain. The
/// launchd setup this replaces kept the key in cleartext inside a plist, which is
/// how it ended up pasted into a chat transcript.
@MainActor
@Observable
final class Settings {

    private enum Key {
        static let baseURL = "tronbytBaseURL"
        static let deviceID = "tronbytDeviceID"
        static let installationID = "tronbytInstallationID"
    }

    /// Keychain service for our own item — distinct from Claude Code's.
    /// `nonisolated` so it can be used as a default argument, which is evaluated
    /// outside the main actor.
    nonisolated static let keychainService = "com.tbird.ClaudeUsage.tronbytAPIKey"

    private let defaults: UserDefaults
    private let keychainService: String

    var baseURL: String {
        didSet { defaults.set(baseURL, forKey: Key.baseURL) }
    }
    var deviceID: String {
        didSet { defaults.set(deviceID, forKey: Key.deviceID) }
    }
    var installationID: String {
        didSet { defaults.set(installationID, forKey: Key.installationID) }
    }
    /// Written through to the Keychain on assignment.
    var apiKey: String {
        didSet { try? Self.storeAPIKey(apiKey, service: keychainService) }
    }

    init(defaults: UserDefaults = .standard, keychainService: String = Settings.keychainService) {
        self.defaults = defaults
        self.keychainService = keychainService
        self.baseURL = defaults.string(forKey: Key.baseURL) ?? ""
        self.deviceID = defaults.string(forKey: Key.deviceID) ?? ""
        // Matches the default in render_push.sh, so an existing device keeps its
        // rotation slot rather than gaining a second one.
        self.installationID = defaults.string(forKey: Key.installationID) ?? "claudeusage"
        self.apiKey = (try? Self.loadAPIKey(service: keychainService)) ?? ""
    }

    var config: TronbytConfig {
        TronbytConfig(baseURL: baseURL, deviceID: deviceID,
                      installationID: installationID, apiKey: apiKey)
    }

    // MARK: Keychain

    nonisolated static func storeAPIKey(_ key: String, service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }   // clearing the field clears the item
        var insert = query
        insert[kSecValueData as String] = Data(key.utf8)
        // Available once unlocked after boot: the app runs at login, and the frame
        // pusher must work without anyone typing a password.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw SettingsError.keychain(status) }
    }

    nonisolated static func loadAPIKey(service: String) throws -> String {
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
            guard let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
                throw SettingsError.malformed
            }
            return text
        case errSecItemNotFound:
            return ""
        default:
            throw SettingsError.keychain(status)
        }
    }
}

enum SettingsError: Error, CustomStringConvertible {
    case keychain(OSStatus)
    case malformed

    var description: String {
        switch self {
        case let .keychain(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "Keychain error \(status): \(message)"
        case .malformed:
            return "stored API key was not readable text"
        }
    }
}
