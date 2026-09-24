import Foundation

public struct SavedAccount: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var email: String
    public var accountUUID: String
    public var organizationUUID: String
    public var plan: String
    public var addedAt: Date
    public var lastUsedAt: Date?
    public var usage: UsageSnapshot?

    public init(id: UUID = UUID(), label: String, email: String, accountUUID: String,
                organizationUUID: String, plan: String, addedAt: Date = Date(),
                lastUsedAt: Date? = nil, usage: UsageSnapshot? = nil) {
        self.id = id; self.label = label; self.email = email
        self.accountUUID = accountUUID; self.organizationUUID = organizationUUID
        self.plan = plan; self.addedAt = addedAt; self.lastUsedAt = lastUsedAt; self.usage = usage
    }
    public var initials: String {
        let words = label.split(separator: " ")
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}

public struct UsageWindow: Codable, Equatable, Sendable {
    public var utilization: Double
    public var resetsAt: Date?
    public init(utilization: Double, resetsAt: Date?) {
        self.utilization = utilization; self.resetsAt = resetsAt
    }
    public var fraction: Double { min(1, max(0, utilization / 100)) }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    public var sevenDaySonnet: UsageWindow?
    public var sevenDayOpus: UsageWindow?
    public var fetchedAt: Date
    public var modelScoped: [NamedUsageWindow]
    public init(fiveHour: UsageWindow? = nil, sevenDay: UsageWindow? = nil,
                sevenDaySonnet: UsageWindow? = nil, sevenDayOpus: UsageWindow? = nil,
                fetchedAt: Date = Date(), modelScoped: [NamedUsageWindow] = []) {
        self.fiveHour = fiveHour; self.sevenDay = sevenDay
        self.sevenDaySonnet = sevenDaySonnet; self.sevenDayOpus = sevenDayOpus
        self.fetchedAt = fetchedAt
        self.modelScoped = modelScoped
    }
}

public struct NamedUsageWindow: Codable, Equatable, Sendable {
    public var name: String
    public var window: UsageWindow
    public init(name: String, window: UsageWindow) { self.name = name; self.window = window }
}

public struct CurrentLogin: Equatable, Sendable {
    public var email: String
    public var accountUUID: String
    public var organizationUUID: String
    public var plan: String
    public init(email: String, accountUUID: String, organizationUUID: String, plan: String) {
        self.email = email; self.accountUUID = accountUUID
        self.organizationUUID = organizationUUID; self.plan = plan
    }
}

public struct SwitchboardState: Sendable {
    public var accounts: [SavedAccount]
    public var current: CurrentLogin?
    public var activeID: UUID?
}

public enum SwitchboardError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}

public struct CredentialSnapshot: Codable, Equatable, Sendable {
    public var oauth: Data
    public var identity: Data
    public init(oauth: Data, identity: Data) { self.oauth = oauth; self.identity = identity }

    public func validated() throws -> (CurrentLogin, OAuthCredential) {
        let token = try JSONDecoder().decode(OAuthCredential.self, from: oauth)
        let account = try JSONDecoder().decode(ClaudeIdentity.self, from: identity)
        guard !token.accessToken.isEmpty, !account.accountUuid.isEmpty, !account.emailAddress.isEmpty,
              token.scopes.contains("user:inference") else {
            throw SwitchboardError.message("This is not a Claude subscription login. Run claude auth login --claudeai first.")
        }
        let plan: String
        if token.rateLimitTier == "default_claude_max_20x" { plan = "Max 20×" }
        else if token.rateLimitTier == "default_claude_max_5x" { plan = "Max 5×" }
        else { plan = token.subscriptionType?.capitalized ?? "Claude" }
        return (CurrentLogin(email: account.emailAddress, accountUUID: account.accountUuid,
                             organizationUUID: account.organizationUuid ?? "", plan: plan), token)
    }
}

public struct OAuthCredential: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Double?
    public var scopes: [String]
    public var subscriptionType: String?
    public var rateLimitTier: String?
    public var needsRefresh: Bool { (expiresAt ?? 0) / 1000 < Date().timeIntervalSince1970 + 60 }
}

private struct ClaudeIdentity: Decodable {
    var accountUuid: String
    var emailAddress: String
    var organizationUuid: String?
}
