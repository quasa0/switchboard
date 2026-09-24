import Foundation
import Security
import Darwin

extension KeychainStore {
    static func isClaudeService(_ service: String) -> Bool {
        service == "Claude Code-credentials" || service.hasPrefix("Claude Code-credentials-")
    }

    /// Checks existing helper access without widening ACL or partition permissions.
    public func allowClaudeCLI(service: String, account: String) throws {
        guard Self.isClaudeService(service) else { return }
        _ = try readClaudeCredential(service: service, account: account)
    }

    func readClaudeCredential(service: String, account: String) throws -> Data? {
        let helper = ClaudeCredentialHelper()
        // TEMP-COMPAT 2026-09-23: migrate Claude entries created by Switchboard v0.1.0/v0.1.1 on this Mac from app-owned partitions/trusted-app ACLs to helper-created entries. Persist their complete original data in the app's migration vault before deletion so an interrupted replacement can resume. Remove both migration branches, ClaudeMigration, the migration vault helpers, nativeClaudeCredential(), nativeDeleteClaudeCredential(), hasClaudeHelperPartition(), and related migration smoke coverage only after every entry created by those versions on this Mac is verified helper-readable and com.quasa0.switchboard.migration contains no pending backups. Keep helper-only credential reads and writes.
        let backupAccount = migrationAccount(service: service, account: account)
        if let pending = try read(service: Self.migrationService, account: backupAccount) {
            let migration = try JSONDecoder().decode(ClaudeMigration.self, from: pending)
            guard migration.service == service, migration.account == account else {
                throw SwitchboardError.message("Claude's saved credential repair belongs to another account. Nothing was changed.")
            }
            return try finishClaudeMigration(migration, backupAccount: backupAccount)
        }
        guard let helperPartition = try hasClaudeHelperPartition(service: service, account: account) else { return nil }
        if !helperPartition {
            guard let original = try nativeClaudeCredential(service: service, account: account) else { return nil }
            let migration = ClaudeMigration(service: service, account: account, original: original,
                                            target: try cliCredentialData(jsonObject(original)))
            // Preflight the helper's input bound before persisting or deleting anything.
            _ = try ClaudeCredentialHelper.writeCommand(migration.target, service: service, account: account, update: false)
            try write(JSONEncoder().encode(migration), service: Self.migrationService, account: backupAccount)
            return try finishClaudeMigration(migration, backupAccount: backupAccount)
        }
        guard let data = try helper.read(service: service, account: account) else { return nil }
        // TEMP-COMPAT 2026-09-23: normalize nonprintable JSON left by Switchboard v0.1.0/v0.1.1 for this Mac's Claude CLI. Remove this normalization branch and ClaudeCredentialHelper's hex-output decoding after every entry written by those versions on this Mac has been migrated and verified through security -w. Keep compact ASCII encoding for all future writes.
        let normalized = try cliCredentialData(jsonObject(data))
        if normalized != data {
            try helper.write(normalized, service: service, account: account)
            guard let verified = try helper.read(service: service, account: account), verified == normalized else {
                throw SwitchboardError.message("Claude's Keychain credential format could not be verified. Refresh again.")
            }
            return verified
        }
        return data
    }

    private static let migrationService = "com.quasa0.switchboard.migration"

    private struct ClaudeMigration: Codable {
        let service: String
        let account: String
        let original: Data
        let target: Data
    }

    private func migrationAccount(service: String, account: String) -> String {
        Data((service + "\u{0000}" + account).utf8).base64EncodedString()
    }

    private func finishClaudeMigration(_ migration: ClaudeMigration, backupAccount: String) throws -> Data {
        let helper = ClaudeCredentialHelper()
        let originalObject = try jsonObject(migration.original)
        guard NSDictionary(dictionary: originalObject).isEqual(to: try jsonObject(migration.target)),
              migration.target.allSatisfy({ (32...126).contains($0) }) else {
            throw SwitchboardError.message("Claude's saved credential repair is invalid. Nothing was changed.")
        }
        _ = try ClaudeCredentialHelper.writeCommand(migration.target, service: migration.service,
                                                    account: migration.account, update: false)
        if let helperPartition = try hasClaudeHelperPartition(service: migration.service, account: migration.account) {
            if helperPartition {
                guard let current = try helper.read(service: migration.service, account: migration.account),
                      NSDictionary(dictionary: originalObject).isEqual(to: try jsonObject(current)) else {
                    throw changedDuringMigration()
                }
                if current != migration.target {
                    try helper.write(migration.target, service: migration.service, account: migration.account)
                }
            } else {
                guard let current = try nativeClaudeCredential(service: migration.service, account: migration.account),
                      NSDictionary(dictionary: originalObject).isEqual(to: try jsonObject(current)) else {
                    throw changedDuringMigration()
                }
                // A fresh helper-created item gets security(1)'s own default ACL and partition.
                // Updating the old item would retain an app-only trusted-application ACL.
                try nativeDeleteClaudeCredential(service: migration.service, account: migration.account)
                try helper.create(migration.target, service: migration.service, account: migration.account)
            }
        } else {
            // Resume a crash after deletion. Create-only must not replace a concurrent new login.
            try helper.create(migration.target, service: migration.service, account: migration.account)
        }
        guard let verified = try helper.read(service: migration.service, account: migration.account),
              verified == migration.target,
              NSDictionary(dictionary: originalObject).isEqual(to: try jsonObject(verified)) else {
            throw SwitchboardError.message("Claude's credential repair could not be verified. Its original data remains in Switchboard's migration vault; refresh to retry.")
        }
        // A retained backup is safe: the next read rechecks the current data before cleanup.
        try? delete(service: Self.migrationService, account: backupAccount)
        return verified
    }

    private func changedDuringMigration() -> SwitchboardError {
        .message("Claude's login changed during credential repair. Nothing was overwritten. The original data remains in Switchboard's migration vault.")
    }

    private func nativeDeleteClaudeCredential(service: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try claudeMetadataCheck(status) }
    }

    func writeClaudeCredential(_ data: Data, service: String, account: String) throws {
        try ClaudeCredentialHelper().write(cliCredentialData(jsonObject(data)), service: service, account: account)
    }

    func deleteClaudeCredential(service: String, account: String) throws {
        try ClaudeCredentialHelper().delete(service: service, account: account)
    }

    private func nativeClaudeCredential(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try claudeMetadataCheck(status)
        return result as? Data
    }

    /// Reads ACL metadata only. Trusted applications cannot bypass partition checks.
    private func hasClaudeHelperPartition(service: String, account: String) throws -> Bool? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try claudeMetadataCheck(status)
        guard let result else { throw SwitchboardError.message("Claude's Keychain metadata is unavailable.") }
        let item = unsafeBitCast(result, to: SecKeychainItem.self)
        var access: SecAccess?
        try claudeMetadataCheck(SecKeychainItemCopyAccess(item, &access))
        guard let access else { throw SwitchboardError.message("Claude's Keychain access metadata is unavailable.") }
        var entries: CFArray?
        try claudeMetadataCheck(SecAccessCopyACLList(access, &entries))
        for acl in (entries as? [SecACL]) ?? [] {
            let authorizations = SecACLCopyAuthorizations(acl) as? [String] ?? []
            guard authorizations.contains(kSecACLAuthorizationPartitionID as String) else { continue }
            var applications: CFArray?
            var description: CFString?
            var selector = SecKeychainPromptSelector()
            try claudeMetadataCheck(SecACLCopyContents(acl, &applications, &description, &selector))
            guard let encoded = description as String?, let data = ClaudeCredentialHelper.decodeHex(Data(encoded.utf8)),
                  let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let partitions = plist["Partitions"] as? [String] else {
                throw SwitchboardError.message("Claude's Keychain partition metadata is unsupported.")
            }
            // security(1) uses apple-tool:, which is distinct from other Apple's apple: processes.
            return partitions.contains("apple-tool:")
        }
        return false
    }

    private func claudeMetadataCheck(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw SwitchboardError.message("Cannot read Claude's Keychain access metadata (\(status)). Unlock your login Keychain, then refresh.")
        }
    }
}

struct ClaudeCredentialHelper {
    let executable: URL
    let timeout: TimeInterval

    init(executable: URL = URL(fileURLWithPath: "/usr/bin/security"), timeout: TimeInterval = 5) {
        self.executable = executable
        self.timeout = timeout
    }

    func read(service: String, account: String) throws -> Data? {
        let result = try run(arguments: ["find-generic-password", "-w", "-s", service, "-a", account])
        if result.status == 44 { return nil }
        try checkStatus(result.status)
        var data = result.data
        if data.last == 10 { data.removeLast() }
        if (try? jsonObject(data)) != nil { return data }
        // TEMP-COMPAT 2026-09-23: decode security -w's hex output for nonprintable credentials left by Switchboard v0.1.0/v0.1.1 on this Mac. Remove this branch and testReadDecodesPreviouslyHexEncodedCredentialOutput after all entries written by those versions are normalized and verified helper-readable. Keep decodeHex only while partition migration still uses it.
        if let decoded = Self.decodeHex(data), (try? jsonObject(decoded)) != nil { return decoded }
        throw SwitchboardError.message("Claude's Keychain helper returned an unreadable credential format.")
    }

    func write(_ data: Data, service: String, account: String) throws {
        let command = try Self.writeCommand(data, service: service, account: account)
        let result = try run(arguments: ["-q", "-i"], input: command)
        try checkStatus(result.status)
    }

    func create(_ data: Data, service: String, account: String) throws {
        let command = try Self.writeCommand(data, service: service, account: account, update: false)
        let result = try run(arguments: ["-q", "-i"], input: command)
        try checkStatus(result.status)
    }

    func delete(service: String, account: String) throws {
        let result = try run(arguments: ["delete-generic-password", "-s", service, "-a", account])
        if result.status != 44 { try checkStatus(result.status) }
    }

    static func writeCommand(_ data: Data, service: String, account: String, update: Bool = true) throws -> Data {
        func argument(_ value: String) throws -> String {
            guard value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw SwitchboardError.message("The Keychain service or account name contains unsupported characters.")
            }
            return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let line = try "add-generic-password\(update ? " -U" : "") -s \(argument(service)) -a \(argument(account)) -X \(hex)\n"
        let command = Data(line.utf8)
        // security -i has a fixed 4096-byte command buffer. Reject before launching or writing.
        guard command.count < 4096 else {
            throw SwitchboardError.message("Claude's combined Keychain credentials exceed the security helper's command limit. Nothing was changed.")
        }
        return command
    }

    static func decodeHex(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count.isMultiple(of: 2) else { return nil }
        let bytes = Array(data)
        var decoded = Data(capacity: bytes.count / 2)
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 65 + 10
            case 97...102: return byte - 97 + 10
            default: return nil
            }
        }
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
            decoded.append(high * 16 + low)
        }
        return decoded
    }

    private func checkStatus(_ status: Int32) throws {
        guard status == 0 else {
            throw SwitchboardError.message("Claude's Keychain helper failed (\(status)). Unlock your login Keychain, then refresh.")
        }
    }

    private func run(arguments: [String], input: Data? = nil) throws -> (status: Int32, data: Data) {
        let process = Process()
        let output = Pipe()
        let inputPipe = input == nil ? nil : Pipe()
        process.executableURL = executable
        process.arguments = arguments
        if let inputPipe { process.standardInput = inputPipe }
        else { process.standardInput = FileHandle.nullDevice }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var started = false
        defer {
            if started {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            try? inputPipe?.fileHandleForWriting.close()
            try? inputPipe?.fileHandleForReading.close()
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        do { try process.run(); started = true }
        catch { throw SwitchboardError.message("Cannot start Apple's Keychain helper.") }
        try? output.fileHandleForWriting.close()
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw SwitchboardError.message("Cannot read Apple's Keychain helper.")
        }
        if let input, let inputPipe {
            guard fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) >= 0 else {
                throw SwitchboardError.message("Cannot open Apple's Keychain helper input.")
            }
            do {
                try inputPipe.fileHandleForWriting.write(contentsOf: input)
                try inputPipe.fileHandleForWriting.close()
            } catch { throw SwitchboardError.message("Cannot send credentials to Apple's Keychain helper.") }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var reachedEOF = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= 1_048_576 else {
                    throw SwitchboardError.message("Claude's Keychain helper returned excessive output.")
                }
            } else if count == 0 { reachedEOF = true }
            else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                throw SwitchboardError.message("Cannot read Apple's Keychain helper output.")
            }
            if reachedEOF && !process.isRunning { break }
            usleep(10_000)
        }
        guard reachedEOF, !process.isRunning else {
            throw SwitchboardError.message("Claude's Keychain helper timed out. Unlock your login Keychain and allow its access prompt, then refresh.")
        }
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
