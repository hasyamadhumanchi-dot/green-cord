import SwiftData
import SwiftUI

@main
struct GreenCordHandbookApp: App {
    @State private var model: AppModel
    private let container: ModelContainer

    init() {
        // A UI test run gets a clean in-memory store and a scripted backend, so
        // one test can never see another's leftovers.
        let isUITest = ProcessInfo.processInfo.arguments.contains("-uiTesting")

        let container: ModelContainer
        do {
            container = try LocalStore.container(inMemory: isUITest)
        } catch {
            // Falling back to memory keeps the handbook readable even if the
            // on-disk store cannot be opened; the reader does not need it.
            container = try! LocalStore.container(inMemory: true)
        }
        self.container = container

        let store = ContentStore()
        let api = AppEnvironment.makeAPI()
        let network = AppEnvironment.makeNetwork()
        _model = State(
            wrappedValue: AppModel(
                store: store,
                api: api,
                network: network,
                modelContext: ModelContext(container),
                // A UI test starts signed out every time, so it never inherits
                // a session from a previous run or from the developer's own use.
                sessionStore: isUITest ? nil : SessionStore()
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Brand.maroon)
                .task {
                    await AppEnvironment.prepareForUITestingIfNeeded(model: model)
                    // A session restored from the keychain has stale numbers
                    // until this runs; offline it keeps the cached ones.
                    await model.refresh()
                    await model.checkForContentUpdate()
                }
        }
        .modelContainer(container)
    }
}

/// How the app is wired up at launch.
///
/// The server address is a build-time setting, read from Info.plist so the demo
/// build and a future TestFlight build differ by configuration rather than by
/// code. With no address configured the app runs as a reader: the handbook, the
/// search and the requirements all work, and the parts that need an account say
/// so.
enum AppEnvironment {
    static var backendURL: URL? {
        if let override = ProcessInfo.processInfo.environment["GREENCORD_BACKEND_URL"],
           let url = URL(string: override) {
            return url
        }
        // A UI test gets the bundled address only if the run explicitly passed
        // one, so the suite behaves the same on any machine.
        if ProcessInfo.processInfo.arguments.contains("-uiTesting") { return nil }
        guard
            let value = Bundle.main.object(forInfoDictionaryKey: "GreenCordBackendURL") as? String,
            !value.isEmpty,
            let url = URL(string: value)
        else { return nil }
        return url
    }

    static func makeAPI() -> GreenCordAPI {
        guard let backendURL else { return UnreachableAPI() }
        return RemoteAPI(baseURL: backendURL)
    }

    static func makeNetwork() -> NetworkFetching {
        URLSession.shared
    }

    /// Signs a UI test in without typing, when the run asks for it.
    ///
    /// `-signInAs` goes through the real server. `-uiTestingRole` does not: it
    /// installs a session locally so the reader and the navigation can be tested
    /// with no backend at all, which is how the suite runs by default now that
    /// the app is gated behind sign-in.
    @MainActor
    static func prepareForUITestingIfNeeded(model: AppModel) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-uiTesting") else { return }

        if let index = arguments.firstIndex(of: "-signInAs"), index + 2 < arguments.count {
            try? await model.signIn(
                username: arguments[index + 1], password: arguments[index + 2]
            )
            return
        }

        guard let index = arguments.firstIndex(of: "-uiTestingRole"),
              index + 1 < arguments.count
        else { return }

        // "counselor" is still accepted so older invocations keep working.
        let role: Account.Role
        switch arguments[index + 1] {
        case "admin", "counselor": role = .admin
        case "manager": role = .manager
        default: role = .student
        }
        model.installSessionForTesting(
            Session(
                token: "ui-test-token",
                account: Account(
                    id: "ui-test-account",
                    role: role,
                    displayName: role.isStaff ? "Test \(role.title)" : "Test Student",
                    lastName: role.isStaff ? role.title : "Student",
                    grade: role.isStaff ? nil : 11,
                    username: role.isStaff ? "teststaff" : "teststudent",
                    thresholdHours: nil,
                    submissionDeadline: nil
                )
            )
        )
    }
}

/// Used when no server is configured. Every call reports the same thing the app
/// would say if the phone were in a tunnel, which is exactly the behaviour the
/// reading half of the app is built to survive.
struct UnreachableAPI: GreenCordAPI {
    func lookupCode(code: String) async throws -> CodeHolder { throw APIError.offline }
    func redeem(code: String, username: String, password: String) async throws -> Session {
        throw APIError.offline
    }
    func signIn(username: String, password: String) async throws -> Session { throw APIError.offline }
    func signOut(token: String) async throws {}
    func account(token: String) async throws -> Account { throw APIError.offline }
    func deleteAccount(token: String) async throws { throw APIError.offline }
    func entries(token: String) async throws -> [HourEntry] { throw APIError.offline }
    func entries(token: String, studentId: String?, status: String?) async throws -> [HourEntry] {
        throw APIError.offline
    }
    func createEntry(token: String, draft: EntryDraft, studentId: String?) async throws -> HourEntry {
        throw APIError.offline
    }
    func updateEntry(token: String, id: String, changes: EntryDraft) async throws -> HourEntry {
        throw APIError.offline
    }
    func deleteEntry(token: String, id: String) async throws { throw APIError.offline }
    func submitEntry(token: String, id: String) async throws -> HourEntry { throw APIError.offline }
    func decideEntry(token: String, id: String, action: ReviewAction, note: String) async throws -> HourEntry {
        throw APIError.offline
    }
    func history(token: String, entryId: String) async throws -> [AuditEvent] { throw APIError.offline }
    func progress(token: String) async throws -> ServerProgress { throw APIError.offline }
    func roster(token: String, grade: Int?, letterFrom: String?, letterTo: String?) async throws -> [RosterRow] {
        throw APIError.offline
    }
    func rosterCSV(token: String, grade: Int?, letterFrom: String?, letterTo: String?) async throws -> String {
        throw APIError.offline
    }
    func exportCSV(token: String) async throws -> String { throw APIError.offline }
    func inviteCodes(token: String) async throws -> [InviteCode] { throw APIError.offline }
    func createInviteCodes(
        token: String, students: [NewStudent]
    ) async throws -> [InviteCode] {
        throw APIError.offline
    }
    func revokeInviteCode(token: String, code: String) async throws { throw APIError.offline }
    func staff(token: String) async throws -> StaffList { throw APIError.offline }
    func inviteStaff(
        token: String, firstName: String, lastName: String, role: Account.Role
    ) async throws -> PendingStaffInvite { throw APIError.offline }
    func setStaffRole(
        token: String, id: String, role: Account.Role
    ) async throws -> StaffMember { throw APIError.offline }
    func removeStaff(token: String, id: String) async throws { throw APIError.offline }
    func issuePasswordReset(
        token: String, accountId: String
    ) async throws -> PasswordReset { throw APIError.offline }
    func resetPassword(code: String, password: String) async throws { throw APIError.offline }
    func checklist(token: String) async throws -> [ChecklistItem] { throw APIError.offline }
    func setChecklist(token: String, itemId: String, checked: Bool) async throws {
        throw APIError.offline
    }
}
