import PDFKit
import SwiftUI

/// The reader: the original handbook pages, opened at the chosen section.
///
/// The handbook shows the counselor's real pages and nothing else. The
/// extracted text is still loaded, but only to power search and to give
/// VoiceOver something to read, never as a second reading mode.
struct HandbookReaderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var selectedSectionId: String?
    @State private var currentPage = 0
    @State private var searchText = ""
    /// The section pushed onto the stack in the compact layout. iPad shows the
    /// reader beside the list and does not use this.
    @State private var pushedSection: HandbookSection?

    private var sections: [HandbookSection] { model.handbook.sections }

    private var selectedSection: HandbookSection? {
        selectedSectionId.flatMap { model.handbook.section(id: $0) } ?? sections.first
    }

    var body: some View {
        Group {
            if sizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .navigationTitle("Handbook")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search the handbook"
        )
        .onAppear {
            if selectedSectionId == nil {
                // The cover and the table of contents carry almost no text, so
                // opening on either leaves the iPad detail pane looking empty.
                selectedSectionId = (sections.first { $0.blocks.count > 2 } ?? sections.first)?.id
                if let section = selectedSection { currentPage = section.startPage }
            }
        }
    }

    // MARK: - Layouts

    /// iPad: the section list stays beside the page being read.
    private var regularLayout: some View {
        HStack(spacing: 0) {
            sectionList
                .frame(width: 320)
                .background(Brand.cardBackground)
            Divider()
            readerPane
                .frame(maxWidth: .infinity)
        }
    }

    /// iPhone: a list that pushes to the reader.
    private var compactLayout: some View {
        Group {
            if searchText.isEmpty {
                List(sections) { section in
                    Button {
                        pushedSection = section
                    } label: {
                        sectionRow(section)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(section.title), \(section.displayPageRange)")
                    .accessibilityHint("Opens this section.")
                }
                .listStyle(.plain)
            } else {
                searchResults
            }
        }
        // Driven by state rather than by NavigationLink, so that opening a
        // search result pushes the reader too. Before this, tapping a hit on
        // iPhone set the selection and then showed the list again, which looked
        // like nothing had happened.
        .navigationDestination(item: $pushedSection) { section in
            readerPane(for: section)
                .navigationTitle(section.title)
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var sectionList: some View {
        Group {
            if searchText.isEmpty {
                // No `selection:` binding: the rows are buttons that set the
                // selection themselves, and a List selection binding resets
                // itself to nil on appear, which would undo the default section.
                List(sections) { section in
                    Button {
                        select(section)
                    } label: {
                        sectionRow(section)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        section.id == selectedSection?.id
                            ? Brand.maroon.opacity(0.12) : Color.clear
                    )
                }
                .listStyle(.inset)
            } else {
                searchResults
            }
        }
    }

    private func sectionRow(_ section: HandbookSection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(section.title)
                .font(.body.weight(.medium))
                .multilineTextAlignment(.leading)
            Text(section.displayPageRange)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(section.title), \(section.displayPageRange)")
        .accessibilityIdentifier("section-\(section.id)")
    }

    // MARK: - Reader

    private var readerPane: some View {
        Group {
            if let section = selectedSection {
                readerPane(for: section)
            } else {
                ContentUnavailableView(
                    "Choose a section",
                    systemImage: "book.closed",
                    description: Text("Pick a section on the left to start reading.")
                )
            }
        }
    }

    private func readerPane(for section: HandbookSection) -> some View {
        readerContent(for: section)
            .onAppear {
                // On iPhone the reader is reached by a push, which does not go
                // through `select(_:)`, so the section has to be recorded here
                // or the pages view would open on page 1.
                selectedSectionId = section.id
                currentPage = section.startPage
            }
    }

    private func readerContent(for section: HandbookSection) -> some View {
        PDFPageReaderView(
            document: model.pdfDocument,
            page: Binding(
                get: { currentPage },
                set: { newPage in
                    currentPage = newPage
                    // Paging past a section boundary moves the selection with
                    // it, so the list always shows where the reader actually is.
                    if let owning = model.handbook.section(forPage: newPage) {
                        selectedSectionId = owning.id
                    }
                }
            ),
            accessibleText: accessibleText(forPage: currentPage)
        )
        .accessibilityIdentifier("pdfReader")
    }

    /// The reflowed text of the page currently shown, offered to VoiceOver as an
    /// alternative to an image of a page, which a screen reader cannot read.
    private func accessibleText(forPage page: Int) -> String {
        let blocks = model.handbook.sections
            .flatMap(\.blocks)
            .filter { $0.page == page }
            .map(\.text)
        guard !blocks.isEmpty else { return "Page \(page + 1) of the handbook." }
        return "Page \(page + 1). " + blocks.joined(separator: ". ")
    }

    // MARK: - Search

    private var searchResults: some View {
        SearchResultsList(
            hits: model.searchIndex.search(searchText),
            query: searchText,
            onOpen: { hit in open(hit) }
        )
    }

    private func open(_ hit: SearchHit) {
        selectedSectionId = hit.sectionId
        currentPage = hit.page
        searchText = ""
        // On iPhone the reader has to be pushed; on iPad it is already beside
        // the list, and pushing would bury it.
        if sizeClass != .regular {
            pushedSection = model.handbook.section(id: hit.sectionId)
        }
    }

    private func select(_ section: HandbookSection) {
        selectedSectionId = section.id
        currentPage = section.startPage
    }

}

/// The original pages, rendered by PDFKit from the bundled file.
struct PDFPageReaderView: View {
    let document: PDFDocument?
    @Binding var page: Int
    /// The same page's text, so VoiceOver has something to read.
    var accessibleText: String

    var body: some View {
        Group {
            if let document {
                VStack(spacing: 0) {
                    PDFKitView(document: document, page: $page)
                        .accessibilityElement()
                        .accessibilityLabel(accessibleText)
                        .accessibilityIdentifier("pdfPage")
                    pageControls(pageCount: document.pageCount)
                }
            } else {
                ContentUnavailableView(
                    "The handbook could not be opened",
                    systemImage: "doc.questionmark",
                    description: Text(
                        "Check for a new handbook on the Account screen, or ask your counselor."
                    )
                )
            }
        }
        .background(Brand.pageBackground)
    }

    private func pageControls(pageCount: Int) -> some View {
        HStack {
            Button {
                page = max(0, page - 1)
            } label: {
                Label("Previous page", systemImage: "chevron.left")
            }
            .disabled(page <= 0)
            .accessibilityLabel("Previous page")

            Spacer()

            Text("Page \(page + 1) of \(pageCount)")
                .font(.footnote)
                .monospacedDigit()
                .accessibilityLabel("Page \(page + 1) of \(pageCount)")

            Spacer()

            Button {
                page = min(pageCount - 1, page + 1)
            } label: {
                Label("Next page", systemImage: "chevron.right")
            }
            .disabled(page >= pageCount - 1)
            .accessibilityLabel("Next page")
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// Thin wrapper around PDFView. Kept minimal on purpose: the page binding is the
/// only state, so the SwiftUI side stays the source of truth for position.
struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    @Binding var page: Int

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.usePageViewController(true)
        view.backgroundColor = .systemBackground
        view.delegate = context.coordinator
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: view
        )
        if let target = document.page(at: page) { view.go(to: target) }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        guard
            let target = document.page(at: page),
            view.currentPage != target
        else { return }
        view.go(to: target)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PDFViewDelegate {
        var parent: PDFKitView

        init(_ parent: PDFKitView) { self.parent = parent }

        @objc func pageChanged(_ notification: Notification) {
            guard
                let view = notification.object as? PDFView,
                let current = view.currentPage,
                let document = view.document
            else { return }
            let index = document.index(for: current)
            if index != parent.page { parent.page = index }
        }
    }
}


/// The list of search hits.
///
/// Separate from `HandbookReaderView` so it can reach `dismissSearch`, which is
/// only published to views inside the `.searchable` scope.
struct SearchResultsList: View {
    let hits: [SearchHit]
    let query: String
    let onOpen: (SearchHit) -> Void

    @Environment(\.dismissSearch) private var dismissSearch

    var body: some View {
        Group {
            if hits.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(hits) { hit in
                    Button {
                        onOpen(hit)
                        // Ends the search, which also brings the rest of the
                        // toolbar - including the reading-mode toggle - back.
                        dismissSearch()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(hit.sectionTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Brand.maroon)
                            Text(highlighted(hit.snippet))
                                .font(.callout)
                                .foregroundStyle(.primary)
                            Text("Page \(hit.displayPage)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("hit-\(hit.sectionId)")
                    .accessibilityLabel(
                        "\(hit.sectionTitle), page \(hit.displayPage). \(hit.snippet)"
                    )
                }
                .listStyle(.plain)
                .accessibilityIdentifier("searchResults")
            }
        }
    }

    private func highlighted(_ snippet: String) -> AttributedString {
        var attributed = AttributedString(snippet)
        guard !query.isEmpty else { return attributed }
        let needle = SearchIndex.normalise(query)
        let haystack = SearchIndex.normalise(snippet)
        if let range = haystack.range(of: needle),
           let mapped = Range(range, in: attributed) {
            attributed[mapped].backgroundColor = Brand.maroon.opacity(0.18)
            attributed[mapped].font = .body.bold()
        }
        return attributed
    }
}

#if DEBUG
#Preview("Handbook") {
    PreviewShell { HandbookReaderView() }
}

// Layout at the largest text size a reader can choose. Anything that breaks
// here breaks for a real person, not a hypothetical one.
#Preview("Largest text") {
    PreviewShell { HandbookReaderView() }
        .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
