import Foundation
import XCTest
@testable import SwitchboardCore

final class SubscriptionPeriodTests: XCTestCase {
    func testInvalidCalendarTimestampsNeverRollIntoAnotherBillingDate() {
        for value in ["2026-02-30T12:00:00Z", "2026-02-29T12:00:00Z", "2026-09-31T12:00:00Z",
                      "2026-09-27T24:00:00Z", "0000-01-01T00:00:00Z"] {
            XCTAssertNil(SubscriptionDateParser.parse(value), value)
        }
        XCTAssertNotNil(SubscriptionDateParser.parse("2028-02-29T12:00:00Z"))
    }

    func testDateParserPreservesOffsetsFractionsAndUnixSeconds() throws {
        let reference = try XCTUnwrap(SubscriptionDateParser.parse("2026-10-24T10:30:45Z"))
        XCTAssertEqual(SubscriptionDateParser.parse("2026-10-24T12:30:45+02:00"), reference)
        XCTAssertEqual(SubscriptionDateParser.parse("2026-10-24T05:00:45-05:30"), reference)
        XCTAssertEqual(try XCTUnwrap(SubscriptionDateParser.parse("2026-10-24T10:30:45.125Z")).timeIntervalSince(reference), 0.125, accuracy: 0.0001)
        XCTAssertEqual(SubscriptionDateParser.parse(1_790_000_000.5), Date(timeIntervalSince1970: 1_790_000_000.5))
    }

    func testDateParserRejectsAmbiguousInvalidAndMillisecondValues() {
        for value in [NSNull(), true, false, 0, -1, Double.nan, Double.infinity, 1_790_000_000_000,
                           "1790000000", "2026-10-24", "2026-10-24T10:30:45", "2026-10-24 10:30:45Z",
                           "2026-99-99T10:30:45Z", ["value": 1_790_000_000]] as [Any] {
            XCTAssertNil(SubscriptionDateParser.parse(value))
        }
        XCTAssertNil(SubscriptionDateParser.parse(nil))
    }

    func testPeriodRoundTripPreservesUnknownRenewalAndSource() throws {
        for source in [SubscriptionPeriod.Source.codexIDToken, .claudeBilling] {
            for willRenew in [nil, false, true] as [Bool?] {
                let original = SubscriptionPeriod(startsAt: Date(timeIntervalSince1970: 1_790_000_000),
                    endsAt: Date(timeIntervalSince1970: 1_791_000_000),
                    checkedAt: Date(timeIntervalSince1970: 1_790_100_000), willRenew: willRenew, source: source)
                let decoded = try JSONDecoder().decode(SubscriptionPeriod.self, from: JSONEncoder().encode(original))
                XCTAssertEqual(decoded, original)
            }
        }
    }
}
