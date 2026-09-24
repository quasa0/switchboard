import Foundation
import Darwin

public final class CodexLoginSession {
    public let installation: CodexInstallation
    private let process = Process()
    private var started = false

    public init(directory: URL, executable: URL) throws {
        installation = .isolated(at: directory)
        guard !FileManager.default.fileExists(atPath: installation.authFile.path) else {
            throw SwitchboardError.message("The new ChatGPT sign-in folder is not empty. Start a new sign-in.")
        }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("home"), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try privateWrite(Data("cli_auth_credentials_store = \"file\"\n".utf8), to: installation.configFile)
        process.executableURL = executable
        process.arguments = ["login", "-c", "cli_auth_credentials_store=\"file\"",
            "-c", "features.plugins=false", "-c", "features.apps=false", "-c", "features.hooks=false",
            "-c", "model_provider=\"openai\"", "-c", "chatgpt_base_url=\"https://chatgpt.com/backend-api\"",
            "-c", "analytics.enabled=false"]
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("OPENAI_") || key.hasPrefix("CODEX_") || key.hasPrefix("CHATGPT_") || key == "RUST_LOG" {
            environment.removeValue(forKey: key)
        }
        environment.merge(installation.configurationEnvironment) { _, new in new }
        environment["CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED"] = "1"
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        // The official CLI opens the browser. OAuth URLs and codes never enter app logs.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }

    public func start() throws {
        guard !started else { throw SwitchboardError.message("This ChatGPT sign-in has already started.") }
        // Codex cancels an existing listener on this port. Do not disrupt somebody else's sign-in.
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SwitchboardError.message("Cannot check the ChatGPT sign-in callback port.") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(1455).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let available = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        close(descriptor)
        guard available else {
            throw SwitchboardError.message("Another Codex sign-in is using localhost:1455. Finish or cancel it before starting another.")
        }
        try process.run()
        started = true
    }

    public func checkFinished() throws {
        guard started, !process.isRunning else {
            throw SwitchboardError.message("Finish signing in in the browser, then choose Save new login.")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, try CodexLoginStore(installation: installation).snapshot() != nil else {
            throw SwitchboardError.message("Codex did not complete ChatGPT sign-in. Cancel and try again.")
        }
    }

    public func stop() {
        guard started else { return }
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
    }
    deinit { stop() }
}

public enum CodexExecutable {
    public static func find(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        var paths = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", home.appendingPathComponent(".local/bin/codex").path]
        paths += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            let executable = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            if executable.lastPathComponent == "codex.js" {
                #if arch(arm64)
                let package = "codex-darwin-arm64", target = "aarch64-apple-darwin"
                #else
                let package = "codex-darwin-x64", target = "x86_64-apple-darwin"
                #endif
                let native = executable.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("node_modules/@openai/\(package)/vendor/\(target)/bin/codex")
                if FileManager.default.isExecutableFile(atPath: native.path) { return native }
                // A native child keeps cancellation and reaping within the app's process ownership.
                continue
            }
            return executable
        }
        throw SwitchboardError.message("Codex CLI is not installed in a supported location. Install it from OpenAI, then reopen Switchboard.")
    }
}
