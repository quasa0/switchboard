import Foundation
import Darwin

/// Reads subscription limits through the installed, unmodified Claude Code binary.
/// No user message is sent, so this operation does not request model inference.
public struct CLIUsageClient: Sendable {
    public let executable: URL
    private let timeout: TimeInterval

    public init(executable: URL) {
        self.executable = executable
        self.timeout = 30
    }

    init(executable: URL, timeout: TimeInterval) {
        self.executable = executable
        self.timeout = timeout
    }

    public func fetch(installation: ClaudeInstallation) async throws -> UsageSnapshot {
        let operation = UsageProcess(executable: executable, installation: installation, timeout: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try operation.run() })
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }

    // Kept separate from process execution so API shape changes can be tested without credentials.
    static func parseUsageResponse(_ data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        let reply: UsageReply
        do { reply = try JSONDecoder().decode(UsageReply.self, from: data) }
        catch { throw SwitchboardError.message("Claude Code returned an unsupported usage format. Update Claude Code, then refresh again.") }
        guard reply.type == "control_response", reply.response.subtype == "success",
              let payload = reply.response.response else {
            throw SwitchboardError.message("Claude Code could not read subscription usage. Check the saved login, then refresh again.")
        }
        guard payload.rateLimitsAvailable == true else {
            throw SwitchboardError.message("Usage is unavailable for this login. Sign in through Claude Code with a Claude subscription.")
        }
        guard let limits = payload.rateLimits else {
            throw SwitchboardError.message("Claude recognized this subscription but did not return its usage. Refresh again.")
        }
        return UsageSnapshot(fiveHour: try limits.fiveHour?.window(),
                             sevenDay: try limits.sevenDay?.window(),
                             sevenDaySonnet: try limits.sevenDaySonnet?.window(),
                             sevenDayOpus: try limits.sevenDayOpus?.window(),
                             fetchedAt: fetchedAt,
                             modelScoped: try limits.namedWindows())
    }
}

private struct UsageReply: Decodable {
    var type: String
    var response: ResultBody
    struct ResultBody: Decodable {
        var subtype: String
        var response: Payload?
    }
    struct Payload: Decodable {
        var rateLimitsAvailable: Bool?
        var rateLimits: Limits?
        enum CodingKeys: String, CodingKey {
            case rateLimitsAvailable = "rate_limits_available"
            case rateLimits = "rate_limits"
        }
    }
    struct Limits: Decodable {
        var fiveHour: Window?
        var sevenDay: Window?
        var sevenDaySonnet: Window?
        var sevenDayOpus: Window?
        var rows: [LimitRow]?
        var modelScoped: [NamedWindow]?
        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour", sevenDay = "seven_day"
            case sevenDaySonnet = "seven_day_sonnet", sevenDayOpus = "seven_day_opus"
            case rows = "limits"
            case modelScoped = "model_scoped"
        }

        func namedWindows() throws -> [NamedUsageWindow] {
            // Current CLI responses carry both server rows and a derived model_scoped
            // projection. Feature flags can hide the projection while server rows remain.
            var result = try (rows ?? []).compactMap { row -> NamedUsageWindow? in
                guard row.kind == "weekly_scoped", let name = row.scope?.model?.displayName,
                      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let window = try Window(utilization: row.percent, resetsAt: row.resetsAt).window() else { return nil }
                return NamedUsageWindow(name: name, window: window)
            }
            for item in modelScoped ?? [] {
                guard let window = try item.value.window() else { continue }
                let duplicate = result.contains {
                    $0.name.caseInsensitiveCompare(item.displayName) == .orderedSame && $0.window == window
                }
                // A shared model label alone does not establish that two windows are the same.
                if !duplicate { result.append(NamedUsageWindow(name: item.displayName, window: window)) }
            }
            return result
        }
    }
    struct LimitRow: Decodable {
        var kind: String
        var percent: Double?
        var resetsAt: String?
        var scope: Scope?
        enum CodingKeys: String, CodingKey {
            case kind, percent, scope
            case resetsAt = "resets_at"
        }
        struct Scope: Decodable {
            var model: Model?
            struct Model: Decodable {
                var displayName: String?
                enum CodingKeys: String, CodingKey { case displayName = "display_name" }
            }
        }
    }
    struct NamedWindow: Decodable {
        var displayName: String
        var value: Window
        enum CodingKeys: String, CodingKey { case displayName = "display_name" }
        init(from decoder: Decoder) throws {
            displayName = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .displayName)
            value = try Window(from: decoder)
        }
    }
    struct Window: Decodable {
        var utilization: Double?
        var resetsAt: String?
        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
        func window() throws -> UsageWindow? {
            guard let utilization else { return nil }
            guard utilization.isFinite, utilization >= 0 else {
                throw SwitchboardError.message("Claude Code returned invalid usage values. Refresh again.")
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var reset = resetsAt.flatMap(formatter.date(from:))
            if reset == nil {
                formatter.formatOptions = [.withInternetDateTime]
                reset = resetsAt.flatMap(formatter.date(from:))
            }
            return UsageWindow(utilization: utilization, resetsAt: reset)
        }
    }
}

private final class UsageProcess: @unchecked Sendable {
    private let executable: URL
    private let installation: ClaudeInstallation
    private let timeout: TimeInterval
    private let cancellationLock = NSLock()
    private var cancelled = false
    private let initializeID = "switchboard-initialize"
    private let usageID = "switchboard-usage"
    private let maximumOutputBytes = 2 * 1024 * 1024
    private let maximumLineBytes = 1024 * 1024

    init(executable: URL, installation: ClaudeInstallation, timeout: TimeInterval) {
        self.executable = executable
        self.installation = installation
        self.timeout = timeout
    }

    func cancel() {
        cancellationLock.lock()
        cancelled = true
        cancellationLock.unlock()
    }

    private func checkCancellation() throws {
        cancellationLock.lock()
        let isCancelled = cancelled
        cancellationLock.unlock()
        if isCancelled { throw CancellationError() }
    }

    func run() throws -> UsageSnapshot {
        try checkCancellation()
        let manager = FileManager.default
        let scratch = manager.temporaryDirectory.appendingPathComponent("switchboard-usage-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: scratch) }

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = scratch
        process.environment = environment(scratch: scratch)
        process.arguments = [
            "--print", "--input-format", "stream-json", "--output-format", "stream-json",
            "--verbose", "--no-session-persistence", "--setting-sources", "",
            "--settings", "{\"disableAllHooks\":true}", "--strict-mcp-config",
            "--mcp-config", "{\"mcpServers\":{}}"
        ]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        defer {
            // A usage child is short-lived. Always reap it, including timeout and cancellation paths.
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let deadline = ProcessInfo.processInfo.systemUptime + 0.5
                while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            if process.processIdentifier > 0 { process.waitUntilExit() }
            for handle in [input.fileHandleForReading, output.fileHandleForReading,
                           output.fileHandleForWriting, errors.fileHandleForReading, errors.fileHandleForWriting] {
                try? handle.close()
            }
        }
        do { try process.run() }
        catch { throw SwitchboardError.message("Cannot start Claude Code. Select a working Claude Code installation.") }
        try output.fileHandleForWriting.close()
        try errors.fileHandleForWriting.close()
        try input.fileHandleForReading.close()
        let outputFD = output.fileHandleForReading.fileDescriptor
        let errorFD = errors.fileHandleForReading.fileDescriptor
        for fd in [outputFD, errorFD] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw SwitchboardError.message("Cannot read Claude Code's usage response.")
            }
        }
        // A child that exits between initialization and the request must not signal the app.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) >= 0 else {
            throw SwitchboardError.message("Cannot open Claude Code's control channel.")
        }
        try send(["subtype": "initialize", "hooks": [:]], id: initializeID, to: input.fileHandleForWriting)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var bytesSeen = 0
        var lineBuffer = Data()
        var requestedUsage = false
        var openOutput = true, openErrors = true
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)

        while true {
            try checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw SwitchboardError.message("Claude Code did not return usage in time. Refresh again.")
            }
            var descriptors = [
                pollfd(fd: openOutput ? outputFD : -1, events: Int16(POLLIN | POLLHUP), revents: 0),
                pollfd(fd: openErrors ? errorFD : -1, events: Int16(POLLIN | POLLHUP), revents: 0)
            ]
            let polled = poll(&descriptors, nfds_t(descriptors.count), 100)
            if polled < 0, errno != EINTR {
                throw SwitchboardError.message("The Claude Code usage connection failed. Refresh again.")
            }
            for index in descriptors.indices where descriptors[index].revents != 0 {
                let count = Darwin.read(descriptors[index].fd, &buffer, buffer.count)
                if count < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                    throw SwitchboardError.message("The Claude Code usage connection closed unexpectedly.")
                }
                if count == 0 {
                    if index == 0 { openOutput = false } else { openErrors = false }
                    continue
                }
                bytesSeen += count
                guard bytesSeen <= maximumOutputBytes else {
                    throw SwitchboardError.message("Claude Code returned too much output. Update Claude Code, then refresh again.")
                }
                // Stderr is deliberately discarded. It can contain account-specific diagnostics.
                if index == 1 { continue }
                lineBuffer.append(contentsOf: buffer.prefix(count))
                while let newline = lineBuffer.firstIndex(of: 10) {
                    let line = Data(lineBuffer[..<newline])
                    lineBuffer.removeSubrange(...newline)
                    guard line.count <= maximumLineBytes else { throw oversizedResponse() }
                    guard let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          frame["type"] as? String == "control_response",
                          let response = frame["response"] as? [String: Any],
                          let id = response["request_id"] as? String else { continue }
                    if id == initializeID, !requestedUsage {
                        guard response["subtype"] as? String == "success" else {
                            throw SwitchboardError.message("Claude Code could not initialize usage lookup. Update Claude Code, then refresh again.")
                        }
                        requestedUsage = true
                        try send(["subtype": "get_usage", "skip_behaviors": true], id: usageID,
                                 to: input.fileHandleForWriting)
                    } else if id == usageID, requestedUsage {
                        return try CLIUsageClient.parseUsageResponse(line)
                    }
                }
                guard lineBuffer.count <= maximumLineBytes else { throw oversizedResponse() }
            }
            if !openOutput || (!process.isRunning && polled == 0) {
                throw SwitchboardError.message("Claude Code closed before returning usage. Check the saved login, then refresh again.")
            }
        }
    }

    private func environment(scratch: URL) -> [String: String] {
        // Start with operating-system essentials. Inherited provider flags, OAuth tokens,
        // endpoints, plugins, and account selectors must not override the selected profile.
        let inherited = ProcessInfo.processInfo.environment
        let allowed = ["PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING",
                       "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS"]
        var env = inherited.filter { allowed.contains($0.key) }
        env["PATH"] = env["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOME"] = installation.configurationEnvironment["CLAUDE_CONFIG_DIR"] == nil
            ? installation.configFile.deletingLastPathComponent().path
            : FileManager.default.homeDirectoryForCurrentUser.path
        env["USER"] = installation.keychainAccount
        env["LOGNAME"] = installation.keychainAccount
        env["ANTHROPIC_CONFIG_DIR"] = scratch.appendingPathComponent("empty-anthropic-profiles").path
        // The broad NONESSENTIAL_TRAFFIC flag also disables the usage endpoint.
        // Disable only telemetry/error reporting so this read can reach Anthropic.
        env["DISABLE_TELEMETRY"] = "1"
        env["DISABLE_ERROR_REPORTING"] = "1"
        env["DISABLE_AUTOUPDATER"] = "1"
        env["CLAUDE_CODE_ENABLE_TELEMETRY"] = "0"
        env.merge(installation.configurationEnvironment) { _, selected in selected }
        return env
    }

    private func send(_ request: [String: Any], id: String, to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: ["type": "control_request", "request_id": id, "request": request])
        data.append(10)
        do { try handle.write(contentsOf: data) }
        catch { throw SwitchboardError.message("Claude Code closed its control channel. Refresh again.") }
    }

    private func oversizedResponse() -> SwitchboardError {
        .message("Claude Code returned an oversized usage response. Update Claude Code, then refresh again.")
    }
}
