import SwiftData
import SwiftUI

#if DEBUG

/// Scaffolding for Xcode's preview canvas.
///
/// Every screen needs an `AppModel`, which needs content, a store and a backend.
/// Building that by hand in each preview would be tedious enough that nobody
/// would write previews at all, so it is built once here.
///
/// The preview model talks to `UnreachableAPI`, so previews show the app exactly
/// as it looks with no server: the handbook works, and the account screens show
/// their signed-out state. That is the right default - a preview should never
/// depend on whether a server happens to be running.
@MainActor
enum PreviewData {
    static let model: AppModel = {
        let container = try! LocalStore.container(inMemory: true)
        return AppModel(
            store: ContentStore(
                cacheDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("previews-\(UUID().uuidString)")
            ),
            api: UnreachableAPI(),
            network: URLSession.shared,
            modelContext: ModelContext(container)
        )
    }()

    /// A section with enough text in it to be worth looking at.
    static var sampleSection: HandbookSection {
        model.handbook.sections.first { $0.id == "service-hour-requirements" }
            ?? model.handbook.sections[0]
    }

    static var sampleEntry: HourEntry {
        HourEntry(
            id: "preview-1",
            studentId: "preview-student",
            serviceDate: "2026-09-13",
            hours: 6.5,
            category: "community",
            organization: "Princeton Community Food Pantry",
            description: "Sorted and boxed donated food for weekend distribution.",
            verifierName: "Pantry Volunteer Coordinator",
            verifierContact: "volunteer.coordinator@example.org",
            evidenceURL: nil,
            counselorEntered: false,
            status: .submitted,
            updatedAt: nil,
            submittedAt: nil,
            decidedAt: nil
        )
    }

    static var sampleRosterRow: RosterRow {
        RosterRow(
            studentId: "preview-student",
            displayName: "Alpha Alderwood",
            lastName: "Alderwood",
            grade: 11,
            verifiedHours: 41.5,
            pendingHours: 6.5,
            thresholdHours: 75,
            percentComplete: 55.3,
            lastActivityAt: Date().timeIntervalSince1970
        )
    }
}

/// Wraps a screen the way the running app does, so a preview shows the real
/// navigation bar, toolbar and tint rather than a bare view.
struct PreviewShell<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            content
        }
        .environment(PreviewData.model)
        .tint(Brand.maroon)
    }
}

#endif
