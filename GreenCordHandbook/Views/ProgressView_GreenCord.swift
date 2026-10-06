import SwiftUI

/// A student's standing against their own grade's requirement.
///
/// Approved and pending hours are shown as two separate figures and are never
/// added together. The big number is what actually counts; pending sits beside
/// it, visibly different, so nobody mistakes submitted work for verified work.
struct ProgressView_GreenCord: View {
    @Environment(AppModel.self) private var model

    @State private var loggingHours = false

    var body: some View {
        Group {
            if !model.isSignedIn {
                SignedOutNotice(
                    message: "Sign in to see how your hours stand against your grade's requirement."
                )
            } else {
                content
            }
        }
        .navigationTitle("My Progress")
        .refreshable { await model.refresh() }
    }

    private var content: some View {
        let summary = model.progress
        let requirement = model.gradeRequirement

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                greeting
                headline(summary: summary, requirement: requirement)
                logHoursButton
                recentCard
                categoryBreakdown(summary: summary)
                organisationsCard(summary: summary)
                if model.account?.grade == 12 {
                    distinctionCard(summary: summary)
                }
                checklistCard
                deadlineCard(requirement: requirement)
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .background(Brand.pageBackground)
        .accessibilityIdentifier("progressView")
    }

    // MARK: - Landing

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Hi, \(firstName)")
                .font(.title2.weight(.semibold))
            if let grade = model.account?.grade {
                Text("Grade \(grade)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("greeting")
    }

    private var firstName: String {
        model.account?.displayName.split(separator: " ").first.map(String.init)
            ?? model.account?.displayName
            ?? "there"
    }

    private var logHoursButton: some View {
        Button {
            loggingHours = true
        } label: {
            Label("Log Hours", systemImage: "plus")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel("Log service hours")
        .accessibilityIdentifier("logHours")
        .sheet(isPresented: $loggingHours) {
            NavigationStack { EntryEditorView(entry: nil) }
        }
    }

    /// The last few entries, so the landing screen answers "did my hours go
    /// through" without a trip to another tab.
    @ViewBuilder
    private var recentCard: some View {
        let recent = Array(
            model.entries
                .sorted { $0.serviceDate > $1.serviceDate }
                .prefix(3)
        )
        if !recent.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recent")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(recent) { entry in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.organization.isEmpty ? "Service hours" : entry.organization)
                                    .font(.body)
                                    .lineLimit(1)
                                StatusBadge(status: entry.status)
                            }
                            Spacer()
                            Text(Formatting.hours(entry.hours))
                                .font(.body.weight(.medium))
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "\(entry.organization), \(Formatting.hours(entry.hours)) hours, "
                            + entry.status.displayName
                        )
                    }
                }
            }
            .accessibilityIdentifier("recentEntries")
        }
    }

    // MARK: - Headline

    private func headline(summary: ProgressSummary, requirement: GradeRequirement?) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                if let requirement {
                    Text("\(requirement.label) year")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(Formatting.hours(summary.verifiedHours))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(summary.hasMetRequirement ? Brand.cordGreen : Brand.maroon)
                    Text("of \(Formatting.hours(summary.thresholdHours)) approved hours")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                ProgressBar(fraction: summary.progressFraction, met: summary.hasMetRequirement)
                    .frame(height: 12)

                HStack(spacing: 12) {
                    Text(Formatting.percent(summary.percentComplete))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    if !summary.hasMetRequirement {
                        Text("\(Formatting.hours(summary.hoursRemaining)) to go")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Requirement met", systemImage: "checkmark.seal.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Brand.cordGreen)
                    }
                }

                Divider()

                // Pending is deliberately a separate, quieter figure.
                HStack(alignment: .top, spacing: 20) {
                    figure(
                        value: Formatting.hours(summary.verifiedHours),
                        label: "Approved",
                        note: "Counted",
                        tint: Brand.cordGreen
                    )
                    figure(
                        value: Formatting.hours(summary.pendingHours),
                        label: "Awaiting review",
                        note: "Not counted yet",
                        tint: .secondary
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(Formatting.hours(summary.verifiedHours)) approved hours out of "
            + "\(Formatting.hours(summary.thresholdHours)) required, "
            + "\(Formatting.percent(summary.percentComplete)). "
            + "\(Formatting.hours(summary.pendingHours)) hours are awaiting review and are not counted yet."
        )
    }

    private func figure(value: String, label: String, note: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(label)
                .font(.subheadline)
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) hours \(label). \(note).")
    }

    // MARK: - Cards

    private func categoryBreakdown(summary: ProgressSummary) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("By category")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                ForEach(model.requirements.categories) { category in
                    let used = summary.byCategory[category.id] ?? 0
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(category.name)
                                .font(.subheadline)
                            Spacer()
                            Text("\(Formatting.hours(used)) h")
                                .font(.subheadline.weight(.medium))
                                .monospacedDigit()
                        }
                        if let cap = category.maxHours.hours {
                            ProgressBar(
                                fraction: cap > 0 ? min(1, used / cap) : 0,
                                met: used >= cap
                            )
                            .frame(height: 6)
                            Text("Handbook maximum \(Formatting.hours(cap)) hours (page \(pageFor(category)))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("The handbook sets no maximum for this category")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(category.name): \(Formatting.hours(used)) approved hours. "
                        + category.maxHours.displayText
                    )
                }
            }
        }
    }

    private func pageFor(_ category: ActivityCategory) -> Int {
        if case let .hours(_, page) = category.maxHours { return page ?? 12 }
        return 12
    }

    private func organisationsCard(summary: ProgressSummary) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Organizations")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("\(summary.distinctOrganizations) so far")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                if model.account?.grade == 12 {
                    let required = model.requirements.limits
                        .minimumDistinctOrganizationsSeniorYear.value
                    Text(
                        summary.distinctOrganizations >= required
                            ? "Meets the senior-year requirement of \(required) separate organizations."
                            : "Seniors need \(required) separate organizations before the Green Cord Award (page 12)."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if !summary.organizations.isEmpty {
                    Text(summary.organizations.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func distinctionCard(summary: ProgressSummary) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Senior distinction levels")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                ForEach(model.requirements.seniorDistinctionLevels) { level in
                    let earned = summary.verifiedHours >= level.minHours
                    HStack {
                        Image(systemName: earned ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(earned ? Brand.cordGreen : .secondary)
                        Text(level.name)
                            .font(.subheadline.weight(earned ? .semibold : .regular))
                        Spacer()
                        Text(level.rangeText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(level.name), \(level.rangeText). "
                        + (earned ? "Reached." : "Not reached yet.")
                    )
                }
            }
        }
    }

    private var checklistCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Program requirements")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                ForEach(model.checklistForGrade) { item in
                    Button {
                        Task { await model.setChecklist(itemId: item.id, checked: !item.checked) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: item.checked ? "checkmark.square.fill" : "square")
                                .foregroundStyle(item.checked ? Brand.cordGreen : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.subheadline)
                                    .multilineTextAlignment(.leading)
                                Text("Handbook page \(item.page)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.title)
                    .accessibilityValue(item.checked ? "Done" : "Not done")
                    .accessibilityHint("Double tap to mark this requirement \(item.checked ? "not done" : "done").")
                    .accessibilityIdentifier("checklist-\(item.id)")
                }
            }
        }
    }

    private func deadlineCard(requirement: GradeRequirement?) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Deadline")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(requirement?.submissionDeadline.value ?? "Not specified in the handbook")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Brand.maroon)
                if let requirement {
                    Text(requirement.submissionDeadline.quote ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Handbook page \(requirement.submissionDeadline.page ?? 16)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A rounded container used across the student and counselor screens.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// A plain progress bar. `fraction` is already clamped by the caller.
struct ProgressBar: View {
    let fraction: Double
    var met = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Brand.silver.opacity(0.4))
                Capsule()
                    .fill(met ? Brand.cordGreen : Brand.maroon)
                    .frame(width: max(0, geometry.size.width * fraction))
            }
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Progress") {
    PreviewShell { ProgressView_GreenCord() }
}

#Preview("Progress, dark") {
    PreviewShell { ProgressView_GreenCord() }
        .preferredColorScheme(.dark)
}

#Preview("Progress, largest text") {
    PreviewShell { ProgressView_GreenCord() }
        .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
