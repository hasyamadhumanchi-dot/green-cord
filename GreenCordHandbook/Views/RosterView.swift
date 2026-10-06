import SwiftUI

/// Every student's standing, for the counselor only.
///
/// On iPad this is a real table with sortable columns, because a counselor
/// scanning 200 students needs columns, not stacked cards. On iPhone the same
/// rows render as a list.
struct RosterView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var gradeFilter: Int?
    @State private var letterFrom = ""
    @State private var letterTo = ""
    @State private var sortOrder = [KeyPathComparator(\RosterRow.lastName)]
    @State private var showingExport = false
    @State private var showingCodes = false

    private var rows: [RosterRow] {
        model.roster.sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            if model.role?.isStaff != true {
                SignedOutNotice(message: "Sign in with the counselor account to see the roster.")
            } else {
                VStack(spacing: 0) {
                    filterBar
                    Divider()
                    if sizeClass == .regular {
                        table
                    } else {
                        compactList
                    }
                }
            }
        }
        .navigationTitle("Students")
        .toolbar {
            if model.role?.isStaff == true {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingExport = true
                    } label: {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Export the roster as a CSV file")
                    .accessibilityIdentifier("exportRoster")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingCodes = true
                    } label: {
                        Label("Invite codes", systemImage: "ticket")
                    }
                    .accessibilityLabel("Manage invite codes")
                    .accessibilityIdentifier("manageCodes")
                }
            }
        }
        .sheet(isPresented: $showingExport) {
            ExportSheet(
                filename: "green-cord-roster.csv",
                contents: model.rosterCSV(),
                title: "Roster"
            )
        }
        .sheet(isPresented: $showingCodes) {
            InviteCodesView()
        }
        .task { await applyFilters() }
        .refreshable { await applyFilters() }
    }

    // MARK: - Filters

    private var filterBar: some View {
        VStack(spacing: 10) {
            Picker("Grade", selection: $gradeFilter) {
                Text("All grades").tag(Int?.none)
                ForEach([9, 10, 11, 12], id: \.self) { grade in
                    Text("Grade \(grade)").tag(Int?.some(grade))
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Filter by grade")
            .accessibilityIdentifier("gradeFilter")

            HStack(spacing: 10) {
                Text("Last name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("A", text: $letterFrom)
                    .frame(width: 44)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .accessibilityLabel("Last name range starts at")
                    .accessibilityIdentifier("letterFrom")
                Text("to")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Z", text: $letterTo)
                    .frame(width: 44)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .accessibilityLabel("Last name range ends at")
                    .accessibilityIdentifier("letterTo")

                Spacer()

                Text("\(rows.count) student\(rows.count == 1 ? "" : "s")")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .accessibilityIdentifier("rosterCount")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Brand.cardBackground)
        .onChange(of: gradeFilter) { _, _ in Task { await applyFilters() } }
        .onChange(of: letterFrom) { _, _ in Task { await applyFilters() } }
        .onChange(of: letterTo) { _, _ in Task { await applyFilters() } }
    }

    private func applyFilters() async {
        await model.loadRoster(
            grade: gradeFilter,
            letterFrom: letterFrom.isEmpty ? nil : String(letterFrom.prefix(1)),
            letterTo: letterTo.isEmpty ? nil : String(letterTo.prefix(1))
        )
    }

    // MARK: - iPad table

    private var table: some View {
        Table(rows, sortOrder: $sortOrder) {
            TableColumn("Last name", value: \.lastName) { row in
                Text(row.lastName).accessibilityLabel("Last name \(row.lastName)")
            }
            TableColumn("Student", value: \.displayName) { row in
                HStack(spacing: 6) {
                    Text(row.displayName)
                    if !row.hasJoined {
                        Text("Not joined")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Brand.cardBackground, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel(
                    row.hasJoined
                        ? row.displayName
                        : "\(row.displayName), has not signed up yet"
                )
            }
            TableColumn("Grade", value: \.grade) { row in
                Text(String(row.grade)).monospacedDigit()
            }
            TableColumn("Approved", value: \.verifiedHours) { row in
                Text(Formatting.hours(row.verifiedHours))
                    .monospacedDigit()
                    .accessibilityLabel("\(Formatting.hours(row.verifiedHours)) approved hours")
            }
            TableColumn("Pending", value: \.pendingHours) { row in
                Text(Formatting.hours(row.pendingHours))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(Formatting.hours(row.pendingHours)) hours awaiting review")
            }
            TableColumn("Required", value: \.thresholdHours) { row in
                Text(Formatting.hours(row.thresholdHours)).monospacedDigit()
            }
            TableColumn("Complete", value: \.percentComplete) { row in
                HStack(spacing: 8) {
                    ProgressBar(
                        fraction: min(1, row.percentComplete / 100),
                        met: row.percentComplete >= 100
                    )
                    .frame(width: 60, height: 6)
                    Text(Formatting.percent(row.percentComplete))
                        .monospacedDigit()
                        .font(.caption)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Formatting.percent(row.percentComplete)) complete")
            }
            TableColumn("Last activity") { row in
                Text(row.lastActivityText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("rosterTable")
    }

    // MARK: - iPhone list

    private var compactList: some View {
        List(rows) { row in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(row.displayName)
                        .font(.body.weight(.medium))
                    if !row.hasJoined {
                        Text("Not joined")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Brand.cardBackground, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Grade \(row.grade)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Text("\(Formatting.hours(row.verifiedHours)) approved")
                        .font(.caption)
                        .monospacedDigit()
                    Text("\(Formatting.hours(row.pendingHours)) pending")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Text(Formatting.percent(row.percentComplete))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
                ProgressBar(
                    fraction: min(1, row.percentComplete / 100),
                    met: row.percentComplete >= 100
                )
                .frame(height: 5)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(row.displayName), grade \(row.grade). "
                + (row.hasJoined ? "" : "Has not signed up yet. ")
                + "\(Formatting.hours(row.verifiedHours)) approved hours of "
                + "\(Formatting.hours(row.thresholdHours)) required, "
                + "\(Formatting.percent(row.percentComplete)). "
                + "\(Formatting.hours(row.pendingHours)) hours awaiting review."
            )
            .accessibilityIdentifier("roster-\(row.studentId)")
        }
        .listStyle(.plain)
        .accessibilityIdentifier("rosterList")
    }
}

/// Add students to the program and manage their invite codes.
///
/// A code is always issued to a named student, so this screen doubles as the
/// counselor's own list: who has been added, who has signed up, and who is
/// still holding a slip of paper.
struct InviteCodesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var grade = 9
    @State private var justIssued: [InviteCode] = []
    @State private var showingBulkAdd = false
    @State private var showingIssuedExport = false

    private var canAddOne: Bool {
        !firstName.trimmingCharacters(in: .whitespaces).isEmpty
            && !lastName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                addOneSection
                if !justIssued.isEmpty { justIssuedSection }
                outstandingSection
                joinedSection
            }
            .navigationTitle("Students & codes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityLabel("Close students and codes")
                }
            }
            .sheet(isPresented: $showingBulkAdd) {
                BulkAddStudentsView { issued in
                    justIssued = issued + justIssued
                }
            }
            .sheet(isPresented: $showingIssuedExport) {
                ExportSheet(
                    filename: "green-cord-invite-codes.csv",
                    contents: CodeSheet.csv(justIssued),
                    title: "Codes to hand out"
                )
            }
        }
    }

    // MARK: - Add one

    // Two sections now: the fields, then the buttons.
    @ViewBuilder
    private var addOneSection: some View {
        Section {
            TextField("First name", text: $firstName)
                .accessibilityLabel("Student's first name")
                .accessibilityIdentifier("newStudentFirstName")
            TextField("Last name", text: $lastName)
                .accessibilityLabel("Student's last name")
                .accessibilityIdentifier("newStudentLastName")
            Picker("Grade", selection: $grade) {
                ForEach([9, 10, 11, 12], id: \.self) { Text("Grade \($0)").tag($0) }
            }
            .accessibilityLabel("Student's grade")
            .accessibilityIdentifier("newStudentGrade")

        } header: {
            Text("Add a student")
        } footer: {
            Text(
                "Each student gets their own code. The code carries their name, so when "
                + "they sign up the app knows who they are and they cannot enrol as "
                + "someone else."
            )
        }

        // In their own section with a real button shape. Sitting in the same
        // section as the text fields, a disabled plain button read as a third
        // empty field.
        Section {
            Button {
                Task { await addOne() }
            } label: {
                Label("Add student and issue a code", systemImage: "plus")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canAddOne)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
            .accessibilityLabel("Add this student and issue their invite code")
            .accessibilityIdentifier("addStudent")

            Button {
                showingBulkAdd = true
            } label: {
                Label("Add a whole list instead", systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
            .accessibilityLabel("Add several students at once by pasting a list")
            .accessibilityIdentifier("bulkAdd")
        }
    }

    private func addOne() async {
        let student = NewStudent(
            firstName: firstName.trimmingCharacters(in: .whitespaces),
            lastName: lastName.trimmingCharacters(in: .whitespaces),
            grade: grade
        )
        let issued = await model.addStudents([student])
        guard !issued.isEmpty else { return }
        justIssued = issued + justIssued
        firstName = ""
        lastName = ""
    }

    // MARK: - Just issued

    private var justIssuedSection: some View {
        Section {
            ForEach(justIssued) { code in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(code.fullName)
                            .font(.body.weight(.medium))
                        Text("Grade \(code.grade)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(code.code)
                        .font(.body.monospaced().weight(.semibold))
                        .foregroundStyle(Brand.maroon)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(code.fullName), grade \(code.grade), code \(code.code.map(String.init).joined(separator: " "))"
                )
                .accessibilityIdentifier("issued-\(code.code)")
            }

            Button {
                showingIssuedExport = true
            } label: {
                Label("Export this list to hand out", systemImage: "square.and.arrow.up")
            }
            .accessibilityLabel("Export the names and codes as a CSV file")
            .accessibilityIdentifier("exportIssuedCodes")
        } header: {
            Text("Just issued - \(justIssued.count) code\(justIssued.count == 1 ? "" : "s")")
        } footer: {
            Text("Give each student their own code. Read it out or print the list.")
        }
    }

    // MARK: - Outstanding and joined

    private var outstandingSection: some View {
        Section {
            let outstanding = model.inviteCodes
                .filter { $0.state == .outstanding }
                .sorted { $0.lastName.lowercased() < $1.lastName.lowercased() }
            if outstanding.isEmpty {
                Text("Everyone who has been added has signed up.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("noOutstandingCodes")
            }
            ForEach(outstanding) { code in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(code.fullName)
                            .font(.body.weight(.medium))
                        Text("Grade \(code.grade) \u{00B7} \(code.code)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revoke", role: .destructive) {
                        Task { await model.revokeCode(code.code) }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .accessibilityLabel("Revoke \(code.fullName)'s code")
                    .accessibilityIdentifier("revoke-\(code.code)")
                }
                .accessibilityIdentifier("code-\(code.code)")
            }
        } header: {
            Text("Not signed up yet")
        } footer: {
            Text("Revoking cancels that student's code. Add them again to issue a new one.")
        }
    }

    private var joinedSection: some View {
        Section("Signed up") {
            let redeemed = model.inviteCodes
                .filter { $0.state == .redeemed }
                .sorted { $0.lastName.lowercased() < $1.lastName.lowercased() }
            Text("\(redeemed.count) of \(model.inviteCodes.count) students have signed up")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("redeemedCount")
            ForEach(redeemed) { code in
                HStack {
                    Text(code.fullName)
                    Spacer()
                    Text("Grade \(code.grade)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(code.fullName), grade \(code.grade), signed up")
            }
        }
    }
}

/// Paste a class list rather than typing eighty students one at a time.
struct BulkAddStudentsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let onIssued: ([InviteCode]) -> Void

    @State private var text = ""
    @State private var working = false
    @State private var errorMessage: String?

    private var parsed: StudentListParser.Result {
        StudentListParser.parse(text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 180)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .accessibilityLabel("Paste your student list here")
                        .accessibilityIdentifier("bulkAddText")
                } header: {
                    Text("One student per line")
                } footer: {
                    Text(
                        "First Last, grade - for example \"Jordan Martinez, 11\". "
                        + "Tabs work too, so a column pasted from a spreadsheet is fine."
                    )
                }

                if !parsed.students.isEmpty {
                    Section("Ready to add - \(parsed.students.count)") {
                        ForEach(parsed.students) { student in
                            HStack {
                                Text("\(student.firstName) \(student.lastName)")
                                Spacer()
                                Text("Grade \(student.grade)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                if !parsed.problems.isEmpty {
                    Section("Lines that could not be read") {
                        ForEach(parsed.problems, id: \.self) { problem in
                            Text(problem)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                if let errorMessage {
                    AuthErrorRow(message: errorMessage)
                }
            }
            .navigationTitle("Add a list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Issue codes") {
                        Task { await issue() }
                    }
                    .disabled(working || parsed.students.isEmpty)
                    .accessibilityLabel("Issue a code for each student in the list")
                    .accessibilityIdentifier("issueBulkCodes")
                }
            }
        }
    }

    private func issue() async {
        working = true
        errorMessage = nil
        let issued = await model.addStudents(parsed.students)
        working = false
        if issued.isEmpty {
            errorMessage = model.lastError ?? "Those students could not be added."
            return
        }
        onIssued(issued)
        dismiss()
    }
}

/// Turns a pasted class list into students.
///
/// Forgiving on purpose: a counselor pasting from a spreadsheet should not have
/// to reformat anything, and a line that cannot be read is reported rather than
/// dropped in silence.
enum StudentListParser {
    struct Result {
        var students: [NewStudent]
        var problems: [String]
    }

    static func parse(_ text: String) -> Result {
        var students: [NewStudent] = []
        var problems: [String] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            let fields = line
                .split(whereSeparator: { $0 == "," || $0 == "\t" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            guard let grade = grade(from: fields.last ?? ""), fields.count >= 2 else {
                problems.append(line)
                continue
            }

            let nameFields = Array(fields.dropLast())
            let first: String
            let last: String
            if nameFields.count >= 2 {
                // "First, Last, 11" or a spreadsheet's two name columns.
                first = nameFields[0]
                last = nameFields[1]
            } else if let whole = nameFields.first, whole.contains(" ") {
                // "Jordan Martinez, 11" - everything before the last word is the
                // first name, so double-barrelled first names survive.
                var parts = whole.split(separator: " ").map(String.init)
                last = parts.removeLast()
                first = parts.joined(separator: " ")
            } else {
                problems.append(line)
                continue
            }

            let student = NewStudent(firstName: first, lastName: last, grade: grade)
            guard student.isComplete else {
                problems.append(line)
                continue
            }
            students.append(student)
        }

        return Result(students: students, problems: problems)
    }

    private static func grade(from field: String) -> Int? {
        let digits = field.filter(\.isNumber)
        guard let value = Int(digits), (9...12).contains(value) else { return nil }
        return value
    }
}

/// The name-and-code list the counselor hands out.
enum CodeSheet {
    static func csv(_ codes: [InviteCode]) -> String {
        var lines = ["First name,Last name,Grade,Invite code"]
        for code in codes {
            lines.append(
                [code.firstName, code.lastName, String(code.grade), code.code]
                    .map(CSVExport.escape)
                    .joined(separator: ",")
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

#if DEBUG
#Preview("Roster") {
    PreviewShell { RosterView() }
}

#Preview("Students and codes") {
    InviteCodesView().environment(PreviewData.model)
}

#Preview("Bulk add") {
    BulkAddStudentsView { _ in }.environment(PreviewData.model)
}
#endif
