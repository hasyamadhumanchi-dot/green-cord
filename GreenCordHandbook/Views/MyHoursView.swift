import SwiftUI

/// A student's own entries. Nothing about anybody else appears here.
struct MyHoursView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: EditorTarget?
    @State private var showingExport = false

    private enum EditorTarget: Identifiable {
        case new
        case existing(HourEntry)

        var id: String {
            switch self {
            case .new: return "new"
            case let .existing(entry): return entry.id
            }
        }
    }

    var body: some View {
        Group {
            if !model.isSignedIn {
                SignedOutNotice(
                    message: "Sign in with the invite code from your counselor to log service hours."
                )
            } else if model.entries.isEmpty {
                ContentUnavailableView {
                    Label("No hours logged yet", systemImage: "list.bullet.clipboard")
                } description: {
                    Text("Add your first entry once you have a signed verification form.")
                } actions: {
                    Button("Log hours") { editing = .new }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Log service hours")
                }
            } else {
                entryList
            }
        }
        .navigationTitle("My Hours")
        .toolbar {
            if model.isSignedIn {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editing = .new
                    } label: {
                        Label("Log hours", systemImage: "plus")
                    }
                    .accessibilityLabel("Log service hours")
                    .accessibilityIdentifier("addEntry")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingExport = true
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Export my approved hours")
                    .accessibilityIdentifier("exportHours")
                }
            }
        }
        .sheet(item: $editing) { target in
            switch target {
            case .new:
                EntryEditorView(entry: nil)
            case let .existing(entry):
                EntryEditorView(entry: entry)
            }
        }
        .sheet(isPresented: $showingExport) {
            ExportSheet(
                filename: "green-cord-hours.csv",
                contents: model.studentCSV(),
                title: "Approved hours"
            )
        }
        .refreshable { await model.refresh() }
    }

    private var entryList: some View {
        List {
            if model.queuedCount > 0 {
                Section {
                    Label(
                        "\(model.queuedCount) entr\(model.queuedCount == 1 ? "y" : "ies") saved on this device, waiting to reach your counselor.",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("queuedNotice")
                }
            }

            ForEach(groupedEntries, id: \.status) { group in
                Section(group.status.displayName) {
                    ForEach(group.entries) { entry in
                        EntryRow(entry: entry) {
                            if entry.status.isStudentEditable {
                                editing = .existing(entry)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("entryList")
    }

    private var groupedEntries: [(status: EntryStatus, entries: [HourEntry])] {
        let order: [EntryStatus] = [.revisionRequested, .rejected, .draft, .submitted, .approved]
        return order.compactMap { status in
            let matching = model.entries
                .filter { $0.status == status }
                .sorted { $0.serviceDate > $1.serviceDate }
            return matching.isEmpty ? nil : (status, matching)
        }
    }
}

struct EntryRow: View {
    let entry: HourEntry
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(entry.organization)
                        .font(.body.weight(.medium))
                    Spacer()
                    Text("\(Formatting.hours(entry.hours)) h")
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                }
                Text(entry.displayDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let decision = entry.decidedBy {
                    Text(decision.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    StatusBadge(status: entry.status)
                    if entry.counselorEntered {
                        Label("Entered by your counselor", systemImage: "person.badge.shield.checkmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if entry.pendingSync {
                        Label("Not synced", systemImage: "icloud.slash")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!entry.status.isStudentEditable)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(entry.organization), \(Formatting.hours(entry.hours)) hours on "
            + "\(entry.displayDate). \(entry.status.displayName)."
        )
        .accessibilityHint(
            entry.status.isStudentEditable
                ? "Opens this entry for editing."
                : entry.status.studentExplanation
        )
        .accessibilityIdentifier("entry-\(entry.id)")
    }
}

struct SignedOutNotice: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Not signed in", systemImage: "person.crop.circle.badge.questionmark")
        } description: {
            Text(message)
        }
        .accessibilityIdentifier("signedOutNotice")
    }
}

#if DEBUG
#Preview("My Hours") {
    PreviewShell { MyHoursView() }
}

#Preview("One row") {
    List {
        EntryRow(entry: PreviewData.sampleEntry) {}
    }
}
#endif
