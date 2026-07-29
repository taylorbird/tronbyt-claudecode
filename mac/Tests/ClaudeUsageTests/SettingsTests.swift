import XCTest
@testable import ClaudeUsage

@MainActor
final class AppSettingsTests: XCTestCase {

    /// Isolated so tests never touch the real app's stored configuration.
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var service: String!

    override func setUp() {
        super.setUp()
        suiteName = "ClaudeUsageTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        service = "com.tbird.ClaudeUsage.test.\(UUID().uuidString)"
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? AppSettings.storeAPIKey("", service: service)   // clears the Keychain item
        super.tearDown()
    }

    private func makeAppSettings() -> AppSettings {
        AppSettings(defaults: defaults, keychainService: service)
    }

    func testDefaultsAreEmptyExceptInstallationID() {
        let settings = makeAppSettings()
        XCTAssertEqual(settings.baseURL, "")
        XCTAssertEqual(settings.deviceID, "")
        // Matches render_push.sh's default so an existing device keeps its slot
        // instead of gaining a second installation.
        XCTAssertEqual(settings.installationID, "claudeusage")
    }

    func testNonSecretFieldsRoundTripThroughUserDefaults() {
        let first = makeAppSettings()
        first.baseURL = "http://10.0.0.5:8100"
        first.deviceID = "my-device"
        first.installationID = "custom"

        let second = makeAppSettings()
        XCTAssertEqual(second.baseURL, "http://10.0.0.5:8100")
        XCTAssertEqual(second.deviceID, "my-device")
        XCTAssertEqual(second.installationID, "custom")
    }

    /// The API key must NOT land in UserDefaults — that is a plaintext plist, which
    /// is exactly the exposure this replaces.
    func testApiKeyIsNotWrittenToUserDefaults() {
        let settings = makeAppSettings()
        settings.apiKey = "super-secret"
        let dump = defaults.dictionaryRepresentation()
        for (key, value) in dump {
            XCTAssertFalse("\(value)".contains("super-secret"),
                           "API key leaked into UserDefaults under \(key)")
        }
    }

    func testApiKeyRoundTripsThroughTheKeychain() throws {
        let first = makeAppSettings()
        first.apiKey = "secret-abc"
        let second = makeAppSettings()
        XCTAssertEqual(second.apiKey, "secret-abc")
    }

    func testClearingTheApiKeyRemovesTheStoredItem() throws {
        let settings = makeAppSettings()
        settings.apiKey = "to-be-removed"
        settings.apiKey = ""
        XCTAssertEqual(try AppSettings.loadAPIKey(service: service), "")
    }

    func testOverwritingTheApiKeyReplacesRatherThanDuplicates() throws {
        let settings = makeAppSettings()
        settings.apiKey = "first"
        settings.apiKey = "second"
        XCTAssertEqual(try AppSettings.loadAPIKey(service: service), "second")
    }

    func testMissingKeychainItemReadsAsEmptyNotAnError() throws {
        XCTAssertEqual(try AppSettings.loadAPIKey(service: "com.tbird.absent.\(UUID())"), "")
    }

    func testConfigAssemblesAllFields() {
        let settings = makeAppSettings()
        settings.baseURL = "http://host:8100"
        settings.deviceID = "dev"
        settings.installationID = "inst"
        settings.apiKey = "key"
        XCTAssertEqual(settings.config,
                       TronbytConfig(baseURL: "http://host:8100", deviceID: "dev",
                                     installationID: "inst", apiKey: "key"))
        XCTAssertTrue(settings.config.isConfigured)
    }

    func testUnconfiguredUntilTheRequiredFieldsArePresent() {
        let settings = makeAppSettings()
        XCTAssertFalse(settings.config.isConfigured)
        settings.baseURL = "http://host:8100"
        settings.deviceID = "dev"
        XCTAssertFalse(settings.config.isConfigured, "still needs an API key")
        settings.apiKey = "key"
        XCTAssertTrue(settings.config.isConfigured)
    }
}
