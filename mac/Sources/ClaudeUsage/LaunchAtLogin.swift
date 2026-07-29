import Foundation
import ServiceManagement

/// Start-at-login, via SMAppService — the supported route since macOS 13. No
/// helper bundle, no launchd plist to install, and the user can always override it
/// in System Settings → General → Login Items.
///
/// Requires the app to live somewhere stable: registering a copy in a build
/// directory produces a login item that breaks the next time that directory is
/// cleaned, which is precisely how the launchd setup this replaces became fragile.
@MainActor
enum LaunchAtLogin {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when the app is running from a location a login item can rely on.
    static var isInStableLocation: Bool {
        let path = Bundle.main.bundleURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix("\(NSHomeDirectory())/Applications/")
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Human-readable state for the settings pane.
    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:        return "on"
        case .notRegistered:  return "off"
        case .requiresApproval:
            return "needs approval in System Settings → Login Items"
        case .notFound:       return "unavailable"
        @unknown default:     return "unknown"
        }
    }
}
