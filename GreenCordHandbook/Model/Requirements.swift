import Foundation

/// A value the handbook states, together with the page it is stated on, so the
/// app can always show a reader where a number came from.
struct Cited<Value: Codable & Hashable>: Codable, Hashable {
    var value: Value
    var page: Int?
    var quote: String?
    var note: String?

    var citation: String { page.map { "Handbook page \($0)" } ?? "Not stated in the handbook" }
}

/// Either a number the handbook states, or an explicit "the handbook does not say".
enum CitedLimit: Codable, Hashable {
    case hours(Double, page: Int?)
    case unspecified(page: Int?, note: String?)

    private enum CodingKeys: String, CodingKey { case value, page, note }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let page = try container.decodeIfPresent(Int.self, forKey: .page)
        let note = try container.decodeIfPresent(String.self, forKey: .note)
        if let number = try? container.decode(Double.self, forKey: .value) {
            self = .hours(number, page: page)
        } else {
            self = .unspecified(page: page, note: note)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .hours(value, page):
            try container.encode(value, forKey: .value)
            try container.encodeIfPresent(page, forKey: .page)
        case let .unspecified(page, note):
            try container.encode("unspecified", forKey: .value)
            try container.encodeIfPresent(page, forKey: .page)
            try container.encodeIfPresent(note, forKey: .note)
        }
    }

    var hours: Double? {
        if case let .hours(value, _) = self { return value }
        return nil
    }

    /// What to show a student. The handbook's silence is surfaced, never filled in.
    var displayText: String {
        switch self {
        case let .hours(value, _): return "Maximum \(Formatting.hours(value)) hours"
        case .unspecified: return "Not specified in the handbook"
        }
    }
}

struct GradeRequirement: Codable, Hashable, Identifiable {
    var grade: Int
    var label: String
    var thresholdHours: Cited<Double>
    var recognition: Cited<[String]>
    var submissionDeadline: Cited<String>

    var id: Int { grade }
}

struct ActivityCategory: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var maxHours: CitedLimit
    var examples: Cited<[String]>
    var excluded: Cited<[String]>?
}

struct ProgramLimits: Codable, Hashable {
    var singleOrganizationMaxHours: Cited<Double>
    var minimumDistinctOrganizationsSeniorYear: Cited<Int>
}

struct DistinctionLevel: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var minHours: Double
    var maxHours: Double?
    var page: Int
    var quote: String

    var rangeText: String {
        if let maxHours { return "\(Formatting.hours(minHours))-\(Formatting.hours(maxHours)) hours" }
        return "\(Formatting.hours(minHours))+ hours"
    }
}

struct ChecklistRequirement: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var appliesToGrades: [Int]
    var page: Int
}

struct VerificationRules: Codable, Hashable {
    var requiredFields: Cited<[String]>
    var districtRights: Cited<[String]>
    var falseInformationConsequences: Cited<[String]>
    var familyMayNotVerify: Cited<Bool>
}

struct ProgramFacts: Codable, Hashable {
    var annualReset: Cited<Bool>
    var earliestAccrualDate: Cited<String>
    var enrollmentDeadline: Cited<String>
    var membershipFeeUSD: Cited<Double>
    var fourYearTotalHours: Cited<Int>
}

struct UnspecifiedItem: Codable, Hashable, Identifiable {
    var field: String
    var reason: String
    var page: Int

    var id: String { field }
}

struct Requirements: Codable, Hashable {
    var schemaVersion: Int
    var contentVersion: String
    var program: ProgramFacts
    var grades: [GradeRequirement]
    var categories: [ActivityCategory]
    var limits: ProgramLimits
    var seniorDistinctionLevels: [DistinctionLevel]
    var verificationRules: VerificationRules
    var nonQualifyingActivities: Cited<[String]>
    var checklist: [ChecklistRequirement]
    var unspecified: [UnspecifiedItem]

    func requirement(forGrade grade: Int) -> GradeRequirement? {
        grades.first { $0.grade == grade }
    }

    func category(id: String) -> ActivityCategory? {
        categories.first { $0.id == id }
    }

    func checklist(forGrade grade: Int) -> [ChecklistRequirement] {
        checklist.filter { $0.appliesToGrades.contains(grade) }
    }

    /// The distinction a senior's verified total earns, if any.
    func distinction(forHours hours: Double) -> DistinctionLevel? {
        seniorDistinctionLevels
            .filter { hours >= $0.minHours && ($0.maxHours.map { hours <= $0 } ?? true) }
            .max(by: { $0.minHours < $1.minHours })
    }
}

enum Formatting {
    /// 5 not 5.0, but 4.5 stays 4.5.
    static func hours(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value)
    }

    static func percent(_ value: Double) -> String {
        value == value.rounded()
            ? "\(Int(value))%"
            : String(format: "%.1f%%", value)
    }
}
