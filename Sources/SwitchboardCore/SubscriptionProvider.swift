import Foundation

public enum SubscriptionProvider: String, CaseIterable, Identifiable, Sendable {
    case claude
    case chatGPT

    public var id: String { rawValue }
    public var displayName: String { self == .claude ? "Claude" : "ChatGPT" }
    public var cliName: String { self == .claude ? "Claude Code" : "Codex" }
    public var restartNotice: String {
        self == .chatGPT ? "Close open Codex sessions before switching accounts." :
            "Restart open Claude Code sessions after switching."
    }
}
