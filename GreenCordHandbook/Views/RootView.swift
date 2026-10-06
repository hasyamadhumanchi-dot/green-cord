import SwiftUI

/// The app's sections. A student never sees the counselor's two.
enum AppDestination: String, Hashable, CaseIterable, Identifiable {
    case counselorHome
    case handbook
    case myHours
    case progress
    case reviewQueue
    case roster
    case account

    var id: String { rawValue }

    var title: String {
        switch self {
        case .counselorHome: return "Home"
        case .handbook: return "Handbook"
        case .myHours: return "My Hours"
        case .progress: return "My Progress"
        case .reviewQueue: return "Review Queue"
        case .roster: return "Students"
        case .account: return "Account"
        }
    }

    var symbol: String {
        switch self {
        case .counselorHome: return "square.grid.2x2"
        case .handbook: return "book.closed"
        case .myHours: return "list.bullet.clipboard"
        case .progress: return "chart.bar"
        case .reviewQueue: return "tray.full"
        case .roster: return "person.3"
        case .account: return "person.crop.circle"
        }
    }

    static func destinations(for role: Account.Role?) -> [AppDestination] {
        switch role {
        case .student:
            // No roster, no ranking, nothing about anyone else.
            return [.progress, .myHours, .handbook, .account]
        case .manager, .admin:
            return [.counselorHome, .reviewQueue, .roster, .handbook, .account]
        case nil:
            // Unreachable: `RootView` shows the welcome screen instead.
            return []
        }
    }
}

/// Chooses the navigation that fits the device.
///
/// iPad gets a sidebar and a detail pane, because a 13-inch screen showing one
/// stretched phone column wastes most of itself. iPhone gets a tab bar and
/// pushes.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if !model.isSignedIn {
                // The whole app sits behind this, handbook included: these are
                // school records, not a public leaflet.
                WelcomeView()
            } else if sizeClass == .regular {
                SplitRootView()
            } else {
                TabRootView()
            }
        }
        .background(Brand.pageBackground)
    }
}

/// iPad and other regular-width layouts.
struct SplitRootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: AppDestination?
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(
                AppDestination.destinations(for: model.role),
                selection: $selection
            ) { destination in
                NavigationLink(value: destination) {
                    Label(destination.title, systemImage: destination.symbol)
                }
                .accessibilityLabel(destination.title)
            }
            .navigationTitle("Green Cord")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    BrandHeader(compact: true)
                }
            }
            .accessibilityIdentifier("sidebar")
        } detail: {
            NavigationStack {
                destinationView(selection ?? defaultDestination)
            }
        }
        .onAppear {
            if selection == nil { selection = defaultDestination }
        }
        .navigationSplitViewStyle(.balanced)
        .accessibilityIdentifier("splitView")
    }

    /// A student lands on their progress, the counselor on their dashboard.
    private var defaultDestination: AppDestination {
        AppDestination.destinations(for: model.role).first ?? .account
    }

    @ViewBuilder
    private func destinationView(_ destination: AppDestination) -> some View {
        switch destination {
        case .counselorHome: CounselorHomeView()
        case .handbook: HandbookReaderView()
        case .myHours: MyHoursView()
        case .progress: ProgressView_GreenCord()
        case .reviewQueue: ReviewQueueView()
        case .roster: RosterView()
        case .account: AccountView()
        }
    }
}

/// iPhone and other compact layouts.
struct TabRootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: AppDestination?

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppDestination.destinations(for: model.role)) { destination in
                NavigationStack {
                    view(for: destination)
                }
                .tabItem {
                    Label(destination.title, systemImage: destination.symbol)
                }
                .tag(Optional(destination))
                .accessibilityIdentifier("tab-\(destination.rawValue)")
            }
        }
        .accessibilityIdentifier("tabView")
        .onAppear {
            if selection == nil {
                selection = AppDestination.destinations(for: model.role).first
            }
        }
    }

    @ViewBuilder
    private func view(for destination: AppDestination) -> some View {
        switch destination {
        case .counselorHome: CounselorHomeView()
        case .handbook: HandbookReaderView()
        case .myHours: MyHoursView()
        case .progress: ProgressView_GreenCord()
        case .reviewQueue: ReviewQueueView()
        case .roster: RosterView()
        case .account: AccountView()
        }
    }
}

/// The panther mark beside the program name, in the school's maroon.
struct BrandHeader: View {
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            BrandLogo(size: compact ? 24 : 32)
            VStack(alignment: .leading, spacing: 0) {
                Text("Green Cord")
                    .font(compact ? .headline : .title3.weight(.semibold))
                if !compact {
                    Text("Princeton Senior High School")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Green Cord, Princeton Senior High School")
    }
}

#if DEBUG
#Preview("Root") {
    RootView().environment(PreviewData.model).tint(Brand.maroon)
}
#endif
