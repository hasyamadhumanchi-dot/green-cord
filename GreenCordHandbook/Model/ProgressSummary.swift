import Foundation

/// A student's standing against their own grade's requirement.
///
/// Verified and pending are separate numbers and are never added together: a
/// student who has logged 40 hours and had 10 approved has 10 hours, not 50.
/// The UI shows them as two distinct figures for the same reason.
struct ProgressSummary: Codable, Hashable {
    var grade: Int
    var thresholdHours: Double
    /// Approved hours only.
    var verifiedHours: Double
    /// Submitted and awaiting the counselor's decision.
    var pendingHours: Double
    var byCategory: [String: Double]
    var distinctOrganizations: Int
    var organizations: [String]
    var submissionDeadline: String

    /// Verified hours as a percentage of this grade's threshold. Not capped: a
    /// senior on 150 of 100 hours has done 150% of the requirement and should
    /// see that.
    var percentComplete: Double {
        guard thresholdHours > 0 else { return 0 }
        return ((verifiedHours / thresholdHours) * 1000).rounded() / 10
    }

    /// Clamped to 0...1 for progress bars, which cannot show more than full.
    var progressFraction: Double {
        guard thresholdHours > 0 else { return 0 }
        return min(1, max(0, verifiedHours / thresholdHours))
    }

    var hoursRemaining: Double {
        max(0, thresholdHours - verifiedHours)
    }

    var hasMetRequirement: Bool { verifiedHours >= thresholdHours }

    static func empty(grade: Int, threshold: Double, deadline: String) -> ProgressSummary {
        ProgressSummary(
            grade: grade,
            thresholdHours: threshold,
            verifiedHours: 0,
            pendingHours: 0,
            byCategory: [:],
            distinctOrganizations: 0,
            organizations: [],
            submissionDeadline: deadline
        )
    }
}

/// Recomputes a summary from entries the app holds locally, so the progress view
/// is correct offline and updates the instant an entry changes. The server
/// recomputes the same numbers independently and is authoritative.
enum ProgressCalculator {
    static func summarise(
        entries: [HourEntry],
        grade: Int,
        requirements: Requirements
    ) -> ProgressSummary {
        let requirement = requirements.requirement(forGrade: grade)
        let threshold = requirement?.thresholdHours.value ?? 0
        let deadline = requirement?.submissionDeadline.value ?? "Not specified in the handbook"

        let approved = entries.filter { $0.status.countsAsVerified }
        let pending = entries.filter { $0.status.countsAsPending }

        var byCategory: [String: Double] = [:]
        for entry in approved {
            byCategory[entry.category, default: 0] += entry.hours
        }
        byCategory = byCategory.mapValues { round($0 * 100) / 100 }

        let organizations = Set(approved.map(\.organization)).sorted()

        return ProgressSummary(
            grade: grade,
            thresholdHours: threshold,
            verifiedHours: round(approved.reduce(0) { $0 + $1.hours } * 100) / 100,
            pendingHours: round(pending.reduce(0) { $0 + $1.hours } * 100) / 100,
            byCategory: byCategory,
            distinctOrganizations: organizations.count,
            organizations: organizations,
            submissionDeadline: deadline
        )
    }

    /// Where a category's approved hours stand against the handbook's cap for it.
    /// Returns nil when the handbook sets no cap, so the UI can say so rather
    /// than invent a limit.
    static func capUsage(
        categoryId: String,
        summary: ProgressSummary,
        requirements: Requirements
    ) -> (used: Double, cap: Double)? {
        guard let cap = requirements.category(id: categoryId)?.maxHours.hours else { return nil }
        return (summary.byCategory[categoryId] ?? 0, cap)
    }
}
