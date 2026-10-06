import Foundation
import UserNotifications

/// The slice of UNUserNotificationCenter this app uses, so tests can drive it
/// without the system asking a real person for permission.
protocol NotificationScheduling: AnyObject {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func pendingRequests() async -> [UNNotificationRequest]
    func removePending(identifiers: [String])
}

/// `requestAuthorization(options:)` and `add(_:)` already exist on
/// UNUserNotificationCenter with these exact async signatures, so they satisfy
/// the protocol without a shim. Writing one here would just call itself.
extension UNUserNotificationCenter: NotificationScheduling {
    func pendingRequests() async -> [UNNotificationRequest] {
        await pendingNotificationRequests()
    }

    func removePending(identifiers: [String]) {
        removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

/// Schedules reminders for the deadlines that apply to *this* student's grade.
///
/// Two things it will not do: schedule before asking, and schedule a date that
/// has already passed.
struct DeadlineScheduler {
    enum Outcome: Equatable {
        case scheduled(count: Int)
        case denied
        case nothingToSchedule
    }

    /// Reminders land this many days before the deadline, plus one on the day.
    static let leadDays = [30, 7, 0]

    private let center: NotificationScheduling
    private let calendar: Calendar

    init(center: NotificationScheduling, calendar: Calendar = .current) {
        self.center = center
        self.calendar = calendar
    }

    static func identifier(grade: Int, daysBefore: Int) -> String {
        "greencord.deadline.grade\(grade).minus\(daysBefore)"
    }

    /// Ask, then schedule. Returns `.denied` without scheduling anything if the
    /// student says no.
    func scheduleDeadlines(
        grade: Int,
        requirements: Requirements,
        now: Date = Date()
    ) async -> Outcome {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return .denied }

        guard let requirement = requirements.requirement(forGrade: grade),
              let deadline = Self.nextOccurrence(
                  of: requirement.submissionDeadline.value, after: now, calendar: calendar
              )
        else { return .nothingToSchedule }

        // Clear this grade's reminders first so re-running never stacks duplicates.
        center.removePending(identifiers: Self.leadDays.map {
            Self.identifier(grade: grade, daysBefore: $0)
        })

        var scheduled = 0
        for daysBefore in Self.leadDays {
            guard let fireDate = calendar.date(
                byAdding: .day, value: -daysBefore, to: deadline
            ) else { continue }
            // Never schedule into the past. A student installing the app in
            // April has already passed the 30-day mark and gets only what is
            // still ahead of them.
            guard fireDate > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Green Cord deadline"
            content.body = Self.message(
                daysBefore: daysBefore,
                deadline: requirement.submissionDeadline.value,
                label: requirement.label,
                hours: requirement.thresholdHours.value
            )
            content.sound = .default

            var components = calendar.dateComponents([.year, .month, .day], from: fireDate)
            components.hour = 9
            components.minute = 0

            let request = UNNotificationRequest(
                identifier: Self.identifier(grade: grade, daysBefore: daysBefore),
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            if (try? await center.add(request)) != nil { scheduled += 1 }
        }

        return scheduled == 0 ? .nothingToSchedule : .scheduled(count: scheduled)
    }

    func pendingCount() async -> Int {
        await center.pendingRequests().count
    }

    static func message(daysBefore: Int, deadline: String, label: String, hours: Double) -> String {
        let requirement = "\(Formatting.hours(hours)) verified hours for \(label) recognition"
        switch daysBefore {
        case 0:
            return "Today is the \(deadline) deadline. \(requirement) must be submitted and verified."
        case 1:
            return "One day until the \(deadline) deadline. \(requirement)."
        default:
            return "\(daysBefore) days until the \(deadline) deadline. \(requirement)."
        }
    }

    /// Turn "April 15" into the next April 15 strictly after `now`.
    ///
    /// The handbook states deadlines as a month and a day with no year, because
    /// they recur every school year.
    static func nextOccurrence(
        of deadline: String,
        after now: Date,
        calendar: Calendar = .current
    ) -> Date? {
        let parts = deadline.split(separator: " ")
        guard parts.count == 2,
              let month = monthNumber(String(parts[0])),
              let day = Int(parts[1])
        else { return nil }

        let thisYear = calendar.component(.year, from: now)
        for year in [thisYear, thisYear + 1] {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            components.hour = 23
            components.minute = 59
            if let candidate = calendar.date(from: components), candidate > now {
                return candidate
            }
        }
        return nil
    }

    private static func monthNumber(_ name: String) -> Int? {
        let months = ["january", "february", "march", "april", "may", "june",
                      "july", "august", "september", "october", "november", "december"]
        guard let index = months.firstIndex(of: name.lowercased()) else { return nil }
        return index + 1
    }
}
