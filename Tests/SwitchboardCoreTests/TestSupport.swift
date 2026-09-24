import Foundation
import XCTest
import Darwin
@testable import SwitchboardCore

struct SecretKey: Hashable {
    let service: String
    let account: String
}

final class MemorySecretStore: SecretStore {
    var values: [SecretKey: Data] = [:]
    var writes: [SecretKey] = []
    var deletes: [SecretKey] = []
    var afterWrite: ((SecretKey) throws -> Void)?
    var beforeRead: ((SecretKey) throws -> Void)?
    var beforeWrite: ((SecretKey) throws -> Void)?
    var beforeDelete: ((SecretKey) throws -> Void)?

    func read(service: String, account: String) throws -> Data? {
        let key = SecretKey(service: service, account: account)
        try beforeRead?(key)
        return values[key]
    }

    func write(_ data: Data, service: String, account: String) throws {
        let key = SecretKey(service: service, account: account)
        try beforeWrite?(key)
        values[key] = data
        writes.append(key)
        try afterWrite?(key)
    }

    func delete(service: String, account: String) throws {
        let key = SecretKey(service: service, account: account)
        try beforeDelete?(key)
        values.removeValue(forKey: key)
        deletes.append(key)
    }

    func seed(_ data: Data, installation: ClaudeInstallation) {
        values[SecretKey(service: installation.keychainService, account: installation.keychainAccount)] = data
    }

    func value(installation: ClaudeInstallation) -> Data? {
        values[SecretKey(service: installation.keychainService, account: installation.keychainAccount)]
    }
}

class RepositoryTestCase: XCTestCase {
    var root: URL!
    var installation: ClaudeInstallation!
    var secrets: MemorySecretStore!
    var repository: AccountRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitchboardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        installation = ClaudeInstallation(home: root.appendingPathComponent("home"),
                                            environment: ["USER": "synthetic-user"])
        secrets = MemorySecretStore()
        repository = AccountRepository(directory: root.appendingPathComponent("vault"),
                                       secrets: secrets, installation: installation)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
        repository = nil
        secrets = nil
        installation = nil
        root = nil
    }

    func snapshot(_ name: String = "a", organization: String? = nil,
                  token: String? = nil, tier: String = "default_claude_max_20x") throws -> CredentialSnapshot {
        let oauth: [String: Any] = [
            "accessToken": token ?? "synthetic-access-\(name)",
            "refreshToken": "synthetic-refresh-\(name)",
            "expiresAt": 4_102_444_800_000.0,
            "scopes": ["user:profile", "user:inference"],
            "subscriptionType": "max", "rateLimitTier": tier,
            "futureTokenMetadata": ["preserve": true]
        ]
        let identity: [String: Any] = [
            "accountUuid": "account-\(name)", "emailAddress": "\(name)@example.test",
            "organizationUuid": organization ?? "organization-\(name)",
            "displayName": "Account \(name.uppercased())", "hasExtraUsageEnabled": true
        ]
        return try CredentialSnapshot(oauth: jsonData(oauth), identity: jsonData(identity))
    }

    func seedLive(_ snapshot: CredentialSnapshot, config: [String: Any] = [:],
                  credentialSiblings: [String: Any] = [:]) throws {
        var config = config
        config["oauthAccount"] = try jsonObject(snapshot.identity)
        try privateWrite(jsonData(config), to: installation.configFile)
        var credentials = credentialSiblings
        credentials["claudeAiOauth"] = try jsonObject(snapshot.oauth)
        secrets.seed(try jsonData(credentials), installation: installation)
    }

    func token(_ snapshot: CredentialSnapshot) throws -> String {
        try snapshot.validated().1.accessToken
    }

    func assertJSONEqual(_ first: Data, _ second: Data,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        let lhs = try JSONSerialization.jsonObject(with: first, options: .fragmentsAllowed) as! NSObject
        let rhs = try JSONSerialization.jsonObject(with: second, options: .fragmentsAllowed) as! NSObject
        XCTAssertTrue(lhs.isEqual(rhs), file: file, line: line)
    }

    func withReadOnlyDirectory<T>(_ directory: URL, operation: () throws -> T) throws -> T {
        try XCTSkipIf(geteuid() == 0, "Root bypasses the write-permission failure used by this test.")
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let original = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            do { try FileManager.default.setAttributes([.posixPermissions: original], ofItemAtPath: directory.path) }
            catch { XCTFail("Could not restore the temporary test directory permissions: \(error)") }
        }
        return try operation()
    }
}
