import Foundation
import XCTest
import Darwin
@testable import SwitchboardCore

final class LoginSessionTests: XCTestCase {
    func testLoginArgumentsIsolatedEnvironmentAndCodeSubmission() throws {
        let overrides = EnvironmentOverrides([
            "ANTHROPIC_API_KEY": "synthetic-parent-key",
            "ANTHROPIC_AUTH_TOKEN": "synthetic-parent-token",
            "ANTHROPIC_BASE_URL": "https://example.invalid",
            "CLAUDE_CODE_OAUTH_TOKEN": "synthetic-parent-oauth",
            "CLAUDE_CONFIG_DIR": "/synthetic-parent/config",
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/synthetic-parent/keychain",
            "CLAUDE_TEST_OVERRIDE": "synthetic-parent-setting",
            "CLAUDECODE": "1"
        ])
        defer { overrides.restore() }
        let fixture = try Fixture(script: """
        import json, os, sys
        from pathlib import Path
        record = {
            'arguments': sys.argv[1:],
            'cwd': str(Path.cwd().resolve()),
            'config': str(Path(os.environ['CLAUDE_CONFIG_DIR']).resolve()),
            'rawConfig': os.environ['CLAUDE_CONFIG_DIR'],
            'overrideNames': sorted(k for k in os.environ if k.startswith('ANTHROPIC_') or k.startswith('CLAUDE_') or k == 'CLAUDECODE'),
            'user': os.environ['USER']
        }
        Path(__file__ + '.record').write_text(json.dumps(record))
        Path(__file__ + '.pid').write_text(str(os.getpid()))
        code = sys.stdin.readline()
        Path(__file__ + '.code').write_text(code)
        """)
        defer { fixture.remove() }
        let session = try LoginSession(directory: fixture.profile, executable: fixture.executable)
        defer { session.stop() }
        try session.start()
        let pid = try fixture.waitForPID()
        XCTAssertThrowsError(try session.checkFinished()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Finish signing in"))
        }

        let record = try jsonObject(Data(contentsOf: fixture.output("record")))
        XCTAssertEqual(record["arguments"] as? [String], ["auth", "login", "--claudeai"])
        XCTAssertEqual(record["overrideNames"] as? [String], ["CLAUDE_CONFIG_DIR"])
        let resolvedProfile = try fixture.resolvedProfilePath()
        XCTAssertEqual(record["config"] as? String, resolvedProfile)
        XCTAssertEqual(record["cwd"] as? String, resolvedProfile)
        XCTAssertEqual(record["rawConfig"] as? String, session.installation.configurationEnvironment["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(record["user"] as? String, session.installation.keychainAccount)

        XCTAssertThrowsError(try session.submit(code: " \n "))
        XCTAssertThrowsError(try session.submit(code: "first\nsecond"))
        XCTAssertThrowsError(try session.submit(code: "first\rsecond"))
        try session.submit(code: " \tSYNTHETIC-CODE#state \n")
        try fixture.waitForExit(pid)
        try session.checkFinished()
        XCTAssertEqual(try String(contentsOf: fixture.output("code"), encoding: .utf8), "SYNTHETIC-CODE#state\n")
        XCTAssertThrowsError(try session.submit(code: "already-finished"))
        fixture.assertChildStopped(pid)
    }

    func testCancellationReapsChildEvenWhenChildIgnoresTermination() throws {
        let fixture = try Fixture(script: """
        import os, signal, time
        from pathlib import Path
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        Path(__file__ + '.pid').write_text(str(os.getpid()))
        time.sleep(60)
        """)
        defer { fixture.remove() }
        let session = try LoginSession(directory: fixture.profile, executable: fixture.executable)
        defer { session.stop() }
        try session.start()
        let pid = try fixture.waitForPID()
        session.stop()
        fixture.assertChildStopped(pid)
    }

    func testFailedLoginReturnsGenericErrorWithoutRawProcessOutput() throws {
        let secret = "synthetic-secret-must-not-reach-error"
        let fixture = try Fixture(script: """
        import os, sys
        from pathlib import Path
        Path(__file__ + '.pid').write_text(str(os.getpid()))
        print('\(secret)', flush=True)
        print('\(secret)', file=sys.stderr, flush=True)
        sys.exit(23)
        """)
        defer { fixture.remove() }
        let session = try LoginSession(directory: fixture.profile, executable: fixture.executable)
        defer { session.stop() }
        try session.start()
        let pid = try fixture.waitForPID()
        try fixture.waitForExit(pid)
        XCTAssertThrowsError(try session.checkFinished()) { error in
            XCTAssertTrue(error.localizedDescription.contains("did not complete sign-in"))
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }
        fixture.assertChildStopped(pid)
        let profileFiles = try FileManager.default.contentsOfDirectory(atPath: fixture.profile.path)
        XCTAssertTrue(profileFiles.isEmpty, "Login process output must not be persisted in the profile.")
    }

    func testMissingExecutableFailsStartAndCanBeStopped() throws {
        let fixture = try Fixture(script: "raise RuntimeError('must not run')")
        defer { fixture.remove() }
        let missing = fixture.directory.appendingPathComponent("missing-claude")
        let session = try LoginSession(directory: fixture.profile, executable: missing)
        XCTAssertThrowsError(try session.start())
        session.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output("pid").path))
    }

    func testSubmittingToClosedInputThrowsWithoutSIGPIPEAndChildIsReaped() throws {
        let fixture = try Fixture(script: """
        import os, time
        from pathlib import Path
        os.close(0)
        Path(__file__ + '.pid').write_text(str(os.getpid()))
        time.sleep(60)
        """)
        defer { fixture.remove() }
        let session = try LoginSession(directory: fixture.profile, executable: fixture.executable)
        defer { session.stop() }
        try session.start()
        let pid = try fixture.waitForPID()
        XCTAssertThrowsError(try session.submit(code: "synthetic-code"))
        session.stop()
        fixture.assertChildStopped(pid)
    }

    private struct EnvironmentOverrides {
        private let originals: [String: String?]

        init(_ values: [String: String]) {
            originals = Dictionary(uniqueKeysWithValues: values.keys.map { key in
                (key, getenv(key).map { String(cString: $0) })
            })
            for (key, value) in values { XCTAssertEqual(setenv(key, value, 1), 0) }
        }

        func restore() {
            for (key, value) in originals {
                if let value { XCTAssertEqual(setenv(key, value, 1), 0) }
                else { XCTAssertEqual(unsetenv(key), 0) }
            }
        }
    }

    private struct Fixture {
        let directory: URL
        let executable: URL
        var profile: URL { directory.appendingPathComponent("profile") }

        init(script: String) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("switchboard-login-test-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            executable = directory.appendingPathComponent("fixture")
            try Data(("#!/usr/bin/env python3\n" + script + "\n").utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        func output(_ suffix: String) -> URL { URL(fileURLWithPath: executable.path + "." + suffix) }

        func resolvedProfilePath() throws -> String {
            let resolved = try XCTUnwrap(realpath(profile.path, nil))
            defer { free(resolved) }
            return String(cString: resolved)
        }

        func waitForPID() throws -> Int32 {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let contents = try? String(contentsOf: output("pid"), encoding: .utf8), let pid = Int32(contents) {
                    return pid
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            XCTFail("Synthetic login child did not start.")
            throw SwitchboardError.message("Synthetic login child did not start.")
        }

        func waitForExit(_ pid: Int32) throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while ProcessInfo.processInfo.systemUptime < deadline {
                if kill(pid, 0) == -1, errno == ESRCH { return }
                Thread.sleep(forTimeInterval: 0.01)
            }
            XCTFail("Synthetic login child did not exit.")
            throw SwitchboardError.message("Synthetic login child did not exit.")
        }

        func assertChildStopped(_ pid: Int32, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(kill(pid, 0), -1, file: file, line: line)
            XCTAssertEqual(errno, ESRCH, file: file, line: line)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
