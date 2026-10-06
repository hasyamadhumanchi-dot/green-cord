import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import GreenCordHandbook

/// Gates C10, C16, C17 and C19: offline queueing that never duplicates, the
/// deadline reminders, and the CSV export.
@Suite("Offline queue, reminders and export")
struct OfflineAndExportTests {

    // MARK: - A scripted backend

    /// Records every call and can be switched offline mid-test.
    actor FakeAPI: GreenCordAPI {
        private(set) var created: [EntryDraft] = []
        private(set) var submitted: [String] = []
        private(set) var stored: [HourEntry] = []
        var offline = false
        private var counter = 0

        init(offline: Bool = false) { self.offline = offline }

        func goOnline() { offline = false }
        func goOffline() { offline = true }
        func serverEntries() -> [HourEntry] { stored }
        func createdCount() -> Int { created.count }

        private func guardOnline() throws {
            if offline { throw APIError.offline }
        }

        func createEntry(token: String, draft: EntryDraft, studentId: String?) async throws -> HourEntry {
            try guardOnline()
            counter += 1
            created.append(draft)
            let entry = HourEntry(
                id: "server-\(counter)",
                studentId: studentId ?? "student-1",
                serviceDate: draft.serviceDate,
                hours: draft.hours,
                category: draft.category,
                organization: draft.organization,
                description: draft.description,
                verifierName: draft.verifierName,
                verifierContact: draft.verifierContact,
                evidenceURL: draft.evidenceURL,
                counselorEntered: studentId != nil,
                status: .draft,
                updatedAt: Date().timeIntervalSince1970,
                submittedAt: nil,
                decidedAt: nil
            )
            stored.append(entry)
            return entry
        }

        func submitEntry(token: String, id: String) async throws -> HourEntry {
            try guardOnline()
            submitted.append(id)
            guard let index = stored.firstIndex(where: { $0.id == id }) else {
                throw APIError(status: 404, code: "not_found", message: "no such entry")
            }
            stored[index].status = .submitted
            stored[index].submittedAt = Date().timeIntervalSince1970
            return stored[index]
        }

        func updateEntry(token: String, id: String, changes: EntryDraft) async throws -> HourEntry {
            try guardOnline()
            guard let index = stored.firstIndex(where: { $0.id == id }) else {
                throw APIError(status: 404, code: "not_found", message: "no such entry")
            }
            stored[index].hours = changes.hours
            stored[index].organization = changes.organization
            stored[index].description = changes.description
            stored[index].updatedAt = Date().timeIntervalSince1970
            return stored[index]
        }

        func deleteEntry(token: String, id: String) async throws {
            try guardOnline()
            stored.removeAll { $0.id == id }
        }

        func entries(token: String) async throws -> [HourEntry] {
            try guardOnline()
            return stored
        }

        func approveEverything() {
            for index in stored.indices { stored[index].status = .approved }
        }

        // Unused by these tests.
        func lookupCode(code: String) async throws -> CodeHolder { throw APIError.offline }
        func redeem(
            code: String, username: String, password: String
        ) async throws -> Session { throw APIError.offline }
        func signIn(username: String, password: String) async throws -> Session { throw APIError.offline }
        func signOut(token: String) async throws {}
        func account(token: String) async throws -> Account { throw APIError.offline }
        func deleteAccount(token: String) async throws {}
        func entries(token: String, studentId: String?, status: String?) async throws -> [HourEntry] {
            try guardOnline()
            return stored
        }
        func decideEntry(token: String, id: String, action: ReviewAction, note: String) async throws -> HourEntry {
            throw APIError.offline
        }
        func history(token: String, entryId: String) async throws -> [AuditEvent] { [] }
        func progress(token: String) async throws -> ServerProgress { throw APIError.offline }
        func roster(token: String, grade: Int?, letterFrom: String?, letterTo: String?) async throws -> [RosterRow] { [] }
        func rosterCSV(token: String, grade: Int?, letterFrom: String?, letterTo: String?) async throws -> String { "" }
        func exportCSV(token: String) async throws -> String { "" }
        func inviteCodes(token: String) async throws -> [InviteCode] { [] }
        func createInviteCodes(
            token: String, students: [NewStudent]
        ) async throws -> [InviteCode] { [] }
        func revokeInviteCode(token: String, code: String) async throws {}
        func staff(token: String) async throws -> StaffList {
            StaffList(staff: [], pending: [], admins: 1, canManage: true)
        }
        func inviteStaff(
            token: String, firstName: String, lastName: String, role: Account.Role
        ) async throws -> PendingStaffInvite { throw APIError.offline }
        func setStaffRole(
            token: String, id: String, role: Account.Role
        ) async throws -> StaffMember { throw APIError.offline }
        func removeStaff(token: String, id: String) async throws {}
        func issuePasswordReset(
            token: String, accountId: String
        ) async throws -> PasswordReset { throw APIError.offline }
        func resetPassword(code: String, password: String) async throws {}
        func checklist(token: String) async throws -> [ChecklistItem] { [] }
        func setChecklist(token: String, itemId: String, checked: Bool) async throws {}
    }

    static func draft(_ hours: Double, organization: String) -> EntryDraft {
        EntryDraft(
            serviceDate: "2026-09-01",
            hours: hours,
            category: "community",
            organization: organization,
            description: "Sorted donations",
            verifierName: "Supervisor",
            verifierContact: "supervisor@example.org",
            evidenceURL: nil
        )
    }

    // MARK: - Offline queue

    @MainActor
    @Test("C19 entries made offline reach the server exactly once on reconnect")
    func queuedEntriesSyncExactlyOnce() async throws {
        let container = try LocalStore.container(inMemory: true)
        let context = ModelContext(container)
        let api = FakeAPI(offline: true)
        let sync = SyncEngine(api: api, context: context)

        // Three entries logged with no connection.
        for (hours, organization) in [(3.0, "Food Bank"), (5.0, "Library"), (2.0, "Shelter")] {
            await sync.create(
                draft: Self.draft(hours, organization: organization),
                studentId: "student-1",
                token: "token"
            )
        }

        #expect(sync.queuedCount() == 3)
        #expect(await api.createdCount() == 0, "nothing should have reached the server yet")
        #expect(sync.cachedEntries(for: "student-1").count == 3, "still readable offline")

        // Back online.
        await api.goOnline()
        let first = await sync.sync(token: "token", studentId: "student-1")
        #expect(first == .synced(pushed: 3, pulled: 3))
        #expect(await api.createdCount() == 3)
        #expect(sync.queuedCount() == 0)

        // Syncing again must not send anything a second time.
        let second = await sync.sync(token: "token", studentId: "student-1")
        #expect(second == .synced(pushed: 0, pulled: 3))
        #expect(await api.createdCount() == 3, "a second sync must not duplicate")

        let serverSide = await api.serverEntries()
        #expect(serverSide.count == 3)
        #expect(Set(serverSide.map(\.organization)) == ["Food Bank", "Library", "Shelter"])
        #expect(sync.cachedEntries(for: "student-1").count == 3)
    }

    @MainActor
    @Test("C19 an entry submitted offline is created and then submitted on reconnect")
    func offlineSubmitIsHonoured() async throws {
        let container = try LocalStore.container(inMemory: true)
        let context = ModelContext(container)
        let api = FakeAPI(offline: true)
        let sync = SyncEngine(api: api, context: context)

        let entry = await sync.create(
            draft: Self.draft(4, organization: "Food Bank"),
            studentId: "student-1", token: "token"
        )
        _ = await sync.submit(entry: entry, token: "token")
        #expect(entry.status == .submitted)

        await api.goOnline()
        _ = await sync.sync(token: "token", studentId: "student-1")

        let serverSide = await api.serverEntries()
        #expect(serverSide.count == 1)
        #expect(serverSide.first?.status == .submitted)
        #expect(sync.queuedCount() == 0)
    }

    @MainActor
    @Test("C10 an approved entry cannot be edited or deleted from the app")
    func approvedEntriesAreLocked() async throws {
        let container = try LocalStore.container(inMemory: true)
        let context = ModelContext(container)
        let api = FakeAPI()
        let sync = SyncEngine(api: api, context: context)

        let entry = await sync.create(
            draft: Self.draft(6, organization: "Food Bank"),
            studentId: "student-1", token: "token"
        )
        _ = await sync.submit(entry: entry, token: "token")
        await api.approveEverything()
        _ = await sync.sync(token: "token", studentId: "student-1")

        let cached = try #require(sync.cachedEntries(for: "student-1").first)
        #expect(cached.status == .approved)

        let edited = await sync.update(
            entry: cached, draft: Self.draft(999, organization: "Changed"), token: "token"
        )
        #expect(edited == false, "editing an approved entry must be refused")
        #expect(cached.hours == 6)
        #expect(cached.organization == "Food Bank")

        let deleted = await sync.delete(entry: cached, token: "token")
        #expect(deleted == false, "deleting an approved entry must be refused")
        #expect(sync.cachedEntries(for: "student-1").count == 1)
    }

    @MainActor
    @Test("C10 editing is allowed again after a rejection")
    func rejectedEntriesReopen() async throws {
        let container = try LocalStore.container(inMemory: true)
        let context = ModelContext(container)
        let sync = SyncEngine(api: FakeAPI(offline: true), context: context)

        let entry = await sync.create(
            draft: Self.draft(3, organization: "Library"),
            studentId: "student-1", token: nil
        )
        entry.status = .rejected
        let edited = await sync.update(
            entry: entry, draft: Self.draft(4, organization: "Library"), token: nil
        )
        #expect(edited)
        #expect(entry.hours == 4)

        entry.status = .revisionRequested
        #expect(await sync.update(
            entry: entry, draft: Self.draft(5, organization: "Library"), token: nil
        ))
        #expect(entry.hours == 5)

        entry.status = .submitted
        #expect(
            await sync.update(
                entry: entry, draft: Self.draft(6, organization: "Library"), token: nil
            ) == false,
            "an entry under review is not editable"
        )
        #expect(entry.hours == 5)
    }

    @MainActor
    @Test("C19 a pull never deletes work that has not been pushed yet")
    func pullKeepsUnsyncedWork() async throws {
        let container = try LocalStore.container(inMemory: true)
        let context = ModelContext(container)
        let sync = SyncEngine(api: FakeAPI(offline: true), context: context)

        await sync.create(
            draft: Self.draft(2, organization: "Not yet sent"),
            studentId: "student-1", token: nil
        )
        #expect(sync.queuedCount() == 1)

        // The server knows nothing about it. Merging must not wipe it out.
        sync.merge(remote: [], studentId: "student-1")
        #expect(sync.cachedEntries(for: "student-1").count == 1)
        #expect(sync.queuedCount() == 1)
    }

    // MARK: - Deadline reminders

    /// Stands in for UNUserNotificationCenter.
    final class StubNotificationCenter: NotificationScheduling, @unchecked Sendable {
        var granted = true
        private(set) var added: [UNNotificationRequest] = []
        private(set) var authorizationRequests = 0
        /// True if a request was ever added before authorization was asked for.
        private(set) var scheduledBeforeAsking = false

        func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
            authorizationRequests += 1
            return granted
        }

        func add(_ request: UNNotificationRequest) async throws {
            if authorizationRequests == 0 { scheduledBeforeAsking = true }
            added.append(request)
        }

        func pendingRequests() async -> [UNNotificationRequest] { added }

        func removePending(identifiers: [String]) {
            added.removeAll { identifiers.contains($0.identifier) }
        }

        var fireDates: [DateComponents] {
            added.compactMap {
                ($0.trigger as? UNCalendarNotificationTrigger)?.dateComponents
            }
        }
    }

    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func date(_ iso: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: iso)!
    }

    @Test("C16 authorization is asked for before anything is scheduled")
    func asksBeforeScheduling() async throws {
        let requirements = try RequirementsTests.loadRequirements()
        let center = StubNotificationCenter()
        let scheduler = DeadlineScheduler(center: center, calendar: Self.utcCalendar)

        let outcome = await scheduler.scheduleDeadlines(
            grade: 9, requirements: requirements, now: Self.date("2026-09-20")
        )

        #expect(center.authorizationRequests == 1)
        #expect(center.scheduledBeforeAsking == false)
        #expect(outcome == .scheduled(count: 3))
    }

    @Test("C16 refusing permission schedules nothing at all")
    func deniedSchedulesNothing() async throws {
        let requirements = try RequirementsTests.loadRequirements()
        let center = StubNotificationCenter()
        center.granted = false
        let scheduler = DeadlineScheduler(center: center, calendar: Self.utcCalendar)

        let outcome = await scheduler.scheduleDeadlines(
            grade: 9, requirements: requirements, now: Self.date("2026-09-20")
        )
        #expect(outcome == .denied)
        #expect(center.added.isEmpty)
    }

    @Test("C16 reminders land on the right dates and never in the past")
    func fireDatesAreCorrect() async throws {
        let requirements = try RequirementsTests.loadRequirements()
        let center = StubNotificationCenter()
        let scheduler = DeadlineScheduler(center: center, calendar: Self.utcCalendar)

        // September: all three reminders for the following 15 April are ahead.
        _ = await scheduler.scheduleDeadlines(
            grade: 9, requirements: requirements, now: Self.date("2026-09-20")
        )
        #expect(center.added.count == 3)

        let dates = center.fireDates.compactMap { components -> String? in
            guard let month = components.month, let day = components.day,
                  let year = components.year else { return nil }
            return String(format: "%04d-%02d-%02d", year, month, day)
        }.sorted()
        // 15 April 2027 minus 30 and 7 days, plus the day itself.
        #expect(dates == ["2027-03-16", "2027-04-08", "2027-04-15"])
    }

    @Test("C16 a deadline that has just passed schedules only what is still ahead")
    func pastDeadlinesScheduleNothing() async throws {
        let requirements = try RequirementsTests.loadRequirements()

        // 14 April: the 30-day and 7-day marks are gone; only the day itself remains.
        let center = StubNotificationCenter()
        let scheduler = DeadlineScheduler(center: center, calendar: Self.utcCalendar)
        _ = await scheduler.scheduleDeadlines(
            grade: 9, requirements: requirements, now: Self.date("2027-04-14")
        )
        #expect(center.added.count == 1)

        // Every scheduled date must be in the future. Nothing may fire in the past.
        for components in center.fireDates {
            let fireDate = try #require(Self.utcCalendar.date(from: components))
            #expect(fireDate > Self.date("2027-04-14"))
        }
    }

    @Test("C16 a freshman and a senior get different reminder dates")
    func gradesGetDifferentDates() async throws {
        let requirements = try RequirementsTests.loadRequirements()
        let now = Self.date("2026-09-20")

        let freshmanCenter = StubNotificationCenter()
        _ = await DeadlineScheduler(center: freshmanCenter, calendar: Self.utcCalendar)
            .scheduleDeadlines(grade: 9, requirements: requirements, now: now)

        let seniorCenter = StubNotificationCenter()
        _ = await DeadlineScheduler(center: seniorCenter, calendar: Self.utcCalendar)
            .scheduleDeadlines(grade: 12, requirements: requirements, now: now)

        func days(_ center: StubNotificationCenter) -> Set<String> {
            Set(center.fireDates.compactMap { components in
                guard let month = components.month, let day = components.day else { return nil }
                return String(format: "%02d-%02d", month, day)
            })
        }

        // The handbook puts the lower grades on 15 April and seniors on 1 April.
        #expect(days(freshmanCenter) == ["03-16", "04-08", "04-15"])
        #expect(days(seniorCenter) == ["03-02", "03-25", "04-01"])
        #expect(days(freshmanCenter) != days(seniorCenter))
    }

    @Test("C16 scheduling twice does not stack duplicate reminders")
    func reschedulingIsIdempotent() async throws {
        let requirements = try RequirementsTests.loadRequirements()
        let center = StubNotificationCenter()
        let scheduler = DeadlineScheduler(center: center, calendar: Self.utcCalendar)
        let now = Self.date("2026-09-20")

        _ = await scheduler.scheduleDeadlines(grade: 10, requirements: requirements, now: now)
        _ = await scheduler.scheduleDeadlines(grade: 10, requirements: requirements, now: now)

        #expect(center.added.count == 3)
        #expect(Set(center.added.map(\.identifier)).count == 3)
    }

    @Test("Deadline text parses into the next occurrence, not a past one")
    func nextOccurrence() {
        let calendar = Self.utcCalendar
        let september = Self.date("2026-09-20")
        let april15 = try? #require(
            DeadlineScheduler.nextOccurrence(of: "April 15", after: september, calendar: calendar)
        )
        #expect(calendar.component(.year, from: april15!) == 2027)
        #expect(calendar.component(.month, from: april15!) == 4)

        // Asked on 20 April, the next 15 April is the following year.
        let afterDeadline = Self.date("2027-04-20")
        let next = DeadlineScheduler.nextOccurrence(
            of: "April 15", after: afterDeadline, calendar: calendar
        )
        #expect(calendar.component(.year, from: next!) == 2028)

        #expect(DeadlineScheduler.nextOccurrence(
            of: "Not specified in the handbook", after: september, calendar: calendar
        ) == nil)
    }

    // MARK: - Export

    @Test("C17 the export holds approved rows only, with the right count and values")
    func studentExport() throws {
        let requirements = try RequirementsTests.loadRequirements()
        let account = Account(
            id: "student-1", role: .student, displayName: "Alpha Alderwood",
            lastName: "Alderwood", grade: 11, username: "alpha.alderwood",
            thresholdHours: 75, submissionDeadline: "April 15"
        )
        let entries = [
            RequirementsTests.entry(5, .approved, organization: "Food Bank"),
            RequirementsTests.entry(3.5, .approved, organization: "Animal Shelter"),
            RequirementsTests.entry(40, .submitted, organization: "Should Not Appear"),
            RequirementsTests.entry(99, .draft, organization: "Also Not"),
        ]

        let csv = CSVExport.studentExport(
            entries: entries, requirements: requirements, account: account
        )
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        #expect(lines[0] == CSVExport.studentHeader.joined(separator: ","))
        let dataRows = lines.dropFirst().prefix { !$0.isEmpty }
        #expect(dataRows.count == 2, "only the two approved entries")

        #expect(csv.contains("Animal Shelter"))
        #expect(csv.contains("Food Bank"))
        #expect(!csv.contains("Should Not Appear"))
        #expect(!csv.contains("Also Not"))
        #expect(csv.contains("Total verified hours,8.5"))
        #expect(csv.contains("Alpha Alderwood"))
        #expect(csv.contains("April 15"))
        #expect(csv.contains("75"))
    }

    @Test("CSV quoting survives commas, quotes and newlines")
    func csvQuoting() {
        #expect(CSVExport.escape("plain") == "plain")
        #expect(CSVExport.escape("has, comma") == "\"has, comma\"")
        #expect(CSVExport.escape("has \"quote\"") == "\"has \"\"quote\"\"\"")
        #expect(CSVExport.escape("two\nlines") == "\"two\nlines\"")

        let requirements = try? RequirementsTests.loadRequirements()
        let account = Account(
            id: "s", role: .student, displayName: "Bravo, Jr.", lastName: "Birchfield",
            grade: 9, username: "b", thresholdHours: 25, submissionDeadline: "April 15"
        )
        var entry = RequirementsTests.entry(2, .approved)
        entry.description = "Sorted \"winter\" coats, boxed them, and stacked the pallets"
        let csv = CSVExport.studentExport(
            entries: [entry], requirements: requirements!, account: account
        )
        #expect(csv.contains("\"Sorted \"\"winter\"\" coats, boxed them, and stacked the pallets\""))
        #expect(csv.contains("\"Bravo, Jr.\""))
    }

    @Test("The roster export has one row per student plus a header")
    func rosterExport() {
        let rows = [
            RosterRow(studentId: "1", displayName: "Alpha Alderwood", lastName: "Alderwood",
                      grade: 9, verifiedHours: 10, pendingHours: 4, thresholdHours: 25,
                      percentComplete: 40, lastActivityAt: nil),
            RosterRow(studentId: "2", displayName: "Bravo Birchfield", lastName: "Birchfield",
                      grade: 12, verifiedHours: 104.5, pendingHours: 6, thresholdHours: 100,
                      percentComplete: 104.5, lastActivityAt: nil),
        ]
        let csv = CSVExport.rosterExport(rows: rows)
        let lines = csv.split(separator: "\n").map(String.init)

        #expect(lines.count == 3)
        #expect(lines[0] == CSVExport.rosterHeader.joined(separator: ","))
        #expect(csv.contains("Alderwood"))
        #expect(csv.contains("104.5"))
    }
}
