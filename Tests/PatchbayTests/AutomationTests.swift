import Foundation
import Testing
@testable import Patchbay

struct AutomationTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-10-16 is a Friday.
    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func automation(_ frequency: Automation.Frequency, hour: Int = 9, minute: Int = 0, weekday: Int = 2) -> Automation {
        Automation(frequency: frequency, hour: hour, minute: minute, weekday: weekday)
    }

    @Test func daily() {
        #expect(automation(.daily).nextRun(after: date(16, 8), calendar: calendar) == date(16, 9))
        #expect(automation(.daily).nextRun(after: date(16, 9), calendar: calendar) == date(17, 9))
    }

    @Test func hourlyUsesOnlyTheMinute() {
        #expect(automation(.hourly, minute: 15).nextRun(after: date(16, 8, 20), calendar: calendar) == date(16, 9, 15))
    }

    @Test func weekdaysSkipTheWeekend() {
        #expect(automation(.weekdays).nextRun(after: date(16, 10), calendar: calendar) == date(19, 9))
    }

    @Test func weekly() {
        #expect(automation(.weekly, weekday: 4).nextRun(after: date(16, 10), calendar: calendar) == date(21, 9))
    }
}
