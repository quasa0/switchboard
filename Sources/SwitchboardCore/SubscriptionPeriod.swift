import Foundation
import CoreFoundation

/// Provider-reported subscription timing, independent of quota resets and manual reminders.
public struct SubscriptionPeriod: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case codexIDToken
        case claudeBilling
    }

    public var startsAt: Date?
    public var endsAt: Date
    /// The provider's observation time. Reading cached metadata does not advance this date.
    public var checkedAt: Date?
    /// Nil means the provider has not established whether this period will renew.
    public var willRenew: Bool?
    public var source: Source

    public init(startsAt: Date? = nil, endsAt: Date, checkedAt: Date? = nil,
                willRenew: Bool? = nil, source: Source) {
        self.startsAt = startsAt; self.endsAt = endsAt; self.checkedAt = checkedAt
        self.willRenew = willRenew; self.source = source
    }
}

enum SubscriptionDateParser {
    /// Accept provider ISO 8601 timestamps and Unix seconds; never guess milliseconds or a time zone.
    static func parse(_ raw: Any?) -> Date? {
        if let number = raw as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let seconds = number.doubleValue
            guard seconds.isFinite, seconds > 0, seconds <= 253_402_300_799 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        guard let string = raw as? String else { return nil }
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]+)?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])$"#,
                          options: .regularExpression) != nil else { return nil }
        let parts = value.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] > 0 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let expected = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let day = calendar.date(from: expected),
              calendar.dateComponents([.year, .month, .day], from: day) == expected else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
