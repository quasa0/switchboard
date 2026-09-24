import Foundation
import Security
import SwitchboardCore
import Darwin

enum SmokeCheck {
    // Synthetic credentials, unique Keychain services, temporary config files. No real login is read.
    static func keychainRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("switchboard-smoke-\(UUID().uuidString)")
        let installation = ClaudeInstallation.isolated(at: root.appendingPathComponent("claude"))
        let vaultService = "com.quasa0.switchboard.smoke.\(UUID().uuidString)"
        let migrationAccount = Data((installation.keychainService + "\u{0000}" + installation.keychainAccount).utf8).base64EncodedString()
        let secrets = KeychainStore()
        let repository = AccountRepository(directory: root.appendingPathComponent("app"), secrets: secrets,
                                           installation: installation, vaultService: vaultService)
        defer {
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: vaultService] as CFDictionary)
            try? secrets.delete(service: installation.keychainService, account: installation.keychainAccount)
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: "com.quasa0.switchboard.migration",
                           kSecAttrAccount: migrationAccount] as CFDictionary)
            try? FileManager.default.removeItem(at: root)
        }
        func fixture(_ id: String, token: String) throws -> CredentialSnapshot {
            let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
            return try CredentialSnapshot(
                oauth: JSONSerialization.data(withJSONObject: ["accessToken": token, "refreshToken": "synthetic-refresh-\(id)",
                    "scopes": ["user:inference"], "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x"], options: options),
                identity: JSONSerialization.data(withJSONObject: ["accountUuid": id, "emailAddress": "\(id)@example.invalid",
                    "organizationUuid": "synthetic-org-\(id)"], options: options))
        }
        func checkCLIRead(expectedToken: String) throws {
            guard let native = try secrets.read(service: installation.keychainService, account: installation.keychainAccount),
                  let nativeObject = try JSONSerialization.jsonObject(with: native) as? [String: Any] else {
                throw SwitchboardError.message("Synthetic native Keychain read failed.")
            }
            let cli = try securityCredentialData(service: installation.keychainService, account: installation.keychainAccount)
            guard let cliObject = try JSONSerialization.jsonObject(with: cli) as? [String: Any],
                  NSDictionary(dictionary: nativeObject).isEqual(to: cliObject),
                  let oauth = cliObject["claudeAiOauth"] as? [String: Any],
                  oauth["accessToken"] as? String == expectedToken else {
                throw SwitchboardError.message("Synthetic security -w credential read did not match the selected login.")
            }
        }
        let a = try fixture("a", token: "synthetic-a"), b = try fixture("b", token: "synthetic-b")
        let unrelated: [String: Any] = ["mcpOAuth": ["synthetic-server-🧪": ["label": "Café 🚀\n\t\u{0000} \"quoted\" \\",
                                                                               "accessToken": "synthetic-mcp-token"]]]
        // TEMP-COMPAT 2026-09-23: verify recovery of app-created Keychain entries for
        // Switchboard 0.1.0/0.1.1 users until every such entry on this Mac is migrated.
        // Once verified, remove this oldData/oldStatus/migrated fixture with the migration.
        let oldData = try JSONSerialization.data(withJSONObject: unrelated, options: [.prettyPrinted])
        let oldStatus = SecItemAdd([kSecClass: kSecClassGenericPassword,
                                   kSecAttrService: installation.keychainService,
                                   kSecAttrAccount: installation.keychainAccount,
                                   kSecValueData: oldData] as CFDictionary, nil)
        guard oldStatus == errSecSuccess,
              let migrated = try secrets.read(service: installation.keychainService, account: installation.keychainAccount),
              let migratedObject = try JSONSerialization.jsonObject(with: migrated) as? [String: Any],
              NSDictionary(dictionary: unrelated).isEqual(to: migratedObject),
              let cliMigrated = try JSONSerialization.jsonObject(with: securityCredentialData(
                service: installation.keychainService, account: installation.keychainAccount)) as? [String: Any],
              NSDictionary(dictionary: unrelated).isEqual(to: cliMigrated) else {
            throw SwitchboardError.message("An older app-created credential could not be migrated for Claude.")
        }
        try secrets.write(JSONSerialization.data(withJSONObject: unrelated),
                          service: installation.keychainService, account: installation.keychainAccount)
        try repository.withLock {
            try repository.live.apply(a)
            try checkCLIRead(expectedToken: "synthetic-a")
            let first = try repository.capture(a, label: "Synthetic A")
            let second = try repository.capture(b, label: "Synthetic B")
            try repository.activate(second.id)
            try checkCLIRead(expectedToken: "synthetic-b")
            guard try repository.state().activeID == second.id else { throw SwitchboardError.message("Switch B failed.") }
            let rotated = try fixture("b", token: "synthetic-b-rotated")
            try repository.live.apply(rotated)
            try repository.activate(first.id)
            try checkCLIRead(expectedToken: "synthetic-a")
            try repository.activate(second.id)
            try checkCLIRead(expectedToken: "synthetic-b-rotated")
            guard try repository.live.snapshot() == rotated else { throw SwitchboardError.message("Token rotation was lost.") }
            try repository.remove(first.id)
            guard try repository.state().accounts.count == 1 else { throw SwitchboardError.message("Removal failed.") }
        }
        try secrets.delete(service: installation.keychainService, account: installation.keychainAccount)
        let status = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: vaultService] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SwitchboardError.message("Cannot clean the synthetic smoke-test Keychain service.")
        }
    }

    private static func securityCredentialData(service: String, account: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-w", "-s", service, "-a", account]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        var started = false
        defer {
            if started {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        try process.run()
        started = true
        try output.fileHandleForWriting.close()
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw SwitchboardError.message("Cannot read the synthetic security command output.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var reachedEOF = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= 65_536 else {
                    throw SwitchboardError.message("Synthetic security command returned excessive output.")
                }
            } else if count == 0 {
                reachedEOF = true
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                throw SwitchboardError.message("Cannot read the synthetic security command output.")
            }
            if reachedEOF && !process.isRunning { break }
            usleep(10_000)
        }
        guard reachedEOF, !process.isRunning else {
            throw SwitchboardError.message("Synthetic security command timed out.")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SwitchboardError.message("Synthetic security command could not read its test credential.")
        }
        return data
    }
}
