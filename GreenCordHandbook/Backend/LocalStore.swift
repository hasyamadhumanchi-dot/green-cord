import Foundation
import SwiftData

/// An hour entry as it lives on the device.
///
/// This is the app's offline copy of the server's record, plus the queue: an
/// entry created or changed with no network keeps `needsSync` set until it has
/// been accepted by the server.
@Model
final class CachedEntry {
    /// The server's id once it has one. Until then, a locally generated id
    /// prefixed `local-`, which is how `SyncEngine` tells the two apart.
    @Attribute(.unique) var id: String
    var studentId: String
    var serviceDate: String
    var hours: Double
    var category: String
    var entryDescription: String
    var organization: String
    var verifierName: String
    var verifierContact: String
    var evidenceURL: String?
    var counselorEntered: Bool
    var statusRaw: String
    var updatedAt: Double
    var submittedAt: Double?
    var decidedAt: Double?

    /// Set while local changes have not reached the server.
    var needsSync: Bool
    /// Set when the student asked to submit while offline, so the sync pass
    /// knows to submit as well as create.
    var pendingSubmit: Bool

    init(
        id: String,
        studentId: String,
        serviceDate: String,
        hours: Double,
        category: String,
        entryDescription: String,
        organization: String,
        verifierName: String,
        verifierContact: String,
        evidenceURL: String? = nil,
        counselorEntered: Bool = false,
        statusRaw: String = EntryStatus.draft.rawValue,
        updatedAt: Double = Date().timeIntervalSince1970,
        submittedAt: Double? = nil,
        decidedAt: Double? = nil,
        needsSync: Bool = false,
        pendingSubmit: Bool = false
    ) {
        self.id = id
        self.studentId = studentId
        self.serviceDate = serviceDate
        self.hours = hours
        self.category = category
        self.entryDescription = entryDescription
        self.organization = organization
        self.verifierName = verifierName
        self.verifierContact = verifierContact
        self.evidenceURL = evidenceURL
        self.counselorEntered = counselorEntered
        self.statusRaw = statusRaw
        self.updatedAt = updatedAt
        self.submittedAt = submittedAt
        self.decidedAt = decidedAt
        self.needsSync = needsSync
        self.pendingSubmit = pendingSubmit
    }

    var status: EntryStatus {
        get { EntryStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }

    var isLocalOnly: Bool { id.hasPrefix(CachedEntry.localPrefix) }

    static let localPrefix = "local-"

    static func localID() -> String { localPrefix + UUID().uuidString }

    var asHourEntry: HourEntry {
        HourEntry(
            id: id,
            studentId: studentId,
            serviceDate: serviceDate,
            hours: hours,
            category: category,
            organization: organization,
            description: entryDescription,
            verifierName: verifierName,
            verifierContact: verifierContact,
            evidenceURL: evidenceURL,
            counselorEntered: counselorEntered,
            status: status,
            updatedAt: updatedAt,
            submittedAt: submittedAt,
            decidedAt: decidedAt,
            pendingSync: needsSync
        )
    }

    var asDraft: EntryDraft {
        EntryDraft(
            serviceDate: serviceDate,
            hours: hours,
            category: category,
            organization: organization,
            description: entryDescription,
            verifierName: verifierName,
            verifierContact: verifierContact,
            evidenceURL: evidenceURL
        )
    }

    func apply(_ entry: HourEntry) {
        studentId = entry.studentId
        serviceDate = entry.serviceDate
        hours = entry.hours
        category = entry.category
        entryDescription = entry.description
        organization = entry.organization
        verifierName = entry.verifierName
        verifierContact = entry.verifierContact
        evidenceURL = entry.evidenceURL
        counselorEntered = entry.counselorEntered
        status = entry.status
        updatedAt = entry.updatedAt ?? Date().timeIntervalSince1970
        submittedAt = entry.submittedAt
        decidedAt = entry.decidedAt
        needsSync = false
        pendingSubmit = false
    }

    func apply(_ draft: EntryDraft) {
        serviceDate = draft.serviceDate
        hours = draft.hours
        category = draft.category
        organization = draft.organization
        entryDescription = draft.description
        verifierName = draft.verifierName
        verifierContact = draft.verifierContact
        evidenceURL = draft.evidenceURL
        updatedAt = Date().timeIntervalSince1970
    }
}

/// A checklist tick, kept on the device so it survives relaunch and works with
/// no network. Keyed by requirement id, which is why a content update that
/// renames a requirement cannot destroy anything: unknown ids are simply not
/// displayed, and the row stays put in case the id comes back.
@Model
final class CachedChecklistItem {
    @Attribute(.unique) var key: String
    var accountId: String
    var itemId: String
    var checked: Bool
    var needsSync: Bool
    var updatedAt: Double

    init(accountId: String, itemId: String, checked: Bool, needsSync: Bool = false) {
        key = "\(accountId)|\(itemId)"
        self.accountId = accountId
        self.itemId = itemId
        self.checked = checked
        self.needsSync = needsSync
        updatedAt = Date().timeIntervalSince1970
    }
}

enum LocalStore {
    /// Every model the app persists. Used for both the real container and the
    /// in-memory one the tests build.
    static let schema = Schema([CachedEntry.self, CachedChecklistItem.self])

    static func container(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }
}
