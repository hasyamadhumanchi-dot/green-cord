import Foundation
import Testing
@testable import GreenCordHandbook

/// Gates C11 and C13, and the client half of B9: the numbers the app shows come
/// from the handbook and are computed the way the handbook describes.
@Suite("Requirements and progress")
struct RequirementsTests {

    static func loadRequirements() throws -> Requirements {
        let url = try #require(
            Bundle(for: BundleToken.self).url(forResource: "requirements", withExtension: "json")
        )
        return try JSONDecoder().decode(Requirements.self, from: Data(contentsOf: url))
    }

    static func entry(
        _ hours: Double,
        _ status: EntryStatus,
        category: String = "community",
        organization: String = "Food Bank"
    ) -> HourEntry {
        HourEntry(
            id: UUID().uuidString,
            studentId: "student-1",
            serviceDate: "2026-09-01",
            hours: hours,
            category: category,
            organization: organization,
            description: "Sorted donations",
            verifierName: "Supervisor",
            verifierContact: "supervisor@example.org",
            evidenceURL: nil,
            counselorEntered: false,
            status: status,
            updatedAt: nil,
            submittedAt: nil,
            decidedAt: nil
        )
    }

    // MARK: - The handbook's own numbers

    @Test("Each grade has its own threshold, taken from page 6")
    func perGradeThresholds() throws {
        let requirements = try Self.loadRequirements()
        let expected: [Int: Double] = [9: 25, 10: 50, 11: 75, 12: 100]

        for (grade, hours) in expected {
            let requirement = try #require(requirements.requirement(forGrade: grade))
            #expect(requirement.thresholdHours.value == hours)
            #expect(requirement.thresholdHours.page == 6, "the threshold is stated on page 6")
        }
        #expect(Set(requirements.grades.map(\.grade)) == [9, 10, 11, 12])
    }

    @Test("Deadlines differ between the lower grades and senior year")
    func perGradeDeadlines() throws {
        let requirements = try Self.loadRequirements()
        for grade in [9, 10, 11] {
            let requirement = try #require(requirements.requirement(forGrade: grade))
            #expect(requirement.submissionDeadline.value == "April 15")
        }
        let senior = try #require(requirements.requirement(forGrade: 12))
        #expect(senior.submissionDeadline.value == "April 1")
    }

    @Test("Category caps are the handbook's, and an uncapped one says so")
    func categoryCaps() throws {
        let requirements = try Self.loadRequirements()
        #expect(requirements.category(id: "school-based")?.maxHours.hours == 60)
        #expect(requirements.category(id: "faith-based")?.maxHours.hours == 40)
        // The handbook sets no overall cap for general community service, so the
        // app must say so rather than invent one.
        #expect(requirements.category(id: "community")?.maxHours.hours == nil)
        #expect(
            requirements.category(id: "community")?.maxHours.displayText
                == "Not specified in the handbook"
        )
        #expect(requirements.limits.singleOrganizationMaxHours.value == 40)
        #expect(requirements.limits.minimumDistinctOrganizationsSeniorYear.value == 3)
    }

    @Test("Senior distinction bands match pages 7 and 10")
    func distinctionBands() throws {
        let requirements = try Self.loadRequirements()
        #expect(requirements.distinction(forHours: 99) == nil)
        #expect(requirements.distinction(forHours: 100)?.id == "green")
        #expect(requirements.distinction(forHours: 149)?.id == "green")
        #expect(requirements.distinction(forHours: 150)?.id == "silver")
        #expect(requirements.distinction(forHours: 199)?.id == "silver")
        #expect(requirements.distinction(forHours: 200)?.id == "gold")
        #expect(requirements.distinction(forHours: 400)?.id == "gold")
    }

    @Test("C13 the checklist is per grade, and the senior rule is senior-only")
    func checklistPerGrade() throws {
        let requirements = try Self.loadRequirements()
        for grade in [9, 10, 11, 12] {
            let items = requirements.checklist(forGrade: grade)
            #expect(!items.isEmpty)
            #expect(items.contains { $0.id == "membership-fee" })
        }
        #expect(requirements.checklist(forGrade: 12).contains { $0.id == "three-organizations" })
        #expect(!requirements.checklist(forGrade: 9).contains { $0.id == "three-organizations" })
    }

    @Test("Everything the handbook leaves unstated is recorded as unspecified")
    func unspecifiedIsSurfaced() throws {
        let requirements = try Self.loadRequirements()
        #expect(!requirements.unspecified.isEmpty)
        for item in requirements.unspecified {
            #expect(!item.reason.isEmpty)
            #expect((1...20).contains(item.page))
        }
    }

    // MARK: - Progress

    @Test("C11 approved and pending are separate figures and are never summed")
    func approvedAndPendingStaySeparate() throws {
        let requirements = try Self.loadRequirements()
        let entries = [
            Self.entry(10, .approved),
            Self.entry(7, .submitted, category: "school-based"),
            Self.entry(4, .draft, category: "faith-based"),
            Self.entry(99, .rejected),
            Self.entry(3, .revisionRequested),
        ]
        let summary = ProgressCalculator.summarise(
            entries: entries, grade: 9, requirements: requirements
        )

        #expect(summary.verifiedHours == 10)
        #expect(summary.pendingHours == 7)
        // 10 + 7 + 4 + 99 + 3 = 123. None of those totals may appear.
        #expect(summary.verifiedHours != 17)
        #expect(summary.verifiedHours != 123)
        #expect(summary.thresholdHours == 25)
        #expect(summary.percentComplete == 40)
        #expect(summary.byCategory == ["community": 10])
    }

    @Test("C11 zero hours, exactly at threshold, and over threshold")
    func boundaries() throws {
        let requirements = try Self.loadRequirements()

        let zero = ProgressCalculator.summarise(entries: [], grade: 9, requirements: requirements)
        #expect(zero.verifiedHours == 0)
        #expect(zero.percentComplete == 0)
        #expect(zero.progressFraction == 0)
        #expect(zero.hasMetRequirement == false)
        #expect(zero.hoursRemaining == 25)

        let exact = ProgressCalculator.summarise(
            entries: [Self.entry(25, .approved)], grade: 9, requirements: requirements
        )
        #expect(exact.verifiedHours == 25)
        #expect(exact.percentComplete == 100)
        #expect(exact.progressFraction == 1)
        #expect(exact.hasMetRequirement)
        #expect(exact.hoursRemaining == 0)

        let over = ProgressCalculator.summarise(
            entries: [Self.entry(25, .approved), Self.entry(5, .approved)],
            grade: 9, requirements: requirements
        )
        #expect(over.verifiedHours == 30)
        #expect(over.percentComplete == 120, "over-threshold shows the real figure")
        #expect(over.progressFraction == 1, "the bar cannot show more than full")
        #expect(over.hoursRemaining == 0)
    }

    @Test("C11 identical hours give different percentages in grade 9 and grade 12")
    func gradeChangesThePercentage() throws {
        let requirements = try Self.loadRequirements()
        let entries = [Self.entry(50, .approved)]

        let freshman = ProgressCalculator.summarise(
            entries: entries, grade: 9, requirements: requirements
        )
        let senior = ProgressCalculator.summarise(
            entries: entries, grade: 12, requirements: requirements
        )

        #expect(freshman.verifiedHours == senior.verifiedHours)
        #expect(freshman.thresholdHours == 25)
        #expect(senior.thresholdHours == 100)
        #expect(freshman.percentComplete == 200)
        #expect(senior.percentComplete == 50)
        #expect(freshman.percentComplete != senior.percentComplete)
        #expect(freshman.hasMetRequirement)
        #expect(!senior.hasMetRequirement)
        #expect(freshman.submissionDeadline == "April 15")
        #expect(senior.submissionDeadline == "April 1")
    }

    @Test("C11 the per-category breakdown adds up to the verified total")
    func categoryBreakdownAddsUp() throws {
        let requirements = try Self.loadRequirements()
        let entries = [
            Self.entry(6, .approved, category: "community", organization: "Food Bank"),
            Self.entry(2.5, .approved, category: "community", organization: "Library"),
            Self.entry(4, .approved, category: "school-based", organization: "PSHS"),
            Self.entry(20, .submitted, category: "faith-based", organization: "Chapel"),
        ]
        let summary = ProgressCalculator.summarise(
            entries: entries, grade: 11, requirements: requirements
        )

        #expect(summary.byCategory == ["community": 8.5, "school-based": 4])
        #expect(summary.verifiedHours == 12.5)
        #expect(summary.byCategory.values.reduce(0, +) == summary.verifiedHours)
        // A submitted entry must not appear in the approved breakdown.
        #expect(summary.byCategory["faith-based"] == nil)
        #expect(summary.distinctOrganizations == 3)
    }

    @Test("Category cap usage reports nil where the handbook sets no cap")
    func capUsage() throws {
        let requirements = try Self.loadRequirements()
        let summary = ProgressCalculator.summarise(
            entries: [
                Self.entry(70, .approved, category: "school-based"),
                Self.entry(5, .approved, category: "community"),
            ],
            grade: 12, requirements: requirements
        )

        let schoolCap = try #require(
            ProgressCalculator.capUsage(
                categoryId: "school-based", summary: summary, requirements: requirements
            )
        )
        #expect(schoolCap.used == 70)
        #expect(schoolCap.cap == 60)

        #expect(
            ProgressCalculator.capUsage(
                categoryId: "community", summary: summary, requirements: requirements
            ) == nil
        )
    }

    @Test("Entry status rules match the server's")
    func statusRules() {
        for status in [EntryStatus.draft, .rejected, .revisionRequested] {
            #expect(status.isStudentEditable, "\(status) should be editable")
            #expect(!status.countsAsVerified)
        }
        #expect(!EntryStatus.submitted.isStudentEditable)
        #expect(!EntryStatus.approved.isStudentEditable)
        #expect(EntryStatus.approved.isPermanent)
        #expect(EntryStatus.approved.countsAsVerified)
        #expect(EntryStatus.submitted.countsAsPending)
        #expect(!EntryStatus.approved.countsAsPending)
        for status in EntryStatus.allCases {
            #expect(!status.studentExplanation.isEmpty)
        }
    }
}
