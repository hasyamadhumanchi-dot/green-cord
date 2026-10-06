import Foundation
import SwiftData

/// Keeps the device's copy and the server's copy in step.
///
/// The rule that matters is that a queued entry reaches the server exactly once.
/// A locally created entry carries a `local-` id; when the server accepts it the
/// row is rewritten with the server's id, so the next pass no longer sees it as
/// new. Nothing is sent twice, and a pull never resurrects a row that was
/// already pushed.
@MainActor
final class SyncEngine {
    enum Result: Equatable {
        case synced(pushed: Int, pulled: Int)
        case offline(queued: Int)
        case notSignedIn
    }

    private let api: GreenCordAPI
    private let context: ModelContext

    init(api: GreenCordAPI, context: ModelContext) {
        self.api = api
        self.context = context
    }

    // MARK: - Reading

    func cachedEntries(for studentId: String) -> [CachedEntry] {
        let descriptor = FetchDescriptor<CachedEntry>(
            predicate: #Predicate { $0.studentId == studentId },
            sortBy: [SortDescriptor(\.serviceDate, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func cachedEntry(id: String) -> CachedEntry? {
        let descriptor = FetchDescriptor<CachedEntry>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    func queuedCount() -> Int {
        let descriptor = FetchDescriptor<CachedEntry>(predicate: #Predicate { $0.needsSync })
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    // MARK: - Writing

    /// Create an entry. Works offline: the row lands in the queue and is pushed
    /// on the next successful sync.
    @discardableResult
    func create(draft: EntryDraft, studentId: String, token: String?) async -> CachedEntry {
        let cached = CachedEntry(
            id: CachedEntry.localID(),
            studentId: studentId,
            serviceDate: draft.serviceDate,
            hours: draft.hours,
            category: draft.category,
            entryDescription: draft.description,
            organization: draft.organization,
            verifierName: draft.verifierName,
            verifierContact: draft.verifierContact,
            evidenceURL: draft.evidenceURL,
            needsSync: true
        )
        context.insert(cached)
        try? context.save()

        if let token {
            if let remote = try? await api.createEntry(token: token, draft: draft, studentId: nil) {
                replaceLocalID(cached, with: remote)
            }
        }
        return cached
    }

    /// Edit an entry. Refused locally for anything the student may not change,
    /// which is the same set the server refuses.
    @discardableResult
    func update(entry: CachedEntry, draft: EntryDraft, token: String?) async -> Bool {
        guard entry.status.isStudentEditable else { return false }
        entry.apply(draft)
        entry.needsSync = true
        try? context.save()

        if let token, !entry.isLocalOnly {
            if let remote = try? await api.updateEntry(token: token, id: entry.id, changes: draft) {
                entry.apply(remote)
                try? context.save()
            }
        }
        return true
    }

    @discardableResult
    func delete(entry: CachedEntry, token: String?) async -> Bool {
        guard entry.status.isStudentEditable else { return false }
        let id = entry.id
        let wasLocalOnly = entry.isLocalOnly
        context.delete(entry)
        try? context.save()
        if let token, !wasLocalOnly {
            try? await api.deleteEntry(token: token, id: id)
        }
        return true
    }

    @discardableResult
    func submit(entry: CachedEntry, token: String?) async -> Bool {
        guard entry.status.isStudentEditable else { return false }
        entry.status = .submitted
        entry.submittedAt = Date().timeIntervalSince1970
        entry.needsSync = true
        entry.pendingSubmit = true
        try? context.save()

        if let token, !entry.isLocalOnly,
           let remote = try? await api.submitEntry(token: token, id: entry.id) {
            entry.apply(remote)
            try? context.save()
        }
        return true
    }

    // MARK: - Syncing

    /// Push everything queued, then pull the server's view.
    ///
    /// Push happens first so a freshly created entry is not overwritten by a
    /// pull that predates it.
    @discardableResult
    func sync(token: String?, studentId: String) async -> Result {
        guard let token else { return .notSignedIn }

        var pushed = 0
        for entry in queuedEntries(for: studentId) {
            if await push(entry, token: token) { pushed += 1 }
        }

        guard let remote = try? await api.entries(token: token) else {
            return .offline(queued: queuedCount())
        }
        let pulled = merge(remote: remote, studentId: studentId)
        return .synced(pushed: pushed, pulled: pulled)
    }

    private func queuedEntries(for studentId: String) -> [CachedEntry] {
        let descriptor = FetchDescriptor<CachedEntry>(
            predicate: #Predicate { $0.studentId == studentId && $0.needsSync },
            sortBy: [SortDescriptor(\.updatedAt, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Send one queued row. Returns true when the server has it.
    private func push(_ entry: CachedEntry, token: String) async -> Bool {
        if entry.isLocalOnly {
            guard let remote = try? await api.createEntry(
                token: token, draft: entry.asDraft, studentId: nil
            ) else { return false }
            let shouldSubmit = entry.pendingSubmit
            replaceLocalID(entry, with: remote)
            if shouldSubmit,
               let submitted = try? await api.submitEntry(token: token, id: entry.id) {
                entry.apply(submitted)
                try? context.save()
            }
            return true
        }

        guard entry.status.isStudentEditable || entry.pendingSubmit else {
            // Nothing a student is allowed to push. Drop the flag so the queue
            // does not spin on a row the server already owns.
            entry.needsSync = false
            entry.pendingSubmit = false
            try? context.save()
            return false
        }

        if let remote = try? await api.updateEntry(
            token: token, id: entry.id, changes: entry.asDraft
        ) {
            entry.apply(remote)
        } else {
            return false
        }
        if entry.pendingSubmit,
           let submitted = try? await api.submitEntry(token: token, id: entry.id) {
            entry.apply(submitted)
        }
        try? context.save()
        return true
    }

    /// Adopt the server's id for a row that was created offline, so it is never
    /// pushed a second time.
    private func replaceLocalID(_ entry: CachedEntry, with remote: HourEntry) {
        entry.id = remote.id
        entry.apply(remote)
        try? context.save()
    }

    /// Reconcile the server's list with the device's.
    ///
    /// Rows still waiting to be pushed are left alone; everything else takes the
    /// server's values, and a row the server no longer has is removed - unless
    /// it has never been pushed, in which case it is still the student's work.
    @discardableResult
    func merge(remote: [HourEntry], studentId: String) -> Int {
        var byID: [String: CachedEntry] = [:]
        for entry in cachedEntries(for: studentId) {
            byID[entry.id] = entry
        }

        var seen = Set<String>()
        for entry in remote {
            seen.insert(entry.id)
            if let existing = byID[entry.id] {
                guard !existing.needsSync else { continue }
                existing.apply(entry)
            } else {
                let cached = CachedEntry(
                    id: entry.id,
                    studentId: entry.studentId,
                    serviceDate: entry.serviceDate,
                    hours: entry.hours,
                    category: entry.category,
                    entryDescription: entry.description,
                    organization: entry.organization,
                    verifierName: entry.verifierName,
                    verifierContact: entry.verifierContact,
                    evidenceURL: entry.evidenceURL,
                    counselorEntered: entry.counselorEntered,
                    statusRaw: entry.status.rawValue,
                    updatedAt: entry.updatedAt ?? Date().timeIntervalSince1970,
                    submittedAt: entry.submittedAt,
                    decidedAt: entry.decidedAt
                )
                context.insert(cached)
            }
        }

        for (id, entry) in byID where !seen.contains(id) {
            // Never delete something that has not reached the server yet.
            if !entry.needsSync { context.delete(entry) }
        }

        try? context.save()
        return remote.count
    }
}
