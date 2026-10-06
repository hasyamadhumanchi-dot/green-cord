import PhotosUI
import SwiftUI

/// Create or change one entry.
///
/// An approved entry never opens here: the row that would present it is
/// disabled, and if one somehow arrived the form shows itself read-only. The
/// server refuses the write regardless, which is the guarantee that matters.
struct EntryEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let entry: HourEntry?

    @State private var draft = EntryDraft.empty
    @State private var serviceDate = Date()
    @State private var hoursText = ""
    @State private var evidenceItem: PhotosPickerItem?
    @State private var evidenceAttached = false
    @State private var showingDeleteConfirmation = false
    @State private var errorMessage: String?

    private var isEditing: Bool { entry != nil }
    private var isLocked: Bool { entry?.status.isStudentEditable == false }

    var body: some View {
        NavigationStack {
            Form {
                if isLocked, let entry {
                    Section {
                        Label(entry.status.studentExplanation, systemImage: "lock.fill")
                            .font(.footnote)
                            .accessibilityIdentifier("lockedNotice")
                    }
                }

                Section("What you did") {
                    DatePicker(
                        "Date of service",
                        selection: $serviceDate,
                        displayedComponents: .date
                    )
                    .accessibilityLabel("Date of service")
                    .accessibilityIdentifier("dateField")

                    LabeledContent("Hours") {
                        TextField("0", text: $hoursText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Hours served")
                            .accessibilityIdentifier("hoursField")
                    }

                    Picker("Category", selection: $draft.category) {
                        ForEach(model.requirements.categories) { category in
                            Text(category.name).tag(category.id)
                        }
                    }
                    .accessibilityLabel("Activity category")
                    .accessibilityIdentifier("categoryField")

                    TextField("Organization", text: $draft.organization)
                        .accessibilityLabel("Organization name")
                        .accessibilityIdentifier("organizationField")

                    TextField(
                        "What you did", text: $draft.description, axis: .vertical
                    )
                    .lineLimit(3...6)
                    .accessibilityLabel("Description of service")
                    .accessibilityIdentifier("descriptionField")
                }

                Section {
                    TextField("Supervisor name", text: $draft.verifierName)
                        .accessibilityLabel("Supervisor name")
                        .accessibilityIdentifier("verifierNameField")
                    TextField("Supervisor email or phone", text: $draft.verifierContact)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .accessibilityLabel("Supervisor email or phone number")
                        .accessibilityIdentifier("verifierContactField")
                } header: {
                    Text("Who can verify it")
                } footer: {
                    Text(
                        "The handbook requires a supervisor's name, email, phone and signature, "
                        + "and says a parent may not verify their own student's hours (page 16)."
                    )
                }

                Section {
                    PhotosPicker(selection: $evidenceItem, matching: .images) {
                        Label(
                            evidenceAttached ? "Photo attached" : "Attach a photo of the signed form",
                            systemImage: evidenceAttached ? "checkmark.circle.fill" : "camera"
                        )
                    }
                    .accessibilityLabel(
                        evidenceAttached
                            ? "Photo of the signed verification form is attached"
                            : "Attach a photo of the signed verification form"
                    )
                    .accessibilityIdentifier("evidencePicker")
                } header: {
                    Text("Evidence (optional)")
                } footer: {
                    Text("A photo of the signed verification form helps your counselor approve faster.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                            .accessibilityIdentifier("editorError")
                    }
                }

                if isEditing, !isLocked {
                    Section {
                        Button("Delete this entry", role: .destructive) {
                            showingDeleteConfirmation = true
                        }
                        .accessibilityLabel("Delete this entry")
                        .accessibilityIdentifier("deleteEntry")
                    }
                }
            }
            .disabled(isLocked)
            .navigationTitle(isEditing ? "Edit entry" : "Log hours")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityLabel("Cancel without saving")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save(submit: false) } }
                        .disabled(isLocked || !isValid)
                        .accessibilityLabel("Save this entry as a draft")
                        .accessibilityIdentifier("saveEntry")
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        Task { await save(submit: true) }
                    } label: {
                        Label("Send for review", systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLocked || !isValid)
                    .accessibilityLabel("Send these hours to your counselor for review")
                    .accessibilityIdentifier("submitEntry")
                }
            }
            .confirmationDialog(
                "Delete this entry?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task {
                        if let entry { _ = await model.deleteEntry(id: entry.id) }
                        dismiss()
                    }
                }
                Button("Keep it", role: .cancel) {}
            }
            .onAppear(perform: load)
            .onChange(of: evidenceItem) { _, item in
                evidenceAttached = item != nil
                // The prototype records that evidence exists. Uploading the image
                // itself needs object storage on the server, which is listed in
                // RELEASE.md as part of the post-approval build.
                draft.evidenceURL = item == nil ? nil : "attached://photo"
            }
        }
    }

    private var isValid: Bool {
        var candidate = draft
        candidate.hours = Double(hoursText) ?? 0
        return candidate.isComplete
    }

    private func load() {
        guard let entry else { return }
        draft = EntryDraft(
            serviceDate: entry.serviceDate,
            hours: entry.hours,
            category: entry.category,
            organization: entry.organization,
            description: entry.description,
            verifierName: entry.verifierName,
            verifierContact: entry.verifierContact,
            evidenceURL: entry.evidenceURL
        )
        serviceDate = entry.date ?? Date()
        hoursText = Formatting.hours(entry.hours)
        evidenceAttached = entry.evidenceURL != nil
    }

    private func save(submit: Bool) async {
        guard let hours = Double(hoursText), hours > 0 else {
            errorMessage = "Enter how many hours you served, for example 2.5."
            return
        }
        draft.hours = hours
        draft.serviceDate = DateFormatting.isoDay.string(from: serviceDate)

        if let entry {
            let ok = await model.updateEntry(id: entry.id, draft: draft)
            guard ok else {
                errorMessage = entry.status.studentExplanation
                return
            }
            if submit { _ = await model.submitEntry(id: entry.id) }
        } else {
            await model.createEntry(draft)
            if submit, let newest = model.entries.first(where: {
                $0.organization == draft.organization && $0.status == .draft
            }) {
                _ = await model.submitEntry(id: newest.id)
            }
        }
        dismiss()
    }
}

#if DEBUG
#Preview("Log hours") {
    EntryEditorView(entry: nil).environment(PreviewData.model)
}

#Preview("An approved entry, locked") {
    var approved = PreviewData.sampleEntry
    approved.status = .approved
    return EntryEditorView(entry: approved).environment(PreviewData.model)
}
#endif
