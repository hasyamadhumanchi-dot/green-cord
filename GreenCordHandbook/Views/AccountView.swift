import SwiftUI
import UniformTypeIdentifiers

/// Sign in, sign out, and the account-deletion route App Store review requires.
struct AccountView: View {
    @Environment(AppModel.self) private var model
    @State private var showingDeleteConfirmation = false
    @State private var deleting = false

    var body: some View {
        // Signing out returns to the welcome screen, so this view never has to
        // render a signed-out state.
        signedIn
            .navigationTitle("Account")
    }

    private var signedIn: some View {
        List {
            Section {
                if let account = model.account {
                    LabeledContent("Name", value: account.displayName)
                    LabeledContent("Username", value: account.username)
                    if let grade = account.grade {
                        LabeledContent("Grade", value: String(grade))
                    }
                    LabeledContent(
                        "Role",
                        value: account.role.isStaff ? "Counselor" : "Student"
                    )
                }
            } header: {
                Text("Signed in")
            }

            Section("Handbook") {
                LabeledContent("Content version", value: model.content.contentVersion)
                LabeledContent(
                    "Source",
                    value: model.content.origin == .bundled
                        ? "Shipped with the app"
                        : "Downloaded from the school website"
                )
                if let message = model.contentUpdateMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Check for a new handbook") {
                    Task { await model.checkForContentUpdate() }
                }
                .accessibilityLabel("Check the school website for an updated handbook")
                .accessibilityIdentifier("checkForUpdate")
            }

            if model.isOffline {
                Section {
                    Label(
                        "Offline. The handbook and your saved hours still work; changes sync when you reconnect.",
                        systemImage: "wifi.slash"
                    )
                    .font(.footnote)
                    .accessibilityIdentifier("offlineNotice")
                }
            }

            Section {
                Button("Sign out") {
                    Task { await model.signOut() }
                }
                .accessibilityLabel("Sign out of this account")
                .accessibilityIdentifier("signOut")
            }

            Section {
                Button("Delete my account", role: .destructive) {
                    showingDeleteConfirmation = true
                }
                .disabled(deleting)
                .accessibilityLabel("Delete my account and personal information")
                .accessibilityIdentifier("deleteAccount")
            } footer: {
                Text(
                    "Deleting removes your name, username and the details you typed. "
                    + "The number of service hours you completed is kept as part of the "
                    + "program's record, with nothing that identifies you attached to it."
                )
            }
        }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete my account", role: .destructive) {
                deleting = true
                Task {
                    try? await model.deleteAccount()
                    deleting = false
                }
            }
            .accessibilityIdentifier("confirmDeleteAccount")
            Button("Keep my account", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }
}

/// Hands a generated CSV to the share sheet.
struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let filename: String
    let contents: String
    let title: String

    @State private var fileURL: URL?

    private var rowCount: Int {
        max(0, contents.split(separator: "\n").count - 1)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Label("\(rowCount) rows ready", systemImage: "tablecells")
                    .font(.headline)
                    .accessibilityIdentifier("exportRowCount")

                ScrollView {
                    Text(contents)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("Preview of the exported file")
                .accessibilityIdentifier("exportPreview")

                if let fileURL {
                    ShareLink(item: fileURL) {
                        Label("Share \(filename)", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Share the file \(filename)")
                    .accessibilityIdentifier("shareExport")
                }
            }
            .padding(16)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityLabel("Close the export")
                }
            }
            .task {
                fileURL = try? CSVExport.writeTemporaryFile(named: filename, contents: contents)
            }
        }
    }
}

#if DEBUG
#Preview("Account") {
    PreviewShell { AccountView() }
}

#Preview("Export sheet") {
    ExportSheet(
        filename: "green-cord-hours.csv",
        contents: "Date,Hours,Organization\n2026-09-13,6.5,Food Pantry\n",
        title: "Approved hours"
    )
}
#endif
