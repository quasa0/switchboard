import Foundation
import XCTest
@testable import SwitchboardCore

final class ModelsTests: RepositoryTestCase {
    func testPlanNamesAreDerivedFromRateLimitTier() throws {
        XCTAssertEqual(try snapshot().validated().0.plan, "Max 20×")
        XCTAssertEqual(try snapshot(tier: "default_claude_max_5x").validated().0.plan, "Max 5×")
        XCTAssertEqual(try snapshot(tier: "unknown-new-tier").validated().0.plan, "Max")
    }

    func testRejectsEmptyTokenMissingInferenceScopeAndEmptyIdentity() throws {
        let valid = try snapshot()
        for replacement: [String: Any] in [["accessToken": ""], ["scopes": ["user:profile"]]] {
            var oauth = try jsonObject(valid.oauth)
            oauth.merge(replacement) { _, new in new }
            let invalid = try CredentialSnapshot(oauth: jsonData(oauth), identity: valid.identity)
            XCTAssertThrowsError(try invalid.validated())
        }
        for field in ["accountUuid", "emailAddress"] {
            var identity = try jsonObject(valid.identity)
            identity[field] = ""
            let invalid = try CredentialSnapshot(oauth: valid.oauth, identity: jsonData(identity))
            XCTAssertThrowsError(try invalid.validated())
        }
    }

    func testMissingOptionalIdentityOrganizationAndPlanHaveStableDefaults() throws {
        let valid = try snapshot()
        var oauth = try jsonObject(valid.oauth)
        oauth.removeValue(forKey: "rateLimitTier")
        oauth.removeValue(forKey: "subscriptionType")
        var identity = try jsonObject(valid.identity)
        identity.removeValue(forKey: "organizationUuid")
        let (login, _) = try CredentialSnapshot(oauth: jsonData(oauth), identity: jsonData(identity)).validated()
        XCTAssertEqual(login.organizationUUID, "")
        XCTAssertEqual(login.plan, "Claude")
    }

    func testRefreshIsNeededForExpiredOrMissingExpiryButNotFutureToken() throws {
        var oauth = try jsonObject(snapshot().oauth)
        XCTAssertFalse(try JSONDecoder().decode(OAuthCredential.self, from: jsonData(oauth)).needsRefresh)
        oauth["expiresAt"] = 1_000.0
        XCTAssertTrue(try JSONDecoder().decode(OAuthCredential.self, from: jsonData(oauth)).needsRefresh)
        oauth.removeValue(forKey: "expiresAt")
        XCTAssertTrue(try JSONDecoder().decode(OAuthCredential.self, from: jsonData(oauth)).needsRefresh)
    }

    func testUsageFractionsClampToDisplayRange() {
        XCTAssertEqual(UsageWindow(utilization: -5, resetsAt: nil).fraction, 0)
        XCTAssertEqual(UsageWindow(utilization: 37, resetsAt: nil).fraction, 0.37, accuracy: 0.0001)
        XCTAssertEqual(UsageWindow(utilization: 175, resetsAt: nil).fraction, 1)
    }
}
