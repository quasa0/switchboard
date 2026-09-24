import Foundation
import XCTest
@testable import SwitchboardCore

final class CodexAccountRepositoryTests: CodexTestCase {
    func testRoundTripPreservesRotationsPreviousLoginAndMetadata() throws {
        let first = try snapshot(), second = try snapshot("b")
        try seed(first)
        let a = try repository.capture(first, label: "Personal"), b = try repository.capture(second, label: "Work")
        let rotated = try snapshot(token: "rotated", refreshed: "2026-09-24T10:00:00Z")
        try seed(rotated)
        try repository.withLock { try repository.activate(b.id) }
        XCTAssertEqual(try repository.credential(for: a.id), rotated)
        XCTAssertEqual(try repository.live.snapshot(), second)
        try repository.withLock { try repository.activate(a.id) }
        XCTAssertEqual(try repository.live.snapshot(), rotated)
        XCTAssertEqual(try repository.state().activeID, a.id)
        let previous = try XCTUnwrap(secrets.read(service: CodexAccountRepository.vaultService, account: "previous-login"))
        XCTAssertEqual(try JSONDecoder().decode(CodexCredentialSnapshot.self, from: previous), second)
        let metadata = try String(contentsOf: repository.directory.appendingPathComponent("accounts.json"), encoding: .utf8)
        XCTAssertFalse(metadata.contains("synthetic")); XCTAssertFalse(metadata.contains("refresh_token"))
        XCTAssertEqual(try repository.accounts().first { $0.id == a.id }?.label, "Personal")
    }
    func testIdentityIncludesWorkspaceAndPreservesUsageOnRecapture() throws {
        let account = try repository.capture(snapshot(), label: "Personal")
        let usage = UsageSnapshot(fiveHour: .init(utilization: 42, resetsAt: nil))
        try repository.updateUsage(account.id, usage: usage)
        let recaptured = try repository.capture(snapshot(token: "rotated"))
        XCTAssertEqual(recaptured.id, account.id); XCTAssertEqual(recaptured.usage, usage)
        XCTAssertEqual(recaptured.label, "Personal")
        let workspace = try repository.capture(snapshot(workspace: "team"))
        XCTAssertNotEqual(workspace.id, account.id)
    }
    func testUsageUsesLiveFileForActiveAccountAndCollectsInactiveRefresh() throws {
        let first = try snapshot(), second = try snapshot("b")
        try seed(first)
        let a = try repository.capture(first), b = try repository.capture(second)
        let liveProfile = try repository.prepareUsage(a.id)
        XCTAssertEqual(liveProfile.home, installation.home)
        XCTAssertThrowsError(try repository.activate(b.id))
        let liveRotated = try snapshot(token: "live-refresh", refreshed: "2026-09-24T11:00:00Z")
        try seed(liveRotated)
        try repository.collectUsageCredentials(a.id, from: liveProfile)
        XCTAssertEqual(try repository.credential(for: a.id), liveRotated)
        let profile = try repository.prepareUsage(b.id)
        XCTAssertNotEqual(profile.home, installation.home)
        let inactiveRotated = try snapshot("b", token: "inactive-refresh", refreshed: "2026-09-24T12:00:00Z")
        try CodexLoginStore(installation: profile).apply(inactiveRotated)
        try repository.collectUsageCredentials(b.id, from: profile)
        XCTAssertEqual(try repository.credential(for: b.id), inactiveRotated)
        XCTAssertEqual(try repository.live.snapshot(), liveRotated)
    }
    func testStaleUsageCannotOverwriteNewerCapture() throws {
        try seed(snapshot())
        let account = try repository.capture(snapshot("b"))
        let profile = try repository.prepareUsage(account.id)
        let newer = try snapshot("b", token: "new-browser-login", refreshed: "2026-09-24T13:00:00Z")
        try repository.capture(newer)
        XCTAssertThrowsError(try repository.collectUsageCredentials(account.id, from: profile))
        XCTAssertEqual(try repository.credential(for: account.id), newer)
        // Collection failure releases the in-flight guard.
        try repository.activate(account.id)
        XCTAssertEqual(try repository.live.snapshot(), newer)
    }
    func testInterruptedUsageRotationIsRecoveredBeforeSwitch() throws {
        try seed(snapshot())
        let account = try repository.capture(snapshot("b"))
        let profile = try repository.prepareUsage(account.id)
        let rotated = try snapshot("b", token: "recovered", refreshed: "2026-09-24T14:00:00Z")
        try CodexLoginStore(installation: profile).apply(rotated)
        let reopened = CodexAccountRepository(directory: repository.directory, secrets: secrets, installation: installation)
        try reopened.activate(account.id)
        XCTAssertEqual(try reopened.credential(for: account.id), rotated)
        XCTAssertEqual(try reopened.live.snapshot(), rotated)
    }
    func testMissingTargetAndRemovalPreserveLiveLogin() throws {
        let first = try snapshot()
        try seed(first)
        let saved = try repository.capture(snapshot("b"))
        try secrets.delete(service: CodexAccountRepository.vaultService, account: saved.id.uuidString)
        XCTAssertThrowsError(try repository.activate(saved.id))
        XCTAssertEqual(try repository.live.snapshot(), first)
        try repository.remove(saved.id)
        XCTAssertEqual(try repository.live.snapshot(), first)
    }
    func testLockExcludesOtherRepository() throws {
        let other = CodexAccountRepository(directory: repository.directory, secrets: secrets, installation: installation)
        try repository.withLock { XCTAssertThrowsError(try other.withLock { () }) }
        try other.withLock { () }
    }
}
