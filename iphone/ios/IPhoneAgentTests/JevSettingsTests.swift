import XCTest
@testable import IPhoneAgent

/// These tests keep credentials in memory and settings in an isolated defaults suite.
/// They never write to the install's LLM or Jev Keychain items.
@MainActor final class JevSettingsTests: XCTestCase {
    private final class Credentials {
        var key = ""
        var store: JevCredentialStore {
            JevCredentialStore(load: { self.key }, save: { self.key = $0 })
        }
    }

    private func isolatedDefaults() -> (String, UserDefaults) {
        let name = "jev-settings-" + UUID().uuidString
        return (name, UserDefaults(suiteName: name)!)
    }

    func testExecutorStartsDisabledAndDoesNotRequireCredentials() throws {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let credentials = Credentials()
        let settings = Settings(defaults: defaults, info: [:], jevCredentials: credentials.store)

        XCTAssertFalse(settings.jevEnabled)
        XCTAssertEqual(settings.jevModel, "jev-latest")
        XCTAssertEqual(settings.jevMinConfidence, 0.85)
        XCTAssertNil(try settings.jevClient())
        XCTAssertFalse(settings.predictiveBatch)
    }

    func testPredictiveModePersistsWithoutAnyTypeSafeCredential() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let credentials = Credentials()
        let settings = Settings(defaults: defaults, info: [:], jevCredentials: credentials.store)
        let revision = settings.configurationRevision
        settings.predictiveBatch = true
        XCTAssertGreaterThan(settings.configurationRevision, revision)
        let reopened = Settings(defaults: defaults, info: [:], jevCredentials: credentials.store)
        XCTAssertTrue(reopened.predictiveBatch)
        XCTAssertFalse(reopened.jevEnabled)
        XCTAssertTrue(SettingsBackup.keys.contains("predictiveBatch"))
    }

    func testJevSetupSurvivesReloadWithoutChangingTheVisionProvider() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("deepSeek", forKey: "modelProvider")
        defaults.set("https://api.deepseek.com", forKey: "baseURL")
        defaults.set("deepseek-flash", forKey: "model")
        let credentials = Credentials()
        let settings = Settings(defaults: defaults, info: [:], jevCredentials: credentials.store)

        settings.jevEnabled = true
        settings.jevModel = "jev-1.14.0"
        settings.jevMinConfidence = 0.92
        settings.jevAPIKey = "isolated-jev-secret"

        let reopened = Settings(defaults: defaults, info: [:], jevCredentials: credentials.store)
        XCTAssertTrue(reopened.jevEnabled)
        XCTAssertEqual(reopened.jevModel, "jev-1.14.0")
        XCTAssertEqual(reopened.jevMinConfidence, 0.92)
        XCTAssertEqual(reopened.jevAPIKey, "isolated-jev-secret")
        XCTAssertEqual(reopened.provider, .deepSeek)
        XCTAssertEqual(reopened.baseURL, "https://api.deepseek.com")
        XCTAssertEqual(reopened.model, "deepseek-flash")
    }

    func testCredentialNeverEntersDefaultsOrConfigurationBackup() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let credentials = Credentials()
        let settings = Settings(defaults: defaults, info: [:], jevCredentials: credentials.store)

        settings.jevAPIKey = "memory-only-jev-secret-972"
        XCTAssertEqual(credentials.key, "memory-only-jev-secret-972")
        XCTAssertNil(defaults.object(forKey: "jevAPIKey"))
        XCTAssertNil(defaults.object(forKey: "jev-api-key"))
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains(credentials.key))
        XCTAssertFalse(SettingsBackup.keys.contains("jevAPIKey"))
        XCTAssertFalse(SettingsBackup.keys.contains("jev-api-key"))
        XCTAssertTrue(SettingsBackup.keys.contains("jevEnabled"))
        XCTAssertTrue(SettingsBackup.keys.contains("jevModel"))
        XCTAssertTrue(SettingsBackup.keys.contains("jevMinConfidence"))
    }

    func testEnabledExecutorRejectsIncompleteSetupBeforeCreatingAClient() throws {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let credentials = Credentials()
        let settings = Settings(defaults: defaults, info: [:], jevCredentials: credentials.store)
        settings.jevEnabled = true

        settings.jevAPIKey = " \n "
        XCTAssertThrowsError(try settings.jevClient())
        settings.jevAPIKey = "  isolated-test-key  "
        settings.jevModel = " \n "
        XCTAssertThrowsError(try settings.jevClient())
        settings.jevModel = "  jev-latest  "
        XCTAssertNotNil(try settings.jevClient()) // no request is made by constructing the client
    }

    func testDecisionThresholdCannotDisableValidationWithOutOfRangeOrNaNValues() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let credentials = Credentials()
        let settings = Settings(defaults: defaults, info: [:], jevCredentials: credentials.store)

        settings.jevMinConfidence = -1
        XCTAssertEqual(settings.jevMinConfidence, 0.5)
        settings.jevMinConfidence = 1.5
        XCTAssertEqual(settings.jevMinConfidence, 0.99)
        settings.jevMinConfidence = .nan
        XCTAssertEqual(settings.jevMinConfidence, Settings.jevDefaultMinConfidence)
        let reopened = Settings(defaults: defaults, info: [:], jevCredentials: credentials.store)
        XCTAssertEqual(reopened.jevMinConfidence, Settings.jevDefaultMinConfidence)
    }

    func testExecutorChangesInvalidateTheCurrentConfiguration() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let credentials = Credentials()
        let settings = Settings(defaults: defaults, info: [:], jevCredentials: credentials.store)
        var revision = settings.configurationRevision

        settings.jevEnabled = true
        XCTAssertGreaterThan(settings.configurationRevision, revision)
        revision = settings.configurationRevision
        settings.jevModel = "jev-1.14.0"
        XCTAssertGreaterThan(settings.configurationRevision, revision)
        revision = settings.configurationRevision
        settings.jevAPIKey = "isolated-revision-test-key"
        XCTAssertGreaterThan(settings.configurationRevision, revision)
        revision = settings.configurationRevision
        settings.jevMinConfidence = 0.95
        XCTAssertGreaterThan(settings.configurationRevision, revision)
    }

    func testJevUsageKeepsItsProviderEvenWhenThePlannerUsesACustomEndpoint() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let credentials = Credentials()
        let settings = Settings(defaults: defaults, info: [:], jevCredentials: credentials.store)
        let call = ModelCall(role: "jev", model: "jev-latest", reply: nil, error: nil, imageKB: 12)

        let props = settings.analyticsModel(call)
        XCTAssertEqual(props["provider"] as? String, "typesafe")
        XCTAssertEqual(props["model"] as? String, "jev-latest")
        XCTAssertEqual(props["role"] as? String, "jev")
        XCTAssertNil(props["baseURL"])
        XCTAssertNil(props["apiKey"])
    }
}
