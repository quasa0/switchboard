import Foundation

/// Classifies the CLI's errors without displaying URLs, response bodies, or credentials.
struct CodexUsageFailure: Decodable {
    let code: Int?
    private let message: String?

    var httpStatus: Int? {
        guard let message else { return nil }
        // Match the backend client's status header only, never numbers in its URL/body.
        let pattern = #"^failed to fetch codex rate limits: (?:GET|POST) https://[^\s]+ failed: ([1-5][0-9]{2})(?:\s|;)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let range = Range(match.range(at: 1), in: message) else { return nil }
        return Int(message[range])
    }

    func displayError(stage: String) -> SwitchboardError {
        switch httpStatus {
        case 401:
            return .message("Codex's usage service rejected this login (HTTP 401). Sign in to this account again, then refresh.")
        case 403:
            return .message("Codex's usage service denied access (HTTP 403). Check this workspace's Codex access in the CLI, then refresh.")
        case 429:
            return .message("Codex's usage service is rate limiting requests (HTTP 429). Wait before refreshing again.")
        case .some(500...599):
            return .message("Codex's usage service is unavailable (HTTP \(httpStatus!)). Refresh later.")
        case .some(let status):
            return .message("Codex's usage service returned HTTP \(status). Check Codex in Terminal, then refresh.")
        case nil: break
        }
        if code == -32601 || code == -32602 {
            return .message("This Codex version rejected \(stage) (RPC \(code!)). Update Codex, then refresh.")
        }
        let detail = code.map { " (RPC \($0))" } ?? ""
        return .message("Codex failed during \(stage)\(detail). Check Codex in Terminal, then refresh. No usage data was returned.")
    }
}
