import XCTest
@testable import IPhoneAgent

/// Use a separate preferences domain and explicit store mode; never change the
/// real install's agreements or depend on its App Store build setting.
final class AIConsentTests: XCTestCase {
    private var defaults: UserDefaults!
    private var domain: String!

    override func setUp() {
        super.setUp()
        domain = "ai-consent-test-" + UUID().uuidString
        defaults = UserDefaults(suiteName: domain)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: domain)
        defaults = nil
        domain = nil
        super.tearDown()
    }

    func testPlannerAndJevHaveIndependentAgreements() {
        let planner = "https://api.deepseek.com/v1"
        let jev = "https://api.typesafe.ai"
        XCTAssertFalse(AIConsent.granted(planner, defaults: defaults, storeBuild: true))
        AIConsent.grant(planner, defaults: defaults)
        XCTAssertTrue(AIConsent.granted(planner, defaults: defaults, storeBuild: true))
        XCTAssertFalse(AIConsent.granted(jev, defaults: defaults, storeBuild: true))
        AIConsent.grant(jev, defaults: defaults)
        XCTAssertTrue(AIConsent.granted(planner, defaults: defaults, storeBuild: true))
        XCTAssertTrue(AIConsent.granted(jev, defaults: defaults, storeBuild: true))
        XCTAssertEqual(AIConsent.allowedHosts(defaults: defaults), ["api.deepseek.com", "api.typesafe.ai"])
    }

    func testLegacyAgreementSurvivesMigrationWithoutGrantingJev() {
        defaults.set("api.deepseek.com", forKey: AIConsent.key)
        XCTAssertTrue(AIConsent.granted("https://api.deepseek.com", defaults: defaults, storeBuild: true))
        XCTAssertFalse(AIConsent.granted("https://api.typesafe.ai", defaults: defaults, storeBuild: true))
        AIConsent.grant("https://api.typesafe.ai/v1", defaults: defaults)
        XCTAssertNil(defaults.object(forKey: AIConsent.key))
        XCTAssertEqual(defaults.stringArray(forKey: AIConsent.hostsKey), ["api.deepseek.com", "api.typesafe.ai"])
        XCTAssertTrue(AIConsent.granted("https://api.deepseek.com", defaults: defaults, storeBuild: true))
    }

    func testRevokingOneHostKeepsTheOther() {
        AIConsent.grant("https://api.deepseek.com", defaults: defaults)
        AIConsent.grant("https://api.typesafe.ai", defaults: defaults)
        AIConsent.revoke("https://api.typesafe.ai/v1", defaults: defaults)
        XCTAssertFalse(AIConsent.granted("https://api.typesafe.ai", defaults: defaults, storeBuild: true))
        XCTAssertTrue(AIConsent.granted("https://api.deepseek.com", defaults: defaults, storeBuild: true))
    }

    func testWithdrawClearsBothStorageFormats() {
        defaults.set("legacy.example", forKey: AIConsent.key)
        defaults.set(["api.typesafe.ai"], forKey: AIConsent.hostsKey)
        AIConsent.revoke(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: AIConsent.key))
        XCTAssertNil(defaults.object(forKey: AIConsent.hostsKey))
        XCTAssertTrue(AIConsent.allowedHosts(defaults: defaults).isEmpty)
        XCTAssertThrowsError(try AIConsent.check("https://api.typesafe.ai", defaults: defaults, storeBuild: true))
    }

    func testSourceBuildBypassDoesNotPersistOrGrantStorePermission() throws {
        try AIConsent.check("https://api.typesafe.ai", defaults: defaults, storeBuild: false)
        XCTAssertTrue(AIConsent.allowedHosts(defaults: defaults).isEmpty)
        XCTAssertFalse(AIConsent.granted("https://api.typesafe.ai", defaults: defaults, storeBuild: true))
    }

    func testHostsAreCanonicalAndGrantDoesNotAllowAnotherDomain() {
        AIConsent.grant(" https://API.TypeSafe.AI/v1/systemone ", defaults: defaults)
        AIConsent.grant("https://api.typesafe.ai", defaults: defaults)
        XCTAssertEqual(AIConsent.allowedHosts(defaults: defaults), ["api.typesafe.ai"])
        XCTAssertFalse(AIConsent.granted("https://not-typesafe.ai", defaults: defaults, storeBuild: true))
        XCTAssertNoThrow(try AIConsent.check("https://api.typesafe.ai/other", defaults: defaults, storeBuild: true))
    }

    func testRevokingLegacyHostDoesNotRestoreIt() {
        defaults.set("api.deepseek.com", forKey: AIConsent.key)
        AIConsent.revoke("https://api.deepseek.com", defaults: defaults)
        XCTAssertNil(defaults.object(forKey: AIConsent.key))
        XCTAssertEqual(defaults.stringArray(forKey: AIConsent.hostsKey), [])
        XCTAssertFalse(AIConsent.granted("https://api.deepseek.com", defaults: defaults, storeBuild: true))
    }
}
