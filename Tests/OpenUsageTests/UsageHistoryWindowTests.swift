import XCTest
@testable import OpenUsage

final class UsageHistoryWindowTests: XCTestCase {
    func testLastThirtyDaysContainsTodayAndPreviousTwentyNineLocalDates() throws {
        let cases = [
            (zone: "Asia/Singapore", today: (2026, 7, 22), first: "2026-06-23"),
            (zone: "America/Los_Angeles", today: (2024, 3, 10), first: "2024-02-10"),
            (zone: "Europe/London", today: (2026, 1, 1), first: "2025-12-03")
        ]

        for fixture in cases {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: fixture.zone))
            let now = try XCTUnwrap(calendar.date(from: DateComponents(
                year: fixture.today.0,
                month: fixture.today.1,
                day: fixture.today.2,
                hour: 12
            )))

            let days = UsageHistoryWindow.dayKeys(through: now, calendar: calendar)

            XCTAssertEqual(days.count, 30, fixture.zone)
            XCTAssertEqual(days.min(), fixture.first, fixture.zone)
            XCTAssertEqual(
                days.max(),
                String(format: "%04d-%02d-%02d", fixture.today.0, fixture.today.1, fixture.today.2),
                fixture.zone
            )
        }
    }
}
