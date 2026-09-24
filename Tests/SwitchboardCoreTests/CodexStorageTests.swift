import Foundation
import XCTest
@testable import SwitchboardCore

class CodexTestCase: XCTestCase {
    var root: URL!
    var installation: CodexInstallation!
    var secrets: MemorySecretStore!
    var repository: CodexAccountRepository!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SwitchboardCodexTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        installation = CodexInstallation(home: root.appendingPathComponent("user"), environment: [:])
        secrets = MemorySecretStore()
        repository = CodexAccountRepository(directory: root.appendingPathComponent("saved"), secrets: secrets, installation: installation)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func snapshot(_ user: String = "a", workspace: String? = nil, token: String = "original", refreshed: String = "2026-09-24T09:00:00Z") throws -> CodexCredentialSnapshot {
        let claims: [String: Any] = ["email": "\(user)@example.test", "sub": "user-\(user)",
            "https://api.openai.com/auth": ["chatgpt_user_id": "user-\(user)", "chatgpt_account_id": workspace ?? "workspace-\(user)", "chatgpt_plan_type": "pro"]]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let object: [String: Any] = ["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(), "last_refresh": refreshed,
            "tokens": ["id_token": "header.\(payload).signature", "access_token": "synthetic-\(user)-\(token)", "refresh_token": "synthetic-refresh-\(user)-\(token)", "account_id": workspace ?? "workspace-\(user)", "future_token_field": true],
            "future_field": ["must_survive": "猫"]]
        return CodexCredentialSnapshot(authJSON: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
    func seed(_ snapshot: CodexCredentialSnapshot) throws { try privateWrite(snapshot.authJSON, to: installation.authFile) }
}

final class CodexStorageTests: CodexTestCase {
    func testIdentityAndFullPayloadSurviveAtomicSwitch() throws {
        let first = try snapshot(), second = try snapshot("b")
        try seed(first)
        try privateWrite(Data("model = \"example\"\n".utf8), to: installation.configFile)
        let originalConfig = try Data(contentsOf: installation.configFile)
        try repository.live.apply(second, ifUnchangedFrom: first)
        XCTAssertEqual(try repository.live.snapshot(), second)
        XCTAssertEqual(try second.validated(), CurrentLogin(email: "b@example.test", accountUUID: "user-b", organizationUUID: "workspace-b", plan: "Pro"))
        XCTAssertEqual(try Data(contentsOf: installation.configFile), originalConfig)
        let attributes = try FileManager.default.attributesOfItem(atPath: installation.authFile.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testRejectsChangedLiveCredentialBeforeAtomicReplacement() throws {
        let first = try snapshot(), rotated = try snapshot(token: "rotated")
        try seed(rotated)
        XCTAssertThrowsError(try repository.live.apply(snapshot("b"), ifUnchangedFrom: first))
        XCTAssertEqual(try repository.live.snapshot(), rotated)
    }
    func testUnsupportedStoresNeverChangeCredentials() throws {
        let original = try snapshot()
        try seed(original)
        for configuration in ["cli_auth_credentials_store = \"keyring\"", "cli_auth_credentials_store = 'auto'", "[profile]\ncli_auth_credentials_store = \"file\"", "'cli_auth_credentials_store' = \"file\"", "\"cli_auth_credentials\\u005fstore\" = \"keyring\""] {
            try privateWrite(Data(configuration.utf8), to: installation.configFile)
            XCTAssertThrowsError(try repository.live.apply(snapshot("b")))
            XCTAssertEqual(try Data(contentsOf: installation.authFile), original.authJSON)
            XCTAssertTrue(secrets.writes.isEmpty)
        }
    }
    func testExplicitFileStoreCommentsAndDefaultAreAccepted() throws {
        try installation.requireFileStorage()
        try privateWrite(Data("# cli_auth_credentials_store = \"auto\"\ncli_auth_credentials_store = 'file' # local\n[features]\nplugins = false\n".utf8), to: installation.configFile)
        try installation.requireFileStorage()
    }
    func testRejectsAPIKeyMalformedAndNonrefreshableLogins() throws {
        for raw in ["{}", "not json", "{\"OPENAI_API_KEY\":\"synthetic\"}"] {
            XCTAssertThrowsError(try CodexCredentialSnapshot(authJSON: Data(raw.utf8)).validated())
        }
        var object = try JSONSerialization.jsonObject(with: snapshot().authJSON) as! [String: Any]
        object["auth_mode"] = "chatgptAuthTokens"
        XCTAssertThrowsError(try CodexCredentialSnapshot(authJSON: JSONSerialization.data(withJSONObject: object)).validated())
        object["auth_mode"] = "chatgpt"
        var tokens = object["tokens"] as! [String: Any]
        tokens["account_id"] = "different-workspace"
        object["tokens"] = tokens
        XCTAssertThrowsError(try CodexCredentialSnapshot(authJSON: JSONSerialization.data(withJSONObject: object)).validated())
    }
    func testRejectsSymlinkWithoutChangingTarget() throws {
        let target = root.appendingPathComponent("protected.json"), original = try snapshot()
        try privateWrite(original.authJSON, to: target)
        try FileManager.default.createDirectory(at: installation.home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: installation.authFile, withDestinationURL: target)
        XCTAssertThrowsError(try repository.live.apply(snapshot("b")))
        XCTAssertEqual(try Data(contentsOf: target), original.authJSON)
        try FileManager.default.removeItem(at: target)
        XCTAssertThrowsError(try repository.live.apply(snapshot("b")))
    }
}
