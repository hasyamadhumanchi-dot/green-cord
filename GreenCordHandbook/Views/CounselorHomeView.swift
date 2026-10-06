import SwiftUI

/// The counselor's landing screen: where the cohort stands, then a way into
/// each job. The queue is one tap away rather than in front of everything,
/// because the first question on opening the app is usually "how are we doing",
/// not "what is waiting for me".
struct CounselorHomeView: View {
    @Environment(AppModel.self) private var model

    @State private var showingCodes = false
    @State private var showingStaff = false
    @State private var showingExport = false

    private var toReview: Int { model.reviewQueue.count }
    private var students: Int { model.roster.count }
    private var complete: Int { model.roster.filter { $0.percentComplete >= 100 }.count }
    private var totalApprovedHours: Double {
        model.roster.reduce(0) { $0 + $1.verifiedHours }
    }
    private var notSignedUp: Int { model.roster.filter { !$0.hasJoined }.count }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statTiles

                VStack(spacing: 0) {
                    NavigationLink {
                        ReviewQueueView()
                    } label: {
                        DashboardRow(
                            title: "Review queue",
                            detail: toReview == 0
                                ? "Nothing waiting"
                                : "\(toReview) submission\(toReview == 1 ? "" : "s") to look at",
                            symbol: "tray.full",
                            badge: toReview == 0 ? nil : String(toReview)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        toReview == 0
                            ? "Review queue, nothing waiting"
                            : "Review queue, \(toReview) submission\(toReview == 1 ? "" : "s") to look at"
                    )
                    .accessibilityIdentifier("dashboardReviewQueue")

                    Divider().padding(.leading, 56)

                    NavigationLink {
                        RosterView()
                    } label: {
                        DashboardRow(
                            title: "Full roster",
                            detail: "\(students) student\(students == 1 ? "" : "s")"
                                + (notSignedUp > 0 ? ", \(notSignedUp) not signed up" : ""),
                            symbol: "person.3"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Full roster, \(students) student\(students == 1 ? "" : "s")")
                    .accessibilityIdentifier("dashboardRoster")

                    Divider().padding(.leading, 56)

                    Button {
                        showingCodes = true
                    } label: {
                        DashboardRow(
                            title: "Students & invite codes",
                            detail: "Add a student or hand out a code",
                            symbol: "ticket"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Students and invite codes. Add a student or hand out a code")
                    .accessibilityIdentifier("dashboardCodes")

                    Divider().padding(.leading, 56)

                    Button {
                        showingStaff = true
                    } label: {
                        DashboardRow(
                            title: "Staff & access",
                            detail: model.canManageStaff
                                ? "Add someone to help review, or hand the program over"
                                : "See who else can review hours",
                            symbol: "person.2.badge.key"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        model.canManageStaff
                            ? "Staff and access. Add someone to help review, or hand the program over"
                            : "Staff and access. See who else can review hours"
                    )
                    .accessibilityIdentifier("dashboardStaff")

                    Divider().padding(.leading, 56)

                    Button {
                        showingExport = true
                    } label: {
                        DashboardRow(
                            title: "Export for the district",
                            detail: "Every student's hours as a CSV",
                            symbol: "square.and.arrow.up"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Export for the district. Every student's hours as a CSV file")
                    .accessibilityIdentifier("dashboardExport")
                }
                .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 14))

                if model.isOffline {
                    Label(
                        "Offline. These figures are the last ones the app saw.",
                        systemImage: "wifi.slash"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("offlineNotice")
                }
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(16)
        }
        .background(Brand.pageBackground)
        .navigationTitle("Green Cord")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showingCodes) { InviteCodesView() }
        .sheet(isPresented: $showingStaff) { StaffView() }
        .sheet(isPresented: $showingExport) {
            ExportSheet(
                filename: "green-cord-roster.csv",
                contents: model.rosterCSV(),
                title: "Roster"
            )
        }
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
        .accessibilityIdentifier("counselorHome")
    }

    private var statTiles: some View {
        // Two columns on a phone, four across on an iPad, without a second
        // layout to keep in step.
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
            spacing: 12
        ) {
            StatTile(
                value: String(toReview),
                label: "to review",
                emphasised: toReview > 0,
                identifier: "statToReview"
            )
            StatTile(value: String(students), label: "students", identifier: "statStudents")
            StatTile(value: String(complete), label: "complete", identifier: "statComplete")
            StatTile(
                value: Formatting.hours(totalApprovedHours),
                label: "hours total",
                identifier: "statHours"
            )
        }
    }
}

/// One figure and what it counts.
struct StatTile: View {
    let value: String
    let label: String
    var emphasised = false
    var identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.largeTitle.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(emphasised ? Brand.maroon : .primary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
        .accessibilityIdentifier(identifier)
    }
}

/// A row on the dashboard that leads somewhere.
struct DashboardRow: View {
    let title: String
    let detail: String
    let symbol: String
    var badge: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Brand.maroon)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.leading)

            Spacer()

            if let badge {
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Brand.maroon, in: Capsule())
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        // The control around this row carries the name; combining here too
        // would make VoiceOver read the row twice.
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Counselor home") {
    PreviewShell { CounselorHomeView() }
}
#endif
