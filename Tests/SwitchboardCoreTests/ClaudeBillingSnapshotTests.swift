import Foundation
import XCTest
@testable import SwitchboardCore

final class ClaudeBillingSnapshotTests: XCTestCase {
    private let checkedAt = Date(timeIntervalSince1970: 1_789_000_000)

    func testParsesExactBillingTimesAndKeepsDateOnlyValues() throws {
        let value = try parse([
            "status": "active", "next_charge_at": "2026-09-27T02:24:27.125Z",
            "next_charge_date": "2026-09-27", "plan_ending_at": "2027-01-27T03:24:27+01:00",
            "plan_ending_before": "2027-01-28", "payment_paused_until": 1_800_000_000,
        ])
        XCTAssertEqual(value.checkedAt, checkedAt)
        XCTAssertEqual(value.status, "active")
        XCTAssertEqual(value.nextChargeAt, timestamp("2026-09-27T02:24:27.125Z"))
        XCTAssertEqual(value.planEndingAt, timestamp("2027-01-27T02:24:27Z"))
        XCTAssertEqual(value.nextChargeDate, "2026-09-27")
        XCTAssertEqual(value.planEndingDate, "2027-01-28")
        XCTAssertEqual(value.paymentPausedUntil, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testGiftCoverageIsIndependentOfEarlierBillingEvent() throws {
        let value = try parse([
            "status": "active", "next_charge_at": "2026-09-27T02:24:27Z",
            "next_charge_date": "2026-09-27", "plan_ending_at": "2027-01-27T02:24:27Z",
            "gift_details": ["tier": "max_20x", "duration_months": 6, "paid_through": "2027-01-27"],
        ])
        XCTAssertEqual(value.giftPaidThrough, "2027-01-27")
        XCTAssertEqual(value.nextChargeDate, "2026-09-27")
        XCTAssertEqual(value.planEndingAt, timestamp("2027-01-27T02:24:27Z"))
        XCTAssertNil(value.planEndingDate)
    }

    func testMissingAndNullFieldsDoNotInventRenewal() throws {
        XCTAssertEqual(try parse(["status": "canceled"]), ClaudeBillingSnapshot(checkedAt: checkedAt, status: "canceled"))
        XCTAssertEqual(try parse(["status": NSNull(), "next_charge_at": NSNull(), "next_charge_date": NSNull(),
                                 "plan_ending_at": NSNull(), "plan_ending_before": NSNull(),
                                 "gift_details": NSNull(), "payment_paused_until": NSNull()]),
                       ClaudeBillingSnapshot(checkedAt: checkedAt))
        XCTAssertEqual(try parse(["status": "future_provider_state"]).status, "future_provider_state")
        XCTAssertEqual(try parse(["next_charge_date": "2028-02-29"]).nextChargeDate, "2028-02-29")
    }

    func testRejectsNoncanonicalAndImpossibleCalendarDates() throws {
        for field in ["next_charge_date", "plan_ending_before"] {
            for date in ["2026-02-29", "2028-02-30", "2026-13-01", "2026-00-01", "2026-01-00",
                         "2026-04-31", "0000-01-01", "2026-9-27", " 2026-09-27", "2026-09-27\n",
                         "2026-09-27T00:00:00Z"] {
                XCTAssertThrowsError(try parse([field: date]), "\(field): \(date)")
            }
        }
        XCTAssertThrowsError(try parse(["gift_details": ["paid_through": "2026-02-29"]]))
        XCTAssertThrowsError(try parse(["next_charge_date": 1_800_000_000]))
    }

    func testRejectsTimestampsWithoutZonesAndInvalidPauseTypes() throws {
        for value in ["2026-09-27", "2026-09-27T02:24:27", "2026-02-30T02:24:27Z",
                      "2026-09-27T24:00:00Z", "2026-09-27T02:60:00Z", "2026-09-27T02:24:27Z\n"] {
            XCTAssertThrowsError(try parse(["next_charge_at": value]), value)
            XCTAssertThrowsError(try parse(["plan_ending_at": value]), value)
        }
        XCTAssertThrowsError(try parse(["next_charge_at": 1_800_000_000]))
        for value: Any in [true, "1800000000", "2027-01-27T02:24:27Z", -1, 1_800_000_000_000] {
            XCTAssertThrowsError(try parse(["payment_paused_until": value]))
        }
    }

    func testRejectsUnknownErrorMalformedAndOversizedResponsesWithoutLeakingBody() throws {
        for body in ["[]", "null", "{}", #"{"unrelated":"synthetic-private-value"}"#,
                     #"{"status":"active","error":{"message":"synthetic-private-value"}}"#,
                     #"{"type":"error","status":"active"}"#,
                     #"{"status":{"secret":"synthetic-private-value"}}"#,
                     #"{"status":"active","gift_details":"synthetic-private-value"}"#,
                     #"{"status":"active","gift_details":{"paid_through":false}}"#,
                     #"{"status":""}"#, #"{"status":" active"}"#, "synthetic-private-value"] {
            XCTAssertThrowsError(try ClaudeBillingSnapshot.parse(Data(body.utf8), checkedAt: checkedAt)) { error in
                XCTAssertFalse(error.localizedDescription.contains("synthetic-private-value"))
            }
        }
        XCTAssertThrowsError(try ClaudeBillingSnapshot.parse(Data(repeating: 32, count: 1_048_577)))
    }

    func testRoundTripRetainsOnlyDisplayMetadata() throws {
        let value = try parse([
            "status": "active", "next_charge_date": "2026-09-27", "gift_details": ["paid_through": "2027-01-27"],
            "payment_method": ["last4": "4242", "country": "DE"],
            "subscription_details_url": "https://example.test/synthetic-private-value",
            "unknown_new_field": ["access_token": "synthetic-private-value"],
        ])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(ClaudeBillingSnapshot.self, from: data), value)
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(encoded.contains("synthetic-private-value"))
        XCTAssertFalse(encoded.contains("4242"))
        XCTAssertFalse(encoded.contains("payment_method"))
    }

    func testBridgeAcceptsMatchingIdentityAndPersistsOnlyBillingMetadata() throws {
        let details: [String: Any] = ["status": "active", "gift_details": ["paid_through": "2027-01-27"],
            "payment_method": ["last4": "4242"], "unused": ["token": "synthetic-private-value"]]
        let result = try parseBridge(["accountUUID": "account-a", "organizationUUID": "org-a", "details": details])
        XCTAssertEqual(result, ClaudeBillingSnapshot(checkedAt: checkedAt, status: "active", giftPaidThrough: "2027-01-27"))
        let stored = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        for value in ["account-a", "org-a", "4242", "synthetic-private-value"] {
            XCTAssertFalse(stored.contains(value))
        }
    }

    func testBridgeRejectsEitherIdentityMismatchBeforeReadingMalformedDetails() throws {
        for (account, organization) in [("account-b", "org-a"), ("account-a", "org-b"), ("account-b", "org-b")] {
            let envelope: [String: Any] = ["accountUUID": account, "organizationUUID": organization,
                                           "details": ["status": ["secret": "synthetic-private-value"]]]
            XCTAssertThrowsError(try parseBridge(envelope)) { error in
                XCTAssertTrue(error.localizedDescription.contains("different Claude account or organization"))
                XCTAssertFalse(error.localizedDescription.contains("synthetic-private-value"))
                XCTAssertFalse(error.localizedDescription.contains(account))
                XCTAssertFalse(error.localizedDescription.contains(organization))
            }
        }
    }

    func testBridgeRejectsMissingWrongAndExpandedEnvelopeShapes() throws {
        let valid: [String: Any] = ["accountUUID": "account-a", "organizationUUID": "org-a", "details": ["status": "active"]]
        for field in ["accountUUID", "organizationUUID", "details"] {
            var missing = valid
            missing.removeValue(forKey: field)
            XCTAssertThrowsError(try parseBridge(missing))
            var null = valid
            null[field] = NSNull()
            XCTAssertThrowsError(try parseBridge(null))
        }
        for details: Any in ["synthetic-private-value", [], ["unrelated": "synthetic-private-value"], ["type": "error", "status": "active"]] {
            var invalid = valid
            invalid["details"] = details
            XCTAssertThrowsError(try parseBridge(invalid))
        }
        var expanded = valid
        expanded["bootstrap"] = ["intercom_user_jwt": "synthetic-private-value"]
        XCTAssertThrowsError(try parseBridge(expanded))
        var wrongType = valid
        wrongType["accountUUID"] = 42
        XCTAssertThrowsError(try parseBridge(wrongType))
        XCTAssertThrowsError(try ClaudeBillingSnapshot.parseBridge(Data("[]".utf8),
            expectedAccountUUID: "account-a", expectedOrganizationUUID: "org-a"))
        XCTAssertThrowsError(try ClaudeBillingSnapshot.parseBridge(Data(repeating: 32, count: 1_048_577),
            expectedAccountUUID: "account-a", expectedOrganizationUUID: "org-a"))
    }

    func testBridgeCannotAcceptAnUnspecifiedExpectedIdentity() throws {
        for (account, organization) in [("", "org-a"), ("account-a", ""), (" ", "org-a")] {
            let body = try JSONSerialization.data(withJSONObject: ["accountUUID": account,
                "organizationUUID": organization, "details": ["status": "active"]])
            XCTAssertThrowsError(try ClaudeBillingSnapshot.parseBridge(body,
                expectedAccountUUID: account, expectedOrganizationUUID: organization))
        }
    }

    private func parseBridge(_ object: [String: Any]) throws -> ClaudeBillingSnapshot {
        try ClaudeBillingSnapshot.parseBridge(JSONSerialization.data(withJSONObject: object),
            expectedAccountUUID: "account-a", expectedOrganizationUUID: "org-a", checkedAt: checkedAt)
    }

    private func parse(_ object: [String: Any]) throws -> ClaudeBillingSnapshot {
        try ClaudeBillingSnapshot.parse(JSONSerialization.data(withJSONObject: object), checkedAt: checkedAt)
    }

    private func timestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
