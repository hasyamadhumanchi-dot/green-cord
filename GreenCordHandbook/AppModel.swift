import Foundation
import PDFKit
import SwiftData
import SwiftUI

/// The app's single source of truth: who is signed in, what content is loaded,
/// and what the current student's record looks like.
@MainActor
@Observable
final class AppModel {
    // Content
    private(set) var content: LoadedContent
    private(set) var searchIndex: SearchIndex
    private(set) var pdfDocument: PDFDocument?
    private(set) var contentUpdateMessage: String?

    // Session
    private(set) var session: Session?
    var isSignedIn: Bool { session != nil }
    var account: Account? { session?.account }
    var role: Account.Role? { session?.account.role }

    // Student state
    private(set) var entries: [HourEntry] = []
    private(set) var checklist: [ChecklistItem] = []
    private(set) var serverProgress: ServerProgress?

    // Counselor state
    private(set) var reviewQueue: [HourEntry] = []
    private(set) var roster: [RosterRow] = []
    private(set) var inviteCodes: [InviteCode] = []

    // Status surfaced in the UI
    private(set) var isOffline = false
    private(set) var queuedCount = 0
    var lastError: String?

    private let store: ContentStore
    private let api: GreenCordAPI
    private let updater: ContentUpdater
    private let modelContext: ModelContext
    private let sync: SyncEngine
    /// Absent in tests and previews, which have no keychain worth touching.
    private let sessionStore: SessionStore?

    init(
        store: ContentStore,
        api: GreenCordAPI,
        network: NetworkFetching,
        modelContext: ModelContext,
        manifestURL: URL = ContentSource.manifestURL,
        sessionStore: SessionStore? = nil
    ) {
        self.store = store
        self.api = api
        self.modelContext = modelContext
        self.sessionStore = sessionStore
        updater = ContentUpdater(store: store, network: network, manifestURL: manifestURL)
        sync = SyncEngine(api: api, context: modelContext)

        let loaded = store.load()
        content = loaded
        searchIndex = SearchIndex(handbook: loaded.handbook)
        pdfDocument = PDFDocument(url: loaded.pdfURL)

        // Restored here rather than in a task, so the app does not show the
        // welcome screen for a frame to someone who is already signed in.
        session = sessionStore?.load()
    }

    var handbook: Handbook { content.handbook }
    var requirements: Requirements { content.requirements }

    // MARK: - Content

    /// Reload after a content update. Deliberately does not touch entries or
    /// checklist state: a new handbook must never cost a student their record.
    func reloadContent() {
        let loaded = store.load()
        content = loaded
        searchIndex = SearchIndex(handbook: loaded.handbook)
        pdfDocument = PDFDocument(url: loaded.pdfURL)
    }

    func checkForContentUpdate() async {
        let outcome = await updater.checkForUpdate()
        switch outcome {
        case let .updated(from, to):
            reloadContent()
            contentUpdateMessage = "Handbook updated from \(from) to \(to)."
        case .upToDate:
            contentUpdateMessage = nil
        case .ignoredOlder:
            contentUpdateMessage = nil
        case let .rejected(reason):
            // The reader keeps what it has; this is a note, not a failure.
            contentUpdateMessage = "Kept the installed handbook: \(reason)"
        case .unreachable:
            contentUpdateMessage = nil
        }
    }

    // MARK: - Session

    /// Who a code was issued for, so the sign-up screen can ask the student to
    /// confirm rather than type a name the counselor never assigned.
    func lookupCode(_ code: String) async throws -> CodeHolder {
        try await api.lookupCode(code: Self.normalise(code))
    }

    func redeem(code: String, username: String, password: String) async throws {
        let session = try await api.redeem(
            code: Self.normalise(code), username: username, password: password
        )
        adopt(session)
        await refresh()
    }

    /// Codes are read off paper, so case and stray spaces are the student's
    /// least interesting mistake to be punished for.
    static func normalise(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    func signIn(username: String, password: String) async throws {
        adopt(try await api.signIn(username: username, password: password))
        await refresh()
    }

    private func adopt(_ session: Session) {
        self.session = session
        sessionStore?.save(session)
    }

    /// Puts a session in place without a server. Only a UI-test launch reaches
    /// this; nothing in the shipping flow calls it.
    func installSessionForTesting(_ session: Session) {
        self.session = session
    }

    func signOut() async {
        if let token = session?.token { try? await api.signOut(token: token) }
        sessionStore?.clear()
        session = nil
        entries = []
        checklist = []
        serverProgress = nil
        reviewQueue = []
        roster = []
        inviteCodes = []
    }

    func deleteAccount() async throws {
        guard let token = session?.token else { return }
        try await api.deleteAccount(token: token)
        // Clear this device's copy too: deleting an account and leaving its
        // hours cached on the phone would defeat the point.
        if let studentId = account?.id {
            for entry in sync.cachedEntries(for: studentId) {
                modelContext.delete(entry)
            }
            try? modelContext.save()
        }
        await signOut()
    }

    // MARK: - Refresh

    func refresh() async {
        guard let session else { return }
        switch session.account.role {
        case .student:
            await refreshStudent(token: session.token, studentId: session.account.id)
        case .manager, .admin:
            await refreshCounselor(token: session.token)
        }
    }

    private func refreshStudent(token: String, studentId: String) async {
        let result = await sync.sync(token: token, studentId: studentId)
        switch result {
        case .synced:
            isOffline = false
        case .offline:
            isOffline = true
        case .notSignedIn:
            break
        }
        entries = sync.cachedEntries(for: studentId).map(\.asHourEntry)
        queuedCount = sync.queuedCount()

        if let progress = try? await api.progress(token: token) {
            serverProgress = progress
            isOffline = false
        }
        if let items = try? await api.checklist(token: token) {
            checklist = items
        }
    }

    private func refreshCounselor(token: String) async {
        if let submitted = try? await api.entries(token: token, studentId: nil, status: "submitted") {
            reviewQueue = submitted
            isOffline = false
        } else {
            isOffline = true
        }
        if let rows = try? await api.roster(token: token, grade: nil, letterFrom: nil, letterTo: nil) {
            roster = rows
        }
        if let codes = try? await api.inviteCodes(token: token) {
            inviteCodes = codes
        }
    }

    // MARK: - Progress

    /// The figure the UI shows. The server recomputes the same numbers and is
    /// authoritative; the local calculation is what keeps the view correct
    /// offline and updates it the moment an entry changes.
    var progress: ProgressSummary {
        guard let grade = account?.grade else {
            return .empty(grade: 0, threshold: 0, deadline: "")
        }
        return ProgressCalculator.summarise(
            entries: entries, grade: grade, requirements: requirements
        )
    }

    var gradeRequirement: GradeRequirement? {
        account?.grade.flatMap { requirements.requirement(forGrade: $0) }
    }

    // MARK: - Entries

    func createEntry(_ draft: EntryDraft) async {
        guard let account else { return }
        await sync.create(draft: draft, studentId: account.id, token: session?.token)
        await refreshLocalEntries()
    }

    func updateEntry(id: String, draft: EntryDraft) async -> Bool {
        guard let cached = sync.cachedEntry(id: id) else { return false }
        let ok = await sync.update(entry: cached, draft: draft, token: session?.token)
        await refreshLocalEntries()
        return ok
    }

    func deleteEntry(id: String) async -> Bool {
        guard let cached = sync.cachedEntry(id: id) else { return false }
        let ok = await sync.delete(entry: cached, token: session?.token)
        await refreshLocalEntries()
        return ok
    }

    func submitEntry(id: String) async -> Bool {
        guard let cached = sync.cachedEntry(id: id) else { return false }
        let ok = await sync.submit(entry: cached, token: session?.token)
        await refreshLocalEntries()
        return ok
    }

    private func refreshLocalEntries() async {
        guard let studentId = account?.id else { return }
        entries = sync.cachedEntries(for: studentId).map(\.asHourEntry)
        queuedCount = sync.queuedCount()
        if let token = session?.token, let progress = try? await api.progress(token: token) {
            serverProgress = progress
        }
    }

    // MARK: - Checklist

    func setChecklist(itemId: String, checked: Bool) async {
        guard let account else { return }
        if let index = checklist.firstIndex(where: { $0.id == itemId }) {
            checklist[index].checked = checked
        }
        let key = "\(account.id)|\(itemId)"
        let descriptor = FetchDescriptor<CachedChecklistItem>(
            predicate: #Predicate { $0.key == key }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.checked = checked
            existing.updatedAt = Date().timeIntervalSince1970
        } else {
            modelContext.insert(
                CachedChecklistItem(accountId: account.id, itemId: itemId, checked: checked)
            )
        }
        try? modelContext.save()

        if let token = session?.token {
            try? await api.setChecklist(token: token, itemId: itemId, checked: checked)
        }
    }

    /// Checklist rows for this student's grade, with whatever state is cached.
    /// Rows whose requirement id disappeared in a content update are simply not
    /// listed; the stored row stays put in case the id returns.
    var checklistForGrade: [ChecklistItem] {
        guard let account, let grade = account.grade else { return [] }
        let stored = (try? modelContext.fetch(FetchDescriptor<CachedChecklistItem>())) ?? []
        let byItem = Dictionary(
            stored.filter { $0.accountId == account.id }.map { ($0.itemId, $0.checked) },
            uniquingKeysWith: { first, _ in first }
        )
        let serverState = Dictionary(
            checklist.map { ($0.id, $0.checked) }, uniquingKeysWith: { first, _ in first }
        )
        return requirements.checklist(forGrade: grade).map { requirement in
            ChecklistItem(
                id: requirement.id,
                title: requirement.title,
                page: requirement.page,
                checked: byItem[requirement.id] ?? serverState[requirement.id] ?? false
            )
        }
    }

    // MARK: - Counselor actions

    func decide(entryId: String, action: ReviewAction, note: String) async -> Bool {
        guard let token = session?.token else { return false }
        do {
            _ = try await api.decideEntry(token: token, id: entryId, action: action, note: note)
            await refreshCounselor(token: token)
            return true
        } catch {
            lastError = (error as? APIError)?.message ?? error.localizedDescription
            return false
        }
    }

    func logOnBehalf(of studentId: String, draft: EntryDraft) async -> Bool {
        guard let token = session?.token else { return false }
        do {
            _ = try await api.createEntry(token: token, draft: draft, studentId: studentId)
            await refreshCounselor(token: token)
            return true
        } catch {
            lastError = (error as? APIError)?.message ?? error.localizedDescription
            return false
        }
    }

    func loadRoster(grade: Int?, letterFrom: String?, letterTo: String?) async {
        guard let token = session?.token else { return }
        if let rows = try? await api.roster(
            token: token, grade: grade, letterFrom: letterFrom, letterTo: letterTo
        ) {
            roster = rows
        }
    }

    /// Adds students to the program: one invite code per named student, so the
    /// roster exists before anyone signs up.
    func addStudents(_ students: [NewStudent]) async -> [InviteCode] {
        guard let token = session?.token else { return [] }
        do {
            let issued = try await api.createInviteCodes(token: token, students: students)
            await refreshCounselor(token: token)
            return issued
        } catch {
            lastError = (error as? APIError)?.message ?? error.localizedDescription
            return []
        }
    }

    func revokeCode(_ code: String) async {
        guard let token = session?.token else { return }
        try? await api.revokeInviteCode(token: token, code: code)
        await refreshCounselor(token: token)
    }

    // MARK: - Staff

    private(set) var staffList: StaffList?

    var canManageStaff: Bool { role == .admin }

    func loadStaff() async {
        guard let token = session?.token else { return }
        staffList = try? await api.staff(token: token)
    }

    func inviteStaff(
        firstName: String, lastName: String, role: Account.Role
    ) async -> PendingStaffInvite? {
        guard let token = session?.token else { return nil }
        do {
            let invite = try await api.inviteStaff(
                token: token, firstName: firstName, lastName: lastName, role: role
            )
            await loadStaff()
            return invite
        } catch {
            lastError = (error as? APIError)?.message ?? error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func setStaffRole(id: String, role: Account.Role) async -> Bool {
        guard let token = session?.token else { return false }
        do {
            _ = try await api.setStaffRole(token: token, id: id, role: role)
            await loadStaff()
            return true
        } catch {
            lastError = (error as? APIError)?.message ?? error.localizedDescription
            return false
        }
    }

    @discardableResult
    func removeStaff(id: String) async -> Bool {
        guard let token = session?.token else { return false }
        do {
            try await api.removeStaff(token: token, id: id)
            await loadStaff()
            return true
        } catch {
            lastError = (error as? APIError)?.message ?? error.localizedDescription
            return false
        }
    }

    func issuePasswordReset(accountId: String) async -> PasswordReset? {
        guard let token = session?.token else { return nil }
        do {
            return try await api.issuePasswordReset(token: token, accountId: accountId)
        } catch {
            lastError = (error as? APIError)?.message ?? error.localizedDescription
            return nil
        }
    }

    /// Runs for someone who cannot sign in, so it takes no session.
    func resetPassword(code: String, password: String) async throws {
        try await api.resetPassword(code: Self.normalise(code), password: password)
    }

    func history(for entryId: String) async -> [AuditEvent] {
        guard let token = session?.token else { return [] }
        return (try? await api.history(token: token, entryId: entryId)) ?? []
    }

    // MARK: - Export

    func studentCSV() -> String {
        guard let account else { return "" }
        return CSVExport.studentExport(
            entries: entries, requirements: requirements, account: account
        )
    }

    func rosterCSV() -> String {
        CSVExport.rosterExport(rows: roster)
    }
}
