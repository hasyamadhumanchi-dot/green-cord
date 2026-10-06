import Foundation
import PDFKit

/// One hit, carrying both coordinates the reader might want: the reflowed
/// section it lives in and the PDF page it is printed on. That pairing is what
/// lets a single search work in both reading modes.
struct SearchHit: Identifiable, Hashable {
    var sectionId: String
    var sectionTitle: String
    /// Zero-based PDF page index.
    var page: Int
    /// The matching text with a little context either side.
    var snippet: String
    /// Range of the match inside `snippet`, for highlighting.
    var matchRange: Range<String.Index>?
    var occurrences: Int

    var id: String { "\(sectionId)-\(page)-\(snippet.prefix(40))" }
    var displayPage: Int { page + 1 }
}

/// Full-text search over the reflowed handbook.
///
/// Matching is case- and diacritic-insensitive so a student typing "faith based"
/// finds "Faith Based". Results are ranked with title matches first, then by how
/// often the phrase appears, then by page order.
struct SearchIndex {
    private struct Entry {
        let sectionId: String
        let sectionTitle: String
        let normalisedTitle: String
        let page: Int
        let text: String
        let normalisedText: String
    }

    private let entries: [Entry]
    let sections: [HandbookSection]

    init(handbook: Handbook) {
        sections = handbook.sections
        entries = handbook.sections.flatMap { section in
            section.blocks.map { block in
                Entry(
                    sectionId: section.id,
                    sectionTitle: section.title,
                    normalisedTitle: Self.normalise(section.title),
                    page: block.page,
                    text: block.text,
                    normalisedText: Self.normalise(block.text)
                )
            }
        }
    }

    static func normalise(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    func search(_ rawQuery: String, limit: Int = 60) -> [SearchHit] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        let needle = Self.normalise(query)

        var hits: [SearchHit] = []
        var seen = Set<String>()

        for entry in entries {
            let inTitle = entry.normalisedTitle.contains(needle)
            guard entry.normalisedText.contains(needle) || inTitle else { continue }

            let occurrences = entry.normalisedText.occurrences(of: needle)
            let snippet = Self.snippet(from: entry.text, matching: needle)
            let hit = SearchHit(
                sectionId: entry.sectionId,
                sectionTitle: entry.sectionTitle,
                page: entry.page,
                snippet: snippet.text,
                matchRange: snippet.range,
                occurrences: max(occurrences, inTitle ? 1 : 0)
            )
            guard seen.insert(hit.id).inserted else { continue }
            hits.append(hit)
        }

        let needleForRank = needle
        return Array(
            hits.sorted { left, right in
                let leftTitle = Self.normalise(left.sectionTitle).contains(needleForRank)
                let rightTitle = Self.normalise(right.sectionTitle).contains(needleForRank)
                if leftTitle != rightTitle { return leftTitle }
                if left.occurrences != right.occurrences { return left.occurrences > right.occurrences }
                return left.page < right.page
            }
            .prefix(limit)
        )
    }

    /// Every distinct PDF page a query appears on, in page order. This is what
    /// the PDF reading mode uses.
    func pages(matching query: String) -> [Int] {
        var pages: [Int] = []
        for hit in search(query) where !pages.contains(hit.page) {
            pages.append(hit.page)
        }
        return pages.sorted()
    }

    /// The first section a query appears in, preferring a title match.
    func firstSection(matching query: String) -> HandbookSection? {
        guard let hit = search(query).first else { return nil }
        return sections.first { $0.id == hit.sectionId }
    }

    private static func snippet(
        from text: String,
        matching needle: String,
        context: Int = 70
    ) -> (text: String, range: Range<String.Index>?) {
        let normalised = normalise(text)
        guard let found = normalised.range(of: needle) else {
            return (String(text.prefix(context * 2)), nil)
        }
        // The normalised string is built by folding, which preserves length for
        // the scripts this handbook uses, so offsets carry over.
        let lower = normalised.distance(from: normalised.startIndex, to: found.lowerBound)
        let upper = normalised.distance(from: normalised.startIndex, to: found.upperBound)
        guard lower <= text.count, upper <= text.count else {
            return (String(text.prefix(context * 2)), nil)
        }

        let start = max(0, lower - context)
        let end = min(text.count, upper + context)
        let startIndex = text.index(text.startIndex, offsetBy: start)
        let endIndex = text.index(text.startIndex, offsetBy: end)
        var snippet = String(text[startIndex..<endIndex])

        let prefix = start > 0 ? "..." : ""
        let suffix = end < text.count ? "..." : ""
        let matchStart = snippet.index(snippet.startIndex, offsetBy: lower - start)
        let matchEnd = snippet.index(snippet.startIndex, offsetBy: upper - start)
        let matchedText = String(snippet[matchStart..<matchEnd])
        snippet = prefix + snippet + suffix

        let range = snippet.range(of: matchedText)
        return (snippet, range)
    }
}

/// PDF-side search, so the original-pages mode finds the same phrase in the real
/// document rather than relying on the reflowed copy.
enum PDFSearch {
    static func pages(in document: PDFDocument, matching query: String) -> [Int] {
        let selections = document.findString(query, withOptions: [.caseInsensitive])
        var pages: [Int] = []
        for selection in selections {
            for page in selection.pages {
                let index = document.index(for: page)
                if !pages.contains(index) { pages.append(index) }
            }
        }
        return pages.sorted()
    }
}

private extension String {
    func occurrences(of needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var cursor = startIndex
        while let found = range(of: needle, range: cursor..<endIndex) {
            count += 1
            cursor = found.upperBound
        }
        return count
    }
}
