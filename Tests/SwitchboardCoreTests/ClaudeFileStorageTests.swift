import Foundation
import XCTest
import Darwin
@testable import SwitchboardCore

final class ClaudeFileStorageTests: RepositoryTestCase {
    private var file: URL { installation.configDirectory.appendingPathComponent(".credentials.json") }
    private var liveKey: SecretKey { SecretKey(service: installation.keychainService, account: installation.keychainAccount) }

    private func seedFile(_ value: CredentialSnapshot) throws {
        try seedLive(value, config: ["theme": "dark"], credentialSiblings: ["mcpOAuth": ["token": "synthetic-mcp"]])
        try privateWrite(XCTUnwrap(secrets.value(installation: installation)), to: file)
        secrets.values.removeValue(forKey: liveKey)
    }

    func testFileLoginCanBeCapturedSwitchedAndUsedWithoutCreatingLiveKeychainEntry() throws {
        let before = try snapshot(), target = try snapshot("b")
        try seedFile(before)
        XCTAssertEqual(try repository.live.snapshot(), before)
        try repository.captureCurrent(label: "First")
        let account = try repository.capture(target)
        try repository.withLock { try repository.activate(account.id) }
        XCTAssertEqual(try repository.state().activeID, account.id)
        XCTAssertEqual(try repository.live.snapshot(), target)
        XCTAssertNil(secrets.value(installation: installation))
        XCTAssertEqual(try readObject(installation.configFile)["theme"] as? String, "dark")
        try assertJSONEqual(jsonData(XCTUnwrap(readObject(file)["mcpOAuth"])), jsonData(["token": "synthetic-mcp"]))
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        XCTAssertEqual(try repository.prepareUsage(account.id).configDirectory, installation.configDirectory)
        try repository.collectUsageCredentials(account.id, from: installation)
        XCTAssertEqual(try repository.credential(for: account.id), target)
    }

    func testFileWriteRollsBackWhenConfigCannotBeWritten() throws {
        try seedFile(snapshot())
        let original = try Data(contentsOf: file)
        let config = try Data(contentsOf: installation.configFile)
        try withReadOnlyDirectory(installation.configFile.deletingLastPathComponent()) {
            XCTAssertThrowsError(try repository.live.apply(snapshot("b")))
        }
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try Data(contentsOf: installation.configFile), config)
        XCTAssertNil(secrets.value(installation: installation))
    }

    func testInterruptedFileWriteCompletesMatchingTargetButRefusesExternalLogin() throws {
        let before = try snapshot(), target = try snapshot("b")
        try seedFile(before)
        let account = try repository.capture(target)
        struct Journal: Encodable { let before: CredentialSnapshot; let target: CredentialSnapshot }
        let journalKey = SecretKey(service: AccountRepository.vaultService, account: "pending-switch")
        let journal = try JSONEncoder().encode(Journal(before: before, target: target))
        secrets.values[journalKey] = journal
        var credentials = try readObject(file)
        credentials["claudeAiOauth"] = try jsonObject(target.oauth)
        try privateWrite(jsonData(credentials), to: file)
        XCTAssertEqual(try repository.state().activeID, account.id)
        XCTAssertNil(secrets.values[journalKey])
        XCTAssertEqual(try repository.live.snapshot(), target)

        try seedFile(snapshot("c"))
        secrets.values[journalKey] = journal
        let original = try Data(contentsOf: file)
        XCTAssertThrowsError(try repository.state())
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(secrets.values[journalKey], journal)
    }

    func testInaccessibleKeychainDoesNotFallBackToPossiblyStaleFile() throws {
        try seedFile(snapshot())
        let original = try Data(contentsOf: file)
        let key = liveKey
        secrets.beforeRead = { if $0 == key { throw SwitchboardError.message("Synthetic locked Keychain") } }
        XCTAssertThrowsError(try repository.live.snapshot())
        XCTAssertThrowsError(try repository.live.apply(snapshot("b")))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testSwitchRefusesNewKeychainLoginDuringFileRead() throws {
        try seedFile(snapshot())
        let original = try Data(contentsOf: file)
        let config = try Data(contentsOf: installation.configFile)
        let key = liveKey
        let external = try jsonData(["claudeAiOauth": jsonObject(snapshot("c").oauth)])
        var reads = 0
        secrets.beforeRead = { [unowned self] found in
            if found == key { reads += 1; if reads == 2 { self.secrets.values[key] = external } }
        }
        XCTAssertThrowsError(try repository.live.apply(snapshot("b")))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try Data(contentsOf: installation.configFile), config)
        XCTAssertEqual(secrets.value(installation: installation), external)
    }

    func testSecureStorageOverrideReadsFileFromCredentialDirectory() throws {
        let profile = root.appendingPathComponent("profile")
        let secure = root.appendingPathComponent("secure")
        let isolated = ClaudeInstallation(home: root, environment: [
            "CLAUDE_CONFIG_DIR": profile.path, "CLAUDE_SECURESTORAGE_CONFIG_DIR": secure.path,
            "USER": "synthetic-user"
        ])
        let expected = try snapshot()
        try privateWrite(jsonData(["oauthAccount": jsonObject(expected.identity)]), to: isolated.configFile)
        try privateWrite(jsonData(["claudeAiOauth": jsonObject(expected.oauth)]), to: isolated.credentialFile)
        let store = ClaudeLoginStore(installation: isolated, secrets: secrets)
        XCTAssertEqual(try store.snapshot(), expected)
        let target = try snapshot("b")
        try store.apply(target)
        XCTAssertEqual(try store.snapshot(), target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.appendingPathComponent(".credentials.json").path))
        XCTAssertNil(secrets.value(installation: isolated))
    }

    func testConcurrentConfigChangePreventsFileReplacement() throws {
        try seedFile(snapshot())
        let original = try Data(contentsOf: file)
        let key = liveKey
        var reads = 0
        secrets.beforeRead = { [unowned self] found in
            if found == key {
                reads += 1
                if reads == 2 { try privateWrite(jsonData(["external": true]), to: self.installation.configFile) }
            }
        }
        XCTAssertThrowsError(try repository.live.apply(snapshot("b")))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try readObject(installation.configFile)["external"] as? Bool, true)
    }

    func testRollbackDoesNotOverwriteConcurrentKeychainLogin() throws {
        try seedLive(snapshot())
        let config = try Data(contentsOf: installation.configFile)
        let key = liveKey
        let external = try jsonData(["claudeAiOauth": jsonObject(snapshot("c").oauth)])
        secrets.afterWrite = { [unowned self] found in
            if found == key { self.secrets.values[key] = external }
        }
        XCTAssertThrowsError(try repository.live.apply(snapshot("b")))
        XCTAssertEqual(secrets.value(installation: installation), external)
        XCTAssertEqual(try Data(contentsOf: installation.configFile), config)
    }

    func testInvalidFileIsNeverReplacedOrMigratedToKeychain() throws {
        try seedFile(snapshot())
        for invalid in [Data("{broken".utf8), Data("[]".utf8), Data(repeating: 32, count: 1_048_577)] {
            try privateWrite(invalid, to: file)
            XCTAssertThrowsError(try repository.live.snapshot())
            XCTAssertThrowsError(try repository.live.apply(snapshot("b")))
            XCTAssertEqual(try Data(contentsOf: file), invalid)
            XCTAssertNil(secrets.value(installation: installation))
        }
    }

    func testSymlinkAndFIFOAreRejectedWithoutFollowingOrBlocking() throws {
        try seedFile(snapshot())
        let original = try Data(contentsOf: file)
        let target = root.appendingPathComponent("untouched.json")
        try privateWrite(original, to: target)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try repository.live.snapshot())
        XCTAssertThrowsError(try repository.live.apply(snapshot("b")))
        XCTAssertEqual(try Data(contentsOf: target), original)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        XCTAssertThrowsError(try repository.live.snapshot())
        XCTAssertThrowsError(try repository.live.apply(snapshot("b")))
    }
}
