import Foundation
import XCTest
@testable import SwitchboardCore

final class StorageTests: RepositoryTestCase {
    func testAppliedCredentialIsPrintableASCIIJSONForSecurityCommand() throws {
        let target = try snapshot("b")
        try repository.live.apply(target)

        let stored = try XCTUnwrap(secrets.value(installation: installation))
        XCTAssertTrue(stored.allSatisfy { (32...126).contains($0) }, "Nonprintable bytes make security -w return hex instead of JSON.")
        let object = try jsonObject(stored)
        try assertJSONEqual(jsonData(XCTUnwrap(object["claudeAiOauth"])), target.oauth)
        XCTAssertEqual(try repository.live.snapshot(), target)
    }

    func testPrintableCredentialEncodingPreservesUnicodeAndControlValuesAcrossSwitch() throws {
        let text = "Café e\u{0301} 日本語 🚀\n\t\r\u{0000}\u{001F}\u{007F}\u{2028}\u{2029} \"quoted\" \\ /"
        let siblings: [String: Any] = [
            "mcpOAuth": ["server-🧪": ["accessToken": "synthetic-mcp-token", "label": text]],
            "unrelatedUnicode": [text, "🛰️"]
        ]
        try seedLive(snapshot(), credentialSiblings: siblings)
        let target = try snapshot("b")
        var oauth = try jsonObject(target.oauth)
        oauth["futureMetadata-🌙"] = ["description": text]
        let withUnicode = try CredentialSnapshot(oauth: jsonData(oauth), identity: target.identity)

        try repository.live.apply(withUnicode)
        let stored = try XCTUnwrap(secrets.value(installation: installation))
        XCTAssertTrue(stored.allSatisfy { (32...126).contains($0) })
        let object = try jsonObject(stored)
        for (key, value) in siblings {
            try assertJSONEqual(jsonData(XCTUnwrap(object[key])), jsonData(value))
        }
        try assertJSONEqual(jsonData(XCTUnwrap(object["claudeAiOauth"])), withUnicode.oauth)
        XCTAssertEqual(try token(XCTUnwrap(repository.live.snapshot())), "synthetic-access-b")
        XCTAssertEqual(try repository.live.snapshot(), withUnicode)
    }

    func testSnapshotContainsOnlyOAuthAndIdentity() throws {
        let expected = try snapshot()
        try seedLive(expected, config: ["theme": "dark"],
                     credentialSiblings: ["mcpOAuth": ["secret": "synthetic-mcp-token"]])
        let actual = try XCTUnwrap(repository.live.snapshot())
        try assertJSONEqual(actual.oauth, expected.oauth)
        try assertJSONEqual(actual.identity, expected.identity)
        XCTAssertFalse(String(decoding: actual.oauth, as: UTF8.self).contains("synthetic-mcp-token"))
    }

    func testMissingCredentialOrIdentityIsNotACompleteLogin() throws {
        XCTAssertNil(try repository.live.snapshot())
        try privateWrite(jsonData(["oauthAccount": jsonObject(snapshot().identity)]), to: installation.configFile)
        XCTAssertNil(try repository.live.snapshot())
        try privateWrite(jsonData(["theme": "dark"]), to: installation.configFile)
        secrets.seed(try jsonData(["claudeAiOauth": jsonObject(snapshot().oauth)]), installation: installation)
        XCTAssertNil(try repository.live.snapshot())
        try privateWrite(jsonData(["oauthAccount": jsonObject(snapshot().identity)]), to: installation.configFile)
        secrets.seed(try jsonData(["mcpOAuth": "synthetic-unrelated"]), installation: installation)
        XCTAssertNil(try repository.live.snapshot())
    }

    func testMalformedConfigCannotBeOverwrittenBySwitch() throws {
        try seedLive(snapshot())
        let invalidConfig = Data("{ unfinished json".utf8)
        try privateWrite(invalidConfig, to: installation.configFile)
        let originalSecrets = secrets.values
        XCTAssertThrowsError(try repository.live.apply(snapshot("b")))
        XCTAssertEqual(try Data(contentsOf: installation.configFile), invalidConfig)
        XCTAssertEqual(secrets.values, originalSecrets)
        XCTAssertTrue(secrets.writes.isEmpty)
    }

    func testMalformedCredentialContainerCannotBeOverwrittenBySwitch() throws {
        try seedLive(snapshot())
        let invalidCredentials = Data("[]".utf8)
        secrets.seed(invalidCredentials, installation: installation)
        let originalConfig = try Data(contentsOf: installation.configFile)
        XCTAssertThrowsError(try repository.live.apply(snapshot("b")))
        XCTAssertEqual(secrets.value(installation: installation), invalidCredentials)
        XCTAssertEqual(try Data(contentsOf: installation.configFile), originalConfig)
        XCTAssertTrue(secrets.writes.isEmpty)
    }

    func testConfigWriteFailureRestoresOriginalKeychainBytes() throws {
        try seedLive(snapshot(), credentialSiblings: ["mcpOAuth": ["token": "synthetic-mcp-token"]])
        let original = try XCTUnwrap(secrets.value(installation: installation))
        let target = try snapshot("b")
        let configFile = installation.configFile
        let originalConfig = try Data(contentsOf: configFile)
        try withReadOnlyDirectory(configFile.deletingLastPathComponent()) {
            XCTAssertThrowsError(try repository.live.apply(target))
        }
        XCTAssertEqual(secrets.value(installation: installation), original)
        XCTAssertEqual(try Data(contentsOf: configFile), originalConfig)
        XCTAssertEqual(secrets.writes.filter { $0.service == installation.keychainService }.count, 2)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: configFile.deletingLastPathComponent().path)
        XCTAssertFalse(remaining.contains { $0.hasPrefix(".switchboard-") })
    }

    func testConfigWriteFailureDeletesNewKeychainItemIfNoneExisted() throws {
        try privateWrite(jsonData(["theme": "dark"]), to: installation.configFile)
        let configFile = installation.configFile
        let originalConfig = try Data(contentsOf: configFile)
        try withReadOnlyDirectory(configFile.deletingLastPathComponent()) {
            XCTAssertThrowsError(try repository.live.apply(snapshot("b")))
        }
        XCTAssertNil(secrets.value(installation: installation))
        XCTAssertEqual(try Data(contentsOf: configFile), originalConfig)
        XCTAssertTrue(secrets.deletes.contains(SecretKey(service: installation.keychainService,
                                                        account: installation.keychainAccount)))
    }

    func testKeychainWriteFailureLeavesConfigAndCredentialsUntouched() throws {
        try seedLive(snapshot())
        let originalSecrets = secrets.values
        let originalConfig = try Data(contentsOf: installation.configFile)
        secrets.beforeWrite = { _ in throw SwitchboardError.message("Synthetic Keychain failure") }
        XCTAssertThrowsError(try repository.live.apply(snapshot("b")))
        XCTAssertEqual(secrets.values, originalSecrets)
        XCTAssertEqual(try Data(contentsOf: installation.configFile), originalConfig)
    }

    func testPrivateFilesAndNewDirectoriesHaveOwnerOnlyPermissions() throws {
        let account = try repository.withLock { try repository.capture(snapshot()) }
        let profile = try repository.prepareUsage(account.id)
        let files = [repository.directory.appendingPathComponent("accounts.json"),
                     repository.directory.appendingPathComponent("accounts.lock"), profile.configFile]
        for file in files {
            let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o777, 0o600, file.lastPathComponent)
        }
        for directory in [repository.directory, profile.configDirectory] {
            let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o777, 0o700, directory.lastPathComponent)
        }
    }

    func testAtomicPrivateWriteReplacesFileAndRestrictsExistingFileMode() throws {
        let file = root.appendingPathComponent("replace.json")
        try Data("old".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try privateWrite(Data("new".utf8), to: file)
        XCTAssertEqual(try Data(contentsOf: file), Data("new".utf8))
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["replace.json"])
    }

    func testFileCredentialFallbackRefusesSnapshotAndApplyWithoutChangingFilesOrKeychain() throws {
        try seedLive(snapshot(), config: ["theme": "dark"])
        let fallback = installation.configDirectory.appendingPathComponent(".credentials.json")
        let fallbackData = try jsonData(["claudeAiOauth": jsonObject(snapshot("c").oauth)])
        try privateWrite(fallbackData, to: fallback)
        let originalValues = secrets.values
        let originalConfig = try Data(contentsOf: installation.configFile)

        XCTAssertThrowsError(try repository.live.snapshot()) { error in
            XCTAssertTrue(error.localizedDescription.contains("file-based credential store"))
        }
        XCTAssertThrowsError(try repository.live.apply(snapshot("b"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("file-based credential store"))
        }
        XCTAssertEqual(secrets.values, originalValues)
        XCTAssertEqual(try Data(contentsOf: installation.configFile), originalConfig)
        XCTAssertEqual(try Data(contentsOf: fallback), fallbackData)
    }
}

final class ClaudeInstallationTests: XCTestCase {
    func testDefaultInstallationUsesHomeConfigAndStandardKeychainService() {
        let installation = ClaudeInstallation(home: URL(fileURLWithPath: "/synthetic/home"), environment: ["USER": "test-user"])
        XCTAssertEqual(installation.configDirectory.path, "/synthetic/home/.claude")
        XCTAssertEqual(installation.configFile.path, "/synthetic/home/.claude.json")
        XCTAssertEqual(installation.keychainService, "Claude Code-credentials")
        XCTAssertEqual(installation.keychainAccount, "test-user")
        XCTAssertTrue(installation.configurationEnvironment.isEmpty)
    }

    func testCustomConfigPreservesExactNamespaceIncludingTrailingSlash() {
        let plain = ClaudeInstallation(environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude-profile", "USER": "test-user"])
        let slash = ClaudeInstallation(environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude-profile/", "USER": "test-user"])
        XCTAssertEqual(plain.configFile.path, "/tmp/claude-profile/.claude.json")
        XCTAssertEqual(plain.keychainService, "Claude Code-credentials-7182514b")
        XCTAssertEqual(slash.keychainService, "Claude Code-credentials-ecce54fe")
        XCTAssertEqual(slash.configurationEnvironment["CLAUDE_CONFIG_DIR"], "/tmp/claude-profile/")
        XCTAssertNotEqual(plain.keychainService, slash.keychainService)
    }

    func testSecureStorageOverrideChangesOnlyKeychainNamespace() {
        let installation = ClaudeInstallation(environment: [
            "CLAUDE_CONFIG_DIR": "/tmp/claude-profile", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/tmp/secure-store",
            "USER": "test-user", "UNRELATED_VARIABLE": "do-not-forward"
        ])
        XCTAssertEqual(installation.configFile.path, "/tmp/claude-profile/.claude.json")
        XCTAssertEqual(installation.keychainService, "Claude Code-credentials-6a836d2f")
        XCTAssertEqual(installation.configurationEnvironment.count, 2)
        XCTAssertNil(installation.configurationEnvironment["USER"])
        XCTAssertNil(installation.configurationEnvironment["UNRELATED_VARIABLE"])
    }

    func testKeychainNamespaceUsesCanonicalUnicodeNormalization() {
        let composed = ClaudeInstallation(environment: ["CLAUDE_CONFIG_DIR": "/tmp/caf\u{00E9}", "USER": "test-user"])
        let decomposed = ClaudeInstallation(environment: ["CLAUDE_CONFIG_DIR": "/tmp/cafe\u{0301}", "USER": "test-user"])
        XCTAssertEqual(composed.keychainService, "Claude Code-credentials-0873cca0")
        XCTAssertEqual(composed.keychainService, decomposed.keychainService)
    }

    func testInvalidUsernameUsesCLIFallback() {
        for user in ["name with spaces", "", "name@example.test", "../user", "caf\u{00E9}"] {
            XCTAssertEqual(ClaudeInstallation(environment: ["USER": user]).keychainAccount, "claude-code-user")
        }
        XCTAssertEqual(ClaudeInstallation(environment: ["USER": "user._-123"]).keychainAccount, "user._-123")
    }
}
