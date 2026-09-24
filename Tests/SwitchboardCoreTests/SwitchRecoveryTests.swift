import Foundation
import XCTest
@testable import SwitchboardCore

final class SwitchRecoveryTests: RepositoryTestCase {
    private var journalKey: SecretKey {
        SecretKey(service: AccountRepository.vaultService, account: "pending-switch")
    }

    private func seedJournal(before: CredentialSnapshot?, target: CredentialSnapshot) throws {
        struct Journal: Encodable {
            let before: CredentialSnapshot?
            let target: CredentialSnapshot
        }
        secrets.values[journalKey] = try JSONEncoder().encode(Journal(before: before, target: target))
    }

    private func replaceLiveOAuth(with snapshot: CredentialSnapshot) throws {
        var credentials = try jsonObject(XCTUnwrap(secrets.value(installation: installation)))
        credentials["claudeAiOauth"] = try jsonObject(snapshot.oauth)
        secrets.seed(try jsonData(credentials), installation: installation)
    }

    func testInterruptedSwitchAfterKeychainWriteCompletesTargetOnStateRead() throws {
        let before = try snapshot()
        let target = try snapshot("b")
        let accountA = try repository.capture(before, label: "Personal")
        let accountB = try repository.capture(target, label: "Work")
        try seedLive(before, config: ["theme": "dark", "projects": ["/project": ["trusted": true]],
                                       "cachedUsageUtilization": ["account": "a"]],
                     credentialSiblings: ["mcpOAuth": ["server": ["accessToken": "synthetic-mcp-secret"]]])
        try seedJournal(before: before, target: target)
        try replaceLiveOAuth(with: target)

        let state = try repository.withLock { try repository.state() }
        XCTAssertEqual(state.activeID, accountB.id)
        XCTAssertEqual(state.current?.email, "b@example.test")
        let recovered = try XCTUnwrap(repository.live.snapshot())
        XCTAssertEqual(try recovered.validated().0.accountUUID, "account-b")
        XCTAssertEqual(try token(recovered), "synthetic-access-b")
        let config = try readObject(installation.configFile)
        XCTAssertEqual(config["theme"] as? String, "dark")
        try assertJSONEqual(jsonData(XCTUnwrap(config["projects"])), jsonData(["/project": ["trusted": true]]))
        XCTAssertNil(config["cachedUsageUtilization"])
        let credentials = try jsonObject(XCTUnwrap(secrets.value(installation: installation)))
        try assertJSONEqual(jsonData(XCTUnwrap(credentials["mcpOAuth"])), jsonData(["server": ["accessToken": "synthetic-mcp-secret"]]))
        XCTAssertNil(secrets.values[journalKey])
        XCTAssertEqual(try repository.credential(for: accountA.id), before)
        XCTAssertEqual(try repository.credential(for: accountB.id), target)
    }

    func testInterruptedSwitchWithPreviousTokenRestoresPreviousIdentity() throws {
        let before = try snapshot()
        let target = try snapshot("b")
        let accountA = try repository.capture(before)
        _ = try repository.capture(target)
        try seedLive(target, config: ["theme": "dark"])
        try replaceLiveOAuth(with: before)
        try seedJournal(before: before, target: target)

        try repository.withLock { try repository.recoverInterruptedSwitch() }
        XCTAssertEqual(try token(XCTUnwrap(repository.live.snapshot())), "synthetic-access-a")
        XCTAssertEqual(try repository.state().activeID, accountA.id)
        XCTAssertEqual(try readObject(installation.configFile)["theme"] as? String, "dark")
        XCTAssertNil(secrets.values[journalKey])
    }

    func testRecoveryRefusesUnknownExternalTokenWithoutOverwritingAnyState() throws {
        let before = try snapshot()
        let target = try snapshot("b")
        _ = try repository.capture(before)
        _ = try repository.capture(target)
        try seedLive(snapshot("c"), config: ["theme": "dark"])
        try seedJournal(before: before, target: target)
        let originalValues = secrets.values
        let originalConfig = try Data(contentsOf: installation.configFile)
        let metadataFile = repository.directory.appendingPathComponent("accounts.json")
        let originalMetadata = try Data(contentsOf: metadataFile)

        XCTAssertThrowsError(try repository.withLock { try repository.state() }) { error in
            XCTAssertTrue(error.localizedDescription.contains("changed afterward"))
        }
        XCTAssertEqual(secrets.values, originalValues)
        XCTAssertEqual(try Data(contentsOf: installation.configFile), originalConfig)
        XCTAssertEqual(try Data(contentsOf: metadataFile), originalMetadata)
    }

    func testSuccessfulSwitchSurvivesJournalDeleteFailureAndCanRetryCleanup() throws {
        let before = try snapshot()
        let target = try snapshot("b")
        try seedLive(before)
        _ = try repository.capture(before)
        let accountB = try repository.capture(target)
        let pendingKey = journalKey
        secrets.beforeDelete = { key in
            if key == pendingKey { throw SwitchboardError.message("Synthetic journal deletion failure") }
        }

        XCTAssertNoThrow(try repository.withLock { try repository.activate(accountB.id) })
        XCTAssertEqual(try token(XCTUnwrap(repository.live.snapshot())), "synthetic-access-b")
        XCTAssertEqual(try repository.live.snapshot()?.validated().0.accountUUID, "account-b")
        XCTAssertNotNil(secrets.values[journalKey])

        secrets.beforeDelete = nil
        let state = try repository.withLock { try repository.state() }
        XCTAssertEqual(state.activeID, accountB.id)
        XCTAssertNil(secrets.values[journalKey])
        XCTAssertEqual(try token(XCTUnwrap(repository.live.snapshot())), "synthetic-access-b")
    }

    func testJournalBeforeFirstCredentialWriteClearsWithoutChangingExistingConfig() throws {
        let target = try snapshot("b")
        _ = try repository.capture(target)
        try privateWrite(jsonData(["theme": "dark"]), to: installation.configFile)
        let originalConfig = try Data(contentsOf: installation.configFile)
        try seedJournal(before: nil, target: target)
        let writesBefore = secrets.writes

        try repository.withLock { try repository.recoverInterruptedSwitch() }
        XCTAssertNil(secrets.values[journalKey])
        XCTAssertNil(secrets.value(installation: installation))
        XCTAssertEqual(secrets.writes, writesBefore)
        XCTAssertEqual(try Data(contentsOf: installation.configFile), originalConfig)
    }

    func testFailedRollbackOnFirstSwitchKeepsJournalAndRecoversOnRetry() throws {
        let target = try snapshot("b")
        let accountB = try repository.capture(target)
        let configParent = installation.configFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: configParent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let liveKey = SecretKey(service: installation.keychainService, account: installation.keychainAccount)
        secrets.beforeDelete = { key in
            if key == liveKey { throw SwitchboardError.message("Synthetic Keychain rollback failure") }
        }

        try withReadOnlyDirectory(configParent) {
            XCTAssertThrowsError(try repository.withLock { try repository.activate(accountB.id) })
        }
        XCTAssertNotNil(secrets.value(installation: installation))
        XCTAssertNotNil(secrets.values[journalKey], "Incomplete rollback must retain the recovery journal even when no identity exists.")
        secrets.beforeDelete = nil

        let recovered = try repository.withLock { try repository.state() }
        XCTAssertEqual(recovered.activeID, accountB.id)
        XCTAssertEqual(try token(XCTUnwrap(repository.live.snapshot())), "synthetic-access-b")
        XCTAssertNil(secrets.values[journalKey])
    }

    func testCorruptJournalCannotChangeLiveOrSavedCredentials() throws {
        try seedLive(snapshot())
        _ = try repository.capture(snapshot())
        secrets.values[journalKey] = Data("invalid journal".utf8)
        let originalValues = secrets.values
        let originalConfig = try Data(contentsOf: installation.configFile)
        XCTAssertThrowsError(try repository.withLock { try repository.recoverInterruptedSwitch() })
        XCTAssertEqual(secrets.values, originalValues)
        XCTAssertEqual(try Data(contentsOf: installation.configFile), originalConfig)
    }
}
