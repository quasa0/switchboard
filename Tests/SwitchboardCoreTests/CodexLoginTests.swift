import Foundation
import XCTest
import Darwin
@testable import SwitchboardCore

final class CodexLoginTests: CodexTestCase {
    func testOfficialLoginRunsInEmptyPrivateHomeAndSavesOnlyIsolatedAuth() throws {
        let original = try snapshot(), expected = try snapshot("b")
        try seed(original)
        let executable = try fixture("""
        import base64, json, os, sys
        root = os.environ['CODEX_HOME']
        assert root != os.environ['HOME']
        assert not os.path.exists(os.path.join(root, 'auth.json'))
        with open(os.path.join(root, 'receipt.json'), 'w') as handle:
            json.dump({'args': sys.argv[1:], 'home': os.environ['HOME'], 'codex_home': root}, handle)
        with open(os.path.join(root, 'auth.json'), 'wb') as handle:
            handle.write(base64.b64decode('\(expected.authJSON.base64EncodedString())'))
        """)
        let session = try CodexLoginSession(directory: root.appendingPathComponent("login"), executable: executable)
        defer { session.stop() }
        try startOrSkip(session)
        let deadline = Date().addingTimeInterval(3)
        var finished = false
        while Date() < deadline {
            if (try? session.checkFinished()) != nil { finished = true; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(try repository.live.snapshot(), original)
        XCTAssertEqual(try CodexLoginStore(installation: session.installation).snapshot(), expected)
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: session.installation.home.appendingPathComponent("receipt.json"))) as! [String: Any]
        XCTAssertEqual(receipt["home"] as? String, session.installation.home.appendingPathComponent("home").path)
        XCTAssertEqual(receipt["codex_home"] as? String, session.installation.home.path)
        let arguments = receipt["args"] as! [String]
        XCTAssertEqual(arguments.first, "login")
        XCTAssertTrue(arguments.contains("cli_auth_credentials_store=\"file\""))
        XCTAssertTrue(arguments.contains("features.plugins=false"))
    }

    func testRefusesExistingAuthBeforeLoginCanRevokeIt() throws {
        let directory = root.appendingPathComponent("login")
        let authFile = directory.appendingPathComponent("auth.json")
        let original = try snapshot()
        try privateWrite(original.authJSON, to: authFile)
        XCTAssertThrowsError(try CodexLoginSession(directory: directory, executable: URL(fileURLWithPath: "/usr/bin/false")))
        XCTAssertEqual(try Data(contentsOf: authFile), original.authJSON)
    }

    func testNonzeroExitCannotBeSaved() throws {
        let session = try CodexLoginSession(directory: root.appendingPathComponent("login"), executable: URL(fileURLWithPath: "/usr/bin/false"))
        defer { session.stop() }
        try startOrSkip(session)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertThrowsError(try session.checkFinished())
    }

    func testCancellationReapsSigtermResistantLogin() throws {
        let executable = try fixture("""
        import os, signal, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with open(os.path.join(os.environ['CODEX_HOME'], 'pid'), 'w') as handle:
            handle.write(str(os.getpid()))
        while True:
            time.sleep(0.05)
        """)
        let session = try CodexLoginSession(directory: root.appendingPathComponent("login"), executable: executable)
        defer { session.stop() }
        try startOrSkip(session)
        let pidFile = session.installation.home.appendingPathComponent("pid")
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: pidFile.path) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        let pid = try XCTUnwrap(pid_t(String(contentsOf: pidFile, encoding: .utf8)))
        session.stop()
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    private func fixture(_ body: String) throws -> URL {
        let executable = root.appendingPathComponent("fixture-\(UUID().uuidString).py")
        try Data(("#!/usr/bin/python3\n" + body + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }
    private func startOrSkip(_ session: CodexLoginSession) throws {
        do { try session.start() }
        catch {
            if error.localizedDescription.contains("localhost:1455") { throw XCTSkip("A user's Codex login owns the callback port; leave it untouched.") }
            throw error
        }
    }
}
