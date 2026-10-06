import Foundation

/// Where an entry sits in the counselor's review workflow.
///
/// The server is authoritative about transitions; these rules exist so the app
/// can hide controls a student is not allowed to use and can work offline. The
/// two agree by construction: both allow edits only in `draft`, `rejected` and
/// `revisionRequested`, and `approved` is terminal for a student in both.
enum EntryStatus: String, Codable, CaseIterable, Hashable {
    case draft
    case submitted
    case approved
    case rejected
    case revisionRequested = "revision_requested"

    var displayName: String {
        switch self {
        case .draft: return "Draft"
        case .submitted: return "Awaiting review"
        case .approved: return "Approved"
        case .rejected: return "Not accepted"
        case .revisionRequested: return "Changes requested"
        }
    }

    /// What a student can do next, in their own words.
    var studentExplanation: String {
        switch self {
        case .draft:
            return "Not sent yet. You can still change it."
        case .submitted:
            return "Your counselor has it. You cannot change it while it is being reviewed."
        case .approved:
            return "Counted towards your total. Approved hours are permanent - ask your counselor if a correction is needed."
        case .rejected:
            return "Your counselor did not accept this one. Read their note, fix it, and send it again."
        case .revisionRequested:
            return "Your counselor asked for a change. Update it and send it again."
        }
    }

    /// True only where a student may edit, delete or submit.
    var isStudentEditable: Bool {
        switch self {
        case .draft, .rejected, .revisionRequested: return true
        case .submitted, .approved: return false
        }
    }

    /// Approved hours are permanent on the student's record.
    var isPermanent: Bool { self == .approved }

    /// Counts towards the verified total. Only approved hours ever do.
    var countsAsVerified: Bool { self == .approved }

    /// Sitting with the counselor, waiting on a decision.
    var countsAsPending: Bool { self == .submitted }
}

struct HourEntry: Codable, Hashable, Identifiable {
    var id: String
    var studentId: String
    var serviceDate: String        // YYYY-MM-DD, as the server stores it
    var hours: Double
    var category: String
    var organization: String
    var description: String
    var verifierName: String
    var verifierContact: String
    var evidenceURL: String?
    var counselorEntered: Bool
    var status: EntryStatus
    var decidedBy: Decision?
    var updatedAt: Double?
    var submittedAt: Double?
    var decidedAt: Double?

    /// Set while an entry made offline has not reached the server yet. The id is
    /// a client-generated one until then.
    var pendingSync: Bool = false

    enum CodingKeys: String, CodingKey {
        case decidedBy
        case id, studentId, serviceDate, hours, category, organization, description
        case verifierName, verifierContact, evidenceURL, counselorEntered, status
        case updatedAt, submittedAt, decidedAt
    }

    var date: Date? { DateFormatting.isoDay.date(from: serviceDate) }

    var displayDate: String {
        date.map { DateFormatting.friendly.string(from: $0) } ?? serviceDate
    }
}

enum DateFormatting {
    static let isoDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let friendly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

struct Account: Codable, Hashable, Identifiable {
    enum Role: String, Codable, CaseIterable, Hashable {
        case student
        /// Reviews hours and manages students. Everything but staff accounts.
        case manager
        /// Everything a manager can, plus creating and removing staff.
        case admin

        /// Anyone who can review hours.
        var isStaff: Bool { self == .manager || self == .admin }

        var title: String {
            switch self {
            case .student: return "Student"
            case .manager: return "Manager"
            case .admin: return "Admin"
            }
        }

        var explanation: String {
            switch self {
            case .student:
                return "Logs their own hours."
            case .manager:
                return "Reviews hours, adds students and hands out codes."
            case .admin:
                return "Everything a manager can, plus adding and removing staff."
            }
        }
    }

    var id: String
    var role: Role
    var displayName: String
    var lastName: String
    var grade: Int?
    var username: String
    var thresholdHours: Double?
    var submissionDeadline: String?
}

/// Who approved, rejected or returned an entry.
///
/// Kept on the entry itself because with several people reviewing, "approved"
/// is only half the answer. The name stays attached even after that person
/// loses staff access: an approval records who verified the hours.
struct Decision: Codable, Hashable {
    var name: String
    var role: Account.Role
    var action: String
    var note: String
    var at: Double

    var verb: String {
        switch action {
        case "approve": return "Approved"
        case "reject": return "Not accepted"
        case "request_revision": return "Changes requested"
        default: return "Reviewed"
        }
    }

    var summary: String { "\(verb) by \(name)" }
}

/// A member of staff.
struct StaffMember: Codable, Hashable, Identifiable {
    var id: String
    var displayName: String
    var lastName: String
    var username: String
    var role: Account.Role
    var createdAt: Double
}

/// A staff invite that has been issued but not redeemed.
struct PendingStaffInvite: Codable, Hashable, Identifiable {
    var code: String
    var firstName: String
    var lastName: String
    var role: Account.Role
    var expiresAt: Double
    var expired: Bool

    var id: String { code }
    var fullName: String {
        "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
    }
}

/// Everything the staff screen shows.
struct StaffList: Codable, Hashable {
    var staff: [StaffMember]
    var pending: [PendingStaffInvite]
    var admins: Int
    /// False for a manager: they can see who else reviews, but change nothing.
    var canManage: Bool
}

/// A one-time code that lets someone set a new password.
struct PasswordReset: Codable, Hashable {
    var code: String
    var `for`: String
    var username: String
    var expiresAt: Double
}

struct RosterRow: Codable, Hashable, Identifiable {
    var studentId: String
    var displayName: String
    var lastName: String
    var grade: Int
    var verifiedHours: Double
    var pendingHours: Double
    var thresholdHours: Double
    var percentComplete: Double
    var lastActivityAt: Double?
    /// False for a student the counselor has issued a code to who has not
    /// signed up yet. Absent from older responses, so it reads as joined.
    var joined: Bool?

    var id: String { studentId }

    var hasJoined: Bool { joined ?? true }

    var lastActivityText: String {
        guard let lastActivityAt else { return "No activity" }
        return DateFormatting.friendly.string(from: Date(timeIntervalSince1970: lastActivityAt))
    }
}

struct InviteCode: Codable, Hashable, Identifiable {
    enum State: String, Codable {
        case outstanding
        case redeemed
        case revoked
        case expired
    }

    var code: String
    /// The student the counselor issued this code to. A code is never
    /// anonymous: it is how the counselor tracks who has joined.
    var firstName: String
    var lastName: String
    var grade: Int
    var state: State
    var createdAt: Double
    var expiresAt: Double
    var redeemedAt: Double?

    var id: String { code }

    var fullName: String {
        "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
    }
}

/// Who an invite code belongs to, read before an account exists so the student
/// confirms the name their counselor assigned instead of typing their own.
struct CodeHolder: Codable, Hashable {
    var code: String
    var firstName: String
    var lastName: String
    var grade: Int

    var fullName: String {
        "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
    }
}

/// A student the counselor is adding to the program. One of these becomes one
/// invite code.
struct NewStudent: Hashable, Identifiable, Codable {
    var firstName: String
    var lastName: String
    var grade: Int

    var id: String { "\(lastName)|\(firstName)|\(grade)" }

    var isComplete: Bool {
        !firstName.trimmingCharacters(in: .whitespaces).isEmpty
            && !lastName.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

struct ChecklistItem: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var page: Int
    var checked: Bool
}
