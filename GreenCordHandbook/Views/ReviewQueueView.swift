import SwiftUI

/// The counselor's queue of submitted hours.
struct ReviewQueueView: View {
    @Environment(AppModel.self) private var model
    @State private var reviewing: HourEntry?
    @State private var loggingFor: RosterRow?

    var body: some View {
        Group {
            if model.role?.isStaff != true {
                SignedOutNotice(message: "Sign in with the counselor account to review submitted hours.")
            } else if model.reviewQueue.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to review", systemImage: "checkmark.circle")
                } description: {
                    Text("Submitted hours appear here as students send them in.")
                }
            } else {
                List(model.reviewQueue) { entry in
                    Button {
                        reviewing = entry
                    } label: {
                        QueueRow(entry: entry, studentName: studentName(for: entry.studentId))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("queue-\(entry.id)")
                }
                .listStyle(.insetGrouped)
                .accessibilityIdentifier("reviewQueue")
            }
        }
        .navigationTitle("Review Queue")
        .toolbar {
            if model.role?.isStaff == true {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(model.roster) { row in
                            Button(row.displayName) { loggingFor = row }
                        }
                    } label: {
                        Label("Log hours for a student", systemImage: "square.and.pencil")
                    }
                    .accessibilityLabel("Log hours on a student's behalf")
                    .accessibilityIdentifier("logOnBehalf")
                }
            }
        }
        .sheet(item: $reviewing) { entry in
            ReviewDetailView(entry: entry, studentName: studentName(for: entry.studentId))
        }
        .sheet(item: $loggingFor) { row in
            CounselorEntryView(student: row)
        }
        .refreshable { await model.refresh() }
    }

    private func studentName(for id: String) -> String {
        model.roster.first { $0.studentId == id }?.displayName ?? "Student"
    }
}

struct QueueRow: View {
    let entry: HourEntry
    let studentName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(studentName)
                    .font(.body.weight(.semibold))
                Spacer()
                Text("\(Formatting.hours(entry.hours)) h")
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
            }
            Text(entry.organization)
                .font(.subheadline)
            Text(entry.displayDate)
                .font(.caption)
                .foregroundStyle(.secondary)
            if entry.evidenceURL != nil {
                Label("Photo attached", systemImage: "paperclip")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(studentName), \(Formatting.hours(entry.hours)) hours at \(entry.organization) "
            + "on \(entry.displayDate). Awaiting review."
        )
        .accessibilityHint("Opens the entry to approve, decline or ask for changes.")
    }
}

/// One entry, with everything needed to decide on it.
struct ReviewDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let entry: HourEntry
    let studentName: String

    @State private var note = ""
    @State private var working = false
    @State private var history: [AuditEvent] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Student") {
                    LabeledContent("Name", value: studentName)
                    LabeledContent("Hours", value: Formatting.hours(entry.hours))
                    LabeledContent("Date", value: entry.displayDate)
                    LabeledContent(
                        "Category",
                        value: model.requirements.category(id: entry.category)?.name ?? entry.category
                    )
                    LabeledContent("Organization", value: entry.organization)
                }

                Section("What they did") {
                    Text(entry.description)
                        .font(.body)
                }

                Section("Verification") {
                    LabeledContent("Supervisor", value: entry.verifierName)
                    LabeledContent("Contact", value: entry.verifierContact)
                    if entry.evidenceURL != nil {
                        Label("Photo of the signed form attached", systemImage: "paperclip")
                    } else {
                        Text("No photo attached")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Note to the student") {
                    TextField("Optional, shown to the student", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                        .accessibilityLabel("Note to the student")
                        .accessibilityIdentifier("reviewNote")
                }

                Section {
                    ForEach(ReviewAction.allCases, id: \.self) { action in
                        Button {
                            Task { await decide(action) }
                        } label: {
                            Label(action.displayName, systemImage: symbol(for: action))
                        }
                        .disabled(working)
                        .accessibilityLabel(action.accessibilityLabel)
                        .accessibilityIdentifier("decision-\(action.rawValue)")
                    }
                } footer: {
                    Text("Approved hours become permanent on the student's record and can no longer be edited by them.")
                }

                if !history.isEmpty {
                    Section("History") {
                        ForEach(history) { event in
                            HStack {
                                Text(event.summary)
                                    .font(.subheadline)
                                Spacer()
                                Text(DateFormatting.friendly.string(from: event.date))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .navigationTitle("Review hours")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityLabel("Close without deciding")
                }
            }
            .task { history = await model.history(for: entry.id) }
        }
    }

    private func symbol(for action: ReviewAction) -> String {
        switch action {
        case .approve: return "checkmark.seal"
        case .reject: return "xmark.circle"
        case .requestRevision: return "arrow.uturn.backward.circle"
        }
    }

    private func decide(_ action: ReviewAction) async {
        working = true
        let ok = await model.decide(entryId: entry.id, action: action, note: note)
        working = false
        if ok { dismiss() }
    }
}

/// A counselor logging hours a student handed in on paper. The entry is flagged
/// counselor-entered and goes straight into the queue as submitted.
struct CounselorEntryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let student: RosterRow

    @State private var draft = EntryDraft.empty
    @State private var serviceDate = Date()
    @State private var hoursText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Student", value: student.displayName)
                    LabeledContent("Grade", value: String(student.grade))
                } footer: {
                    Text("This entry will be marked as entered by you and recorded in the audit log.")
                }

                Section("Service") {
                    DatePicker("Date", selection: $serviceDate, displayedComponents: .date)
                        .accessibilityLabel("Date of service")
                    LabeledContent("Hours") {
                        TextField("0", text: $hoursText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Hours served")
                            .accessibilityIdentifier("counselorHoursField")
                    }
                    Picker("Category", selection: $draft.category) {
                        ForEach(model.requirements.categories) { category in
                            Text(category.name).tag(category.id)
                        }
                    }
                    .accessibilityLabel("Activity category")
                    TextField("Organization", text: $draft.organization)
                        .accessibilityLabel("Organization name")
                        .accessibilityIdentifier("counselorOrganizationField")
                    TextField("Description", text: $draft.description, axis: .vertical)
                        .lineLimit(2...5)
                        .accessibilityLabel("Description of service")
                }

                Section("From the paper form") {
                    TextField("Supervisor name", text: $draft.verifierName)
                        .accessibilityLabel("Supervisor name")
                    TextField("Supervisor contact", text: $draft.verifierContact)
                        .accessibilityLabel("Supervisor contact")
                }
            }
            .navigationTitle("Log hours")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityLabel("Cancel without saving")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task { await add() }
                    }
                    .disabled(Double(hoursText) ?? 0 <= 0)
                    .accessibilityLabel("Add these hours for \(student.displayName)")
                    .accessibilityIdentifier("counselorAddEntry")
                }
            }
        }
    }

    private func add() async {
        draft.hours = Double(hoursText) ?? 0
        draft.serviceDate = DateFormatting.isoDay.string(from: serviceDate)
        if await model.logOnBehalf(of: student.studentId, draft: draft) {
            dismiss()
        }
    }
}

#if DEBUG
#Preview("Review queue") {
    PreviewShell { ReviewQueueView() }
}

#Preview("One entry under review") {
    ReviewDetailView(entry: PreviewData.sampleEntry, studentName: "Alpha Alderwood")
        .environment(PreviewData.model)
}
#endif
