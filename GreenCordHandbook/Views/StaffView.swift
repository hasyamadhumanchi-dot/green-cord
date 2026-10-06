import SwiftUI

/// Who can review hours, and who can change that.
///
/// Visible to any staff member — a manager should be able to see who else can
/// approve — but every control that changes something is admin-only, and the
/// server enforces that independently of what this screen shows.
struct StaffView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var newRole: Account.Role = .manager
    @State private var justInvited: [PendingStaffInvite] = []
    @State private var resetJustIssued: PasswordReset?
    @State private var confirmingRemoval: StaffMember?
    @State private var errorMessage: String?
    @State private var working = false

    private var list: StaffList? { model.staffList }
    private var canManage: Bool { model.canManageStaff }

    private var canInvite: Bool {
        !firstName.trimmingCharacters(in: .whitespaces).isEmpty
            && !lastName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if canManage { inviteSection }
                if !justInvited.isEmpty { justInvitedSection }
                if let reset = resetJustIssued { resetSection(reset) }
                staffSection
                pendingSection
                if let errorMessage { AuthErrorRow(message: errorMessage) }
            }
            .navigationTitle("Staff & access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityLabel("Close staff and access")
                }
            }
            .task { await model.loadStaff() }
            .refreshable { await model.loadStaff() }
            .confirmationDialog(
                confirmingRemoval.map { "Remove \($0.displayName)?" } ?? "",
                isPresented: Binding(
                    get: { confirmingRemoval != nil },
                    set: { if !$0 { confirmingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove their access", role: .destructive) {
                    if let target = confirmingRemoval {
                        Task {
                            _ = await model.removeStaff(id: target.id)
                            errorMessage = model.lastError
                            confirmingRemoval = nil
                        }
                    }
                }
                .accessibilityIdentifier("confirmRemoveStaff")
                Button("Keep their access", role: .cancel) { confirmingRemoval = nil }
            } message: {
                Text(
                    "They will not be able to sign in. The hours they already approved "
                    + "stay approved, still recorded under their name."
                )
            }
        }
        .accessibilityIdentifier("staffView")
    }

    // MARK: - Inviting

    @ViewBuilder
    private var inviteSection: some View {
        Section {
            TextField("First name", text: $firstName)
                .accessibilityLabel("Their first name")
                .accessibilityIdentifier("staffFirstName")
            TextField("Last name", text: $lastName)
                .accessibilityLabel("Their last name")
                .accessibilityIdentifier("staffLastName")
            Picker("Access", selection: $newRole) {
                Text("Manager").tag(Account.Role.manager)
                Text("Admin").tag(Account.Role.admin)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("What they can do")
            .accessibilityIdentifier("staffRolePicker")

            Text(newRole.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Add someone")
        } footer: {
            Text(
                "They get a code, and set their own password when they use it. "
                + "You never see it."
            )
        }

        Section {
            Button {
                Task { await invite() }
            } label: {
                Label("Create their invite code", systemImage: "person.badge.plus")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canInvite || working)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
            .accessibilityLabel("Create an invite code for this person")
            .accessibilityIdentifier("inviteStaff")
        }
    }

    private func invite() async {
        working = true
        errorMessage = nil
        let invite = await model.inviteStaff(
            firstName: firstName.trimmingCharacters(in: .whitespaces),
            lastName: lastName.trimmingCharacters(in: .whitespaces),
            role: newRole
        )
        working = false
        guard let invite else {
            errorMessage = model.lastError ?? "That invite could not be created."
            return
        }
        justInvited.insert(invite, at: 0)
        firstName = ""
        lastName = ""
    }

    private var justInvitedSection: some View {
        Section {
            ForEach(justInvited) { invite in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(invite.fullName).font(.body.weight(.medium))
                        Text(invite.role.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(invite.code)
                        .font(.body.monospaced().weight(.semibold))
                        .foregroundStyle(Brand.maroon)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(invite.fullName), \(invite.role.title), code "
                    + invite.code.map(String.init).joined(separator: " ")
                )
            }
        } header: {
            Text("Give them this code")
        } footer: {
            Text("It works once and expires in 30 days.")
        }
    }

    // MARK: - Resets

    private func resetSection(_ reset: PasswordReset) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(reset.for).font(.body.weight(.medium))
                Text(reset.code)
                    .font(.title3.monospaced().weight(.semibold))
                    .foregroundStyle(Brand.maroon)
                    .textSelection(.enabled)
                Text("They enter this on the Log In screen under \u{201C}Forgot your password?\u{201D}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("resetCode")

            Button("Done with this code") { resetJustIssued = nil }
                .accessibilityLabel("Hide the reset code")
        } header: {
            Text("Password reset code")
        }
    }

    // MARK: - The people

    @ViewBuilder
    private var staffSection: some View {
        Section {
            if let list {
                if list.staff.isEmpty {
                    Text("Nobody yet.").foregroundStyle(.secondary)
                }
                ForEach(list.staff) { member in
                    staffRow(member, onlyAdmin: list.admins <= 1 && member.role == .admin)
                }
            } else {
                HStack {
                    SwiftUI.ProgressView()
                    Text("Loading\u{2026}").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Who can review hours")
        } footer: {
            if canManage {
                Text(
                    "There must always be at least one admin. To hand the program over, "
                    + "make the new person an admin first, then step yourself down or "
                    + "remove your own access."
                )
            } else {
                Text("Only an admin can change who has access.")
            }
        }
    }

    private func staffRow(_ member: StaffMember, onlyAdmin: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.displayName).font(.body.weight(.medium))
                    Text("\(member.role.title) \u{00B7} \(member.username)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if onlyAdmin {
                    Text("Only admin")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Brand.cardBackground, in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }

            if canManage {
                HStack(spacing: 14) {
                    if member.role == .manager {
                        Button("Make admin") {
                            Task {
                                await model.setStaffRole(id: member.id, role: .admin)
                                errorMessage = model.lastError
                            }
                        }
                        .accessibilityIdentifier("promote-\(member.id)")
                    } else {
                        Button("Make manager") {
                            Task {
                                await model.setStaffRole(id: member.id, role: .manager)
                                errorMessage = model.lastError
                            }
                        }
                        .disabled(onlyAdmin)
                        .accessibilityIdentifier("demote-\(member.id)")
                    }

                    Button("Reset password") {
                        Task {
                            errorMessage = nil
                            resetJustIssued = await model.issuePasswordReset(
                                accountId: member.id
                            )
                            if resetJustIssued == nil { errorMessage = model.lastError }
                        }
                    }
                    .accessibilityIdentifier("reset-\(member.id)")

                    Spacer()

                    Button("Remove", role: .destructive) {
                        confirmingRemoval = member
                    }
                    .disabled(onlyAdmin)
                    .accessibilityIdentifier("remove-\(member.id)")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("staff-\(member.id)")
    }

    @ViewBuilder
    private var pendingSection: some View {
        if let list, !list.pending.isEmpty {
            Section("Invited, not signed up yet") {
                ForEach(list.pending) { invite in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(invite.fullName)
                            Text("\(invite.role.title) \u{00B7} \(invite.code)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if invite.expired {
                            Text("Expired")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

#if DEBUG
#Preview("Staff") {
    StaffView().environment(PreviewData.model)
}
#endif
