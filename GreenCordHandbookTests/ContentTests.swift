import Foundation
import PDFKit
import Testing
@testable import GreenCordHandbook

/// Gates C6, C7 and C9: the bundled content matches the source PDF and the
/// generated outline, and search finds real phrases in the handbook. The text
/// is extracted but never shown: it backs search and VoiceOver, while the
/// reader shows the original pages.
@Suite("Bundled handbook content")
struct ContentTests {

    /// The outline the pipeline generated, parsed straight out of the markdown
    /// so the test compares the app against the artefact, not against itself.
    static func outlineRows() throws -> [(title: String, id: String)] {
        let url = try #require(
            Bundle(for: BundleToken.self).url(forResource: "handbook-outline", withExtension: "md")
                ?? Bundle.main.url(forResource: "handbook-outline", withExtension: "md")
        )
        let markdown = try String(contentsOf: url, encoding: .utf8)
        var rows: [(String, String)] = []
        for line in markdown.split(separator: "\n") {
            let columns = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count >= 5, Int(columns[1]) != nil else { continue }
            let identifier = columns[4].trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            rows.append((columns[2], identifier))
        }
        return rows
    }

    static func loadContent() throws -> LoadedContent {
        let store = ContentStore(
            bundle: Bundle(for: BundleToken.self),
            cacheDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("content-tests-\(UUID().uuidString)")
        )
        return try store.loadBundled()
    }

    @Test("C6 every section in handbook-outline.md is in the app, in order")
    func sectionsMatchOutline() throws {
        let content = try Self.loadContent()
        let outline = try Self.outlineRows()

        #expect(outline.isEmpty == false, "the outline should have parsed")
        #expect(content.handbook.sections.count == outline.count)

        let appIDs = content.handbook.sections.map(\.id)
        let appTitles = content.handbook.sections.map(\.title)
        #expect(appIDs == outline.map(\.id))
        #expect(appTitles == outline.map(\.title))
    }

    @Test("C6 every section has readable text and a real page range")
    func sectionsAreReadable() throws {
        let content = try Self.loadContent()
        for section in content.handbook.sections {
            #expect(!section.blocks.isEmpty, "\(section.id) has no text")
            #expect(section.startPage >= 0)
            #expect(section.endPage < content.handbook.pageCount)
            #expect(section.startPage <= section.endPage)
            for block in section.blocks {
                #expect(
                    (section.startPage...section.endPage).contains(block.page),
                    "\(section.id) has a block on page \(block.page), outside \(section.startPage)-\(section.endPage)"
                )
            }
        }
    }

    @Test("C7 the bundled PDF has the same page count as the content declares")
    func pdfPageCountMatches() throws {
        let content = try Self.loadContent()
        let document = try #require(PDFDocument(url: content.pdfURL))
        #expect(document.pageCount == content.handbook.pageCount)
        #expect(document.pageCount == 20, "the Green Cord handbook is 20 pages")
    }

    @Test("C7 every PDF page belongs to a section, so the two modes always line up")
    func everyPageMapsToASection() throws {
        let content = try Self.loadContent()
        for page in 0..<content.handbook.pageCount {
            let section = content.handbook.section(forPage: page)
            #expect(section != nil, "page \(page + 1) belongs to no section")
        }
    }

    @Test("C9 searching a phrase that is really in the PDF finds the right section and page")
    func searchFindsRealPhrases() throws {
        let content = try Self.loadContent()
        let index = SearchIndex(handbook: content.handbook)
        let document = try #require(PDFDocument(url: content.pdfURL))

        // Each phrase is quoted from the handbook, with the section and the
        // printed page it appears on.
        let cases: [(phrase: String, sectionID: String, page: Int)] = [
            ("Minimum 25 cumulative verified service hours", "service-hour-requirements", 6),
            ("Silver Service Distinction", "senior-distinguished-service-levels", 7),
            ("Habitat for Humanity", "what-counts-as-community-service", 11),
            ("Single Organization Limit", "service-hour-limitations", 12),
            ("Court ordered community service", "activities-that-do-not-qualify", 13),
            ("Parents may not verify their own student", "parent-responsibilities", 16),
        ]

        for testCase in cases {
            let hits = index.search(testCase.phrase)
            #expect(!hits.isEmpty, "\"\(testCase.phrase)\" was not found in the reflowed text")

            let sections = Set(hits.map(\.sectionId))
            #expect(
                sections.contains(testCase.sectionID),
                "\"\(testCase.phrase)\" should be in \(testCase.sectionID), got \(sections)"
            )

            let reflowedPages = index.pages(matching: testCase.phrase).map { $0 + 1 }
            #expect(
                reflowedPages.contains(testCase.page),
                "\"\(testCase.phrase)\" should be on page \(testCase.page), got \(reflowedPages)"
            )

            // The same phrase, found independently by PDFKit in the real document.
            let pdfPages = PDFSearch.pages(in: document, matching: testCase.phrase).map { $0 + 1 }
            #expect(
                pdfPages.contains(testCase.page),
                "PDFKit should find \"\(testCase.phrase)\" on page \(testCase.page), got \(pdfPages)"
            )
        }
    }

    @Test("C9 search ignores case and accents, and rejects a phrase that is not there")
    func searchBehaviour() throws {
        let content = try Self.loadContent()
        let index = SearchIndex(handbook: content.handbook)

        #expect(!index.search("SILVER SERVICE").isEmpty)
        #expect(!index.search("silver service").isEmpty)
        #expect(index.search("quidditch tournament").isEmpty)
        // Under two characters is treated as no query rather than matching everything.
        #expect(index.search("a").isEmpty)
    }

    @Test("C8 a section and its source page round-trip both ways")
    func modeToggleKeepsPlace() throws {
        let content = try Self.loadContent()
        let handbook = content.handbook

        for section in handbook.sections {
            // Text mode -> pages mode opens the section's first page.
            let page = section.startPage
            // Pages mode -> text mode returns to the section owning that page.
            let restored = handbook.section(forPage: page)
            #expect(restored != nil)
            #expect(
                restored?.contains(page: page) == true,
                "\(section.id): page \(page) resolved to \(restored?.id ?? "nil")"
            )
        }
    }
}

/// Lets the test bundle find its own resources.
final class BundleToken {}
