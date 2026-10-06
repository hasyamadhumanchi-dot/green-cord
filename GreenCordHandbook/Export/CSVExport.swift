import Foundation

/// CSV a counselor or a sponsor can open in Excel or Sheets.
///
/// Only approved hours are exported. A student's pending hours are not a record
/// of anything yet, and putting them in the same file as verified ones is
/// exactly the confusion the approval workflow exists to prevent.
enum CSVExport {
    static let studentHeader = [
        "Date", "Hours", "Category", "Organization", "Description",
        "Supervisor", "Supervisor contact", "Status",
    ]

    static let rosterHeader = [
        "Last name", "Student", "Grade", "Verified hours", "Pending hours",
        "Required hours", "Percent complete",
    ]

    static func studentExport(
        entries: [HourEntry],
        requirements: Requirements,
        account: Account
    ) -> String {
        let approved = entries
            .filter { $0.status.countsAsVerified }
            .sorted { $0.serviceDate < $1.serviceDate }

        var rows = [studentHeader]
        for entry in approved {
            let categoryName = requirements.category(id: entry.category)?.name ?? entry.category
            rows.append([
                entry.serviceDate,
                Formatting.hours(entry.hours),
                categoryName,
                entry.organization,
                entry.description,
                entry.verifierName,
                entry.verifierContact,
                entry.status.displayName,
            ])
        }

        let total = approved.reduce(0) { $0 + $1.hours }
        rows.append([])
        rows.append(["Total verified hours", Formatting.hours(total)])
        if let grade = account.grade,
           let requirement = requirements.requirement(forGrade: grade) {
            rows.append([
                "Requirement (\(requirement.label))",
                Formatting.hours(requirement.thresholdHours.value),
            ])
            rows.append(["Submission deadline", requirement.submissionDeadline.value])
        }
        rows.append(["Student", account.displayName])
        rows.append(["Exported", DateFormatting.isoDay.string(from: Date())])

        return render(rows)
    }

    static func rosterExport(rows students: [RosterRow]) -> String {
        var rows = [rosterHeader]
        for student in students {
            rows.append([
                student.lastName,
                student.displayName,
                String(student.grade),
                Formatting.hours(student.verifiedHours),
                Formatting.hours(student.pendingHours),
                Formatting.hours(student.thresholdHours),
                String(student.percentComplete),
            ])
        }
        return render(rows)
    }

    static func render(_ rows: [[String]]) -> String {
        rows.map { row in row.map(escape).joined(separator: ",") }
            .joined(separator: "\n") + "\n"
    }

    /// RFC 4180 quoting. A description containing a comma, a quote or a newline
    /// has to survive the trip into a spreadsheet intact.
    static func escape(_ field: String) -> String {
        let needsQuoting = field.contains(",")
            || field.contains("\"")
            || field.contains("\n")
            || field.contains("\r")
        guard needsQuoting else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Write to a temporary file so the share sheet can hand over a real
    /// document rather than a blob of text.
    static func writeTemporaryFile(named name: String, contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
