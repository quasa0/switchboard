import Foundation
import Security
import CryptoKit
import Darwin

public protocol SecretStore: AnyObject {
    func read(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

public final class KeychainStore: SecretStore {
    public init() {}
    private func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    public func read(service: String, account: String) throws -> Data? {
        if Self.isClaudeService(service) { return try readClaudeCredential(service: service, account: account) }
        var q = query(service, account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return result as? Data
    }
    public func write(_ data: Data, service: String, account: String) throws {
        if Self.isClaudeService(service) {
            try writeClaudeCredential(data, service: service, account: account)
            return
        }
        let q = query(service, account)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var new = q
            new[kSecValueData as String] = data
            new[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(new as CFDictionary, nil))
        } else { try check(status) }
    }
    public func delete(service: String, account: String) throws {
        if Self.isClaudeService(service) {
            try deleteClaudeCredential(service: service, account: account)
            return
        }
        let status = SecItemDelete(query(service, account) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Error \(status)"
            throw SwitchboardError.message("Keychain: \(detail)")
        }
    }
}

public struct ClaudeInstallation: Sendable {
    public let configDirectory: URL
    public let configFile: URL
    public let credentialFile: URL
    public let keychainService: String
    public let keychainAccount: String
    public let configurationEnvironment: [String: String]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        let custom = environment["CLAUDE_CONFIG_DIR"]
        configurationEnvironment = environment.filter { ["CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR"].contains($0.key) }
        configDirectory = custom.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
        configFile = custom == nil ? home.appendingPathComponent(".claude.json") : configDirectory.appendingPathComponent(".claude.json")
        let secureDirectory = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] ?? custom ?? ""
        let fileDirectory = secureDirectory.isEmpty ? home.appendingPathComponent(".claude")
            : URL(fileURLWithPath: secureDirectory.precomposedStringWithCanonicalMapping)
        credentialFile = fileDirectory.appendingPathComponent(".credentials.json")
        if secureDirectory.isEmpty { keychainService = "Claude Code-credentials" }
        else {
            let digest = SHA256.hash(data: Data(secureDirectory.precomposedStringWithCanonicalMapping.utf8))
            keychainService = "Claude Code-credentials-" + digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        }
        let username = environment["USER"] ?? NSUserName()
        keychainAccount = username.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) == nil ? "claude-code-user" : username
    }

    public static func isolated(at directory: URL) -> ClaudeInstallation {
        ClaudeInstallation(environment: ["CLAUDE_CONFIG_DIR": directory.path, "USER": NSUserName()])
    }
}

func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw SwitchboardError.message("Claude's saved login has an unexpected format. Nothing was changed.")
    }
    return object
}

func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
}

func cliCredentialData(_ object: [String: Any]) throws -> Data {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let json = String(decoding: data, as: UTF8.self)
    // Claude reads with `security ... -w`, which hex-encodes the entire password if
    // any byte is nonprintable. Compact ASCII JSON keeps that CLI output parseable.
    let printable = json.utf16.map { unit -> String in
        if (32...126).contains(unit) { return String(UnicodeScalar(unit)!) }
        return String(format: "\\u%04x", unit)
    }.joined()
    return Data(printable.utf8)
}

func readObject(_ url: URL) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
    return try jsonObject(Data(contentsOf: url))
}

public func privateWrite(_ data: Data, to url: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    // The temporary file is private before any bytes are written. rename is atomic on this volume.
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".switchboard-\(UUID().uuidString)")
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw SwitchboardError.message("Cannot create a private settings file.") }
    defer { close(fd); try? manager.removeItem(at: temporary) }
    try data.withUnsafeBytes { bytes in
        var position = 0
        while position < bytes.count {
            let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: position), bytes.count - position)
            if count < 0 { if errno == EINTR { continue }; throw SwitchboardError.message("Cannot write settings.") }
            guard count > 0 else { throw SwitchboardError.message("Incomplete settings write.") }
            position += count
        }
    }
    guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else {
        throw SwitchboardError.message("Cannot save settings atomically.")
    }
}

public final class ClaudeLoginStore {
    public let installation: ClaudeInstallation
    public let secrets: SecretStore
    public init(installation: ClaudeInstallation, secrets: SecretStore) {
        self.installation = installation; self.secrets = secrets
    }
    public func snapshot() throws -> CredentialSnapshot? {
        let config = try readObject(installation.configFile)
        guard let data = try credentialState().data,
              let oauth = try jsonObject(data)["claudeAiOauth"], let identity = config["oauthAccount"] else { return nil }
        let snapshot = try CredentialSnapshot(oauth: jsonData(oauth), identity: jsonData(identity))
        _ = try snapshot.validated()
        return snapshot
    }
    public func apply(_ snapshot: CredentialSnapshot) throws {
        _ = try snapshot.validated()
        let originalConfig = try readObject(installation.configFile)
        var config = originalConfig
        let original = try credentialState()
        var credentials = try original.data.map(jsonObject) ?? [:]
        // These are Anthropic account credentials. MCP and unrelated entries remain intact.
        for key in ["organizationUuid", "trustedDeviceToken", "enterpriseGateway", "designOauth"] {
            credentials.removeValue(forKey: key)
        }
        credentials["claudeAiOauth"] = try jsonObject(snapshot.oauth)
        config["oauthAccount"] = try jsonObject(snapshot.identity)
        // Match the installed CLI's account-scoped cache invalidation on account changes.
        for key in ["additionalModelOptionsCache", "additionalModelOptionsAnsweredAt", "additionalModelCostsCache",
                    "modelAccessCache", "orgModelDefaultCache", "cachedArtifactRoster", "artifactRosterDenied",
                    "lastSeenOrgDefaultUpdatedAt", "clientDataCache", "clientDataCacheSlots", "autoCompactWindowsCache",
                    "cachedUsageUtilization", "githubWebConnectionStatusCache", "startupPrefetchedAt"] {
            config.removeValue(forKey: key)
        }
        let replacement = try cliCredentialData(credentials)
        // Claude does not take our account lock. Detect changes across both stores
        // before writing; never choose a different destination halfway through a switch.
        guard try credentialState() == original,
              NSDictionary(dictionary: originalConfig).isEqual(to: try readObject(installation.configFile)) else {
            throw loginChanged()
        }
        try writeCredential(replacement, to: original.backend)
        do {
            guard try credentialState() == CredentialState(backend: original.backend, data: replacement),
                  NSDictionary(dictionary: originalConfig).isEqual(to: try readObject(installation.configFile)) else {
                throw loginChanged()
            }
            try privateWrite(try jsonData(config), to: installation.configFile)
        } catch {
            let failure = error
            // Do not overwrite a login another process wrote after our credential write.
            guard try credentialState() == CredentialState(backend: original.backend, data: replacement) else {
                throw loginChanged()
            }
            do { try writeCredential(original.data, to: original.backend) }
            catch {
                throw SwitchboardError.message("The switch failed and Claude's credentials could not be restored. Your previous login is saved in Switchboard. Quit Claude Code, then reopen Switchboard to recover.")
            }
            throw failure
        }
    }

    enum CredentialBackend: Equatable { case keychain, file }
    struct CredentialState: Equatable {
        let backend: CredentialBackend
        let data: Data?
    }

    func credentialState() throws -> CredentialState {
        // Claude Code prefers any existing Keychain entry to its plaintext fallback.
        // An inaccessible Keychain is an error, not evidence that the entry is absent.
        if let data = try secrets.read(service: installation.keychainService, account: installation.keychainAccount) {
            return CredentialState(backend: .keychain, data: data)
        }
        if let data = try readCredentialFile() { return CredentialState(backend: .file, data: data) }
        // Never create a new plaintext store. New profiles continue to use Keychain.
        return CredentialState(backend: .keychain, data: nil)
    }

    private var credentialFile: URL { installation.credentialFile }

    private func readCredentialFile() throws -> Data? {
        // Avoid following credential symlinks or blocking on a FIFO. Read through the
        // checked descriptor, with an allocation bound even if the file grows.
        let fd = open(credentialFile.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw SwitchboardError.message("Claude's .credentials.json could not be read safely. No login was changed.")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1,
              info.st_size <= 1_048_576 else {
            throw SwitchboardError.message("Claude's .credentials.json must be a regular file owned by you, without links, and at most 1 MB. No login was changed.")
        }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else {
            throw SwitchboardError.message("Claude's .credentials.json exceeds 1 MB. No login was changed.")
        }
        _ = try jsonObject(data)
        return data
    }

    private func writeCredential(_ data: Data?, to backend: CredentialBackend) throws {
        switch backend {
        case .keychain:
            if let data { try secrets.write(data, service: installation.keychainService, account: installation.keychainAccount) }
            else { try secrets.delete(service: installation.keychainService, account: installation.keychainAccount) }
        case .file:
            // File storage is selected only for an existing fallback. Atomic replacement
            // preserves sibling credentials and sets owner-only permissions before writing.
            guard let data else { throw loginChanged() }
            try privateWrite(data, to: credentialFile)
        }
    }

    private func loginChanged() -> SwitchboardError {
        .message("Claude's login changed during the switch. Quit Claude Code and refresh before trying again. Saved accounts are intact.")
    }
}
