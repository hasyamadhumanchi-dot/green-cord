import Foundation

/// Everything the app asks of the server.
///
/// The server is authoritative for every rule this protocol exposes. The app
/// mirrors those rules locally only to decide which controls to show and to keep
/// working offline; it never relies on the mirror for enforcement.
protocol GreenCordAPI: Sendable {
    /// Who a code was issued for. Unauthenticated: it runs before an account
    /// exists, so the student can confirm their name rather than type one.
    func lookupCode(code: String) async throws -> CodeHolder
    /// The name comes from the code, never from the app.
    func redeem(code: String, username: String, password: String) async throws -> Session
    func signIn(username: String, password: String) async throws -> Session
    func signOut(token: String) async throws

    func account(token: String) async throws -> Account
    func deleteAccount(token: String) async throws

    func entries(token: String) async throws -> [HourEntry]
    func entries(token: String, studentId: String?, status: String?) async throws -> [HourEntry]
    func createEntry(token: String, draft: EntryDraft, studentId: String?) async throws -> HourEntry
    func updateEntry(token: String, id: String, changes: EntryDraft) async throws -> HourEntry
    func deleteEntry(token: String, id: String) async throws
    func submitEntry(token: String, id: String) async throws -> HourEntry
    func decideEntry(token: String, id: String, action: ReviewAction, note: String) async throws -> HourEntry
    func history(token: String, entryId: String) async throws -> [AuditEvent]

    func progress(token: String) async throws -> ServerProgress
    func roster(token: String, grade: Int?, letterFrom: String?, letterTo: String?) async throws -> [RosterRow]
    func rosterCSV(token: String, grade: Int?, letterFrom: String?, letterTo: String?) async throws -> String
    func exportCSV(token: String) async throws -> String

    func inviteCodes(token: String) async throws -> [InviteCode]
    func createInviteCodes(token: String, students: [NewStudent]) async throws -> [InviteCode]
    func revokeInviteCode(token: String, code: String) async throws

    func staff(token: String) async throws -> StaffList
    func inviteStaff(
        token: String, firstName: String, lastName: String, role: Account.Role
    ) async throws -> PendingStaffInvite
    func setStaffRole(token: String, id: String, role: Account.Role) async throws -> StaffMember
    func removeStaff(token: String, id: String) async throws
    func issuePasswordReset(token: String, accountId: String) async throws -> PasswordReset
    /// Unauthenticated: it runs for someone who cannot sign in.
    func resetPassword(code: String, password: String) async throws

    func checklist(token: String) async throws -> [ChecklistItem]
    func setChecklist(token: String, itemId: String, checked: Bool) async throws
}

struct Session: Codable, Hashable {
    var token: String
    var account: Account
}

/// The fields a student fills in. Separate from `HourEntry` because a draft has
/// no id, status or review history yet.
struct EntryDraft: Codable, Hashable {
    var serviceDate: String
    var hours: Double
    var category: String
    var organization: String
    var description: String
    var verifierName: String
    var verifierContact: String
    var evidenceURL: String?

    static let empty = EntryDraft(
        serviceDate: DateFormatting.isoDay.string(from: Date()),
        hours: 0,
        category: "community",
        organization: "",
        description: "",
        verifierName: "",
        verifierContact: "",
        evidenceURL: nil
    )

    var isComplete: Bool {
        hours > 0
            && !organization.trimmingCharacters(in: .whitespaces).isEmpty
            && !description.trimmingCharacters(in: .whitespaces).isEmpty
            && !verifierName.trimmingCharacters(in: .whitespaces).isEmpty
            && !verifierContact.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

enum ReviewAction: String, Codable, CaseIterable {
    case approve
    case reject
    case requestRevision = "request_revision"

    var displayName: String {
        switch self {
        case .approve: return "Approve"
        case .reject: return "Do not accept"
        case .requestRevision: return "Ask for changes"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .approve: return "Approve these hours"
        case .reject: return "Do not accept these hours"
        case .requestRevision: return "Ask the student for changes"
        }
    }
}

struct AuditEvent: Codable, Hashable, Identifiable {
    var at: Double
    var actorRole: String?
    var action: String
    var before: HourEntry?
    var after: HourEntry?

    var id: String { "\(at)-\(action)" }

    var date: Date { Date(timeIntervalSince1970: at) }

    var summary: String {
        switch action {
        case "entry.created": return "Logged"
        case "entry.submitted": return "Sent for review"
        case "entry.approved": return "Approved"
        case "entry.rejected": return "Not accepted"
        case "entry.revision_requested": return "Changes requested"
        case "entry.revised_by_counselor": return "Corrected by the counselor"
        case "entry.updated": return "Edited"
        default: return action
        }
    }
}

/// What the server computes. The app compares its own figure against this and
/// trusts the server's.
struct ServerProgress: Codable, Hashable {
    var grade: Int
    var thresholdHours: Double?
    var verifiedHours: Double
    var pendingHours: Double
    var percentComplete: Double?
    var byCategory: [String: Double]
    var distinctOrganizations: Int
    var organizations: [String]
    var submissionDeadline: String?
}

/// An error the server reported, with the message it wants shown to the person.
struct APIError: Error, LocalizedError, Equatable {
    var status: Int
    var code: String
    var message: String

    var errorDescription: String? { message }

    /// True when the failure is the network rather than the request, so the app
    /// can fall back to its offline copy instead of showing an error.
    var isTransport: Bool { status == 0 }

    static let offline = APIError(
        status: 0, code: "offline",
        message: "You are offline. Your work is saved on this device and will sync when you reconnect."
    )
}
