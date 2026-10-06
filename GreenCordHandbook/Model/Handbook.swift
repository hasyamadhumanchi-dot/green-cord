import Foundation

/// One rendered piece of a handbook section, carrying the PDF page it came from
/// so the reader can jump between reflowed text and the original page.
struct HandbookBlock: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case paragraph
        case subheading
        case bullet
    }

    var kind: Kind
    var text: String
    /// Zero-based index into the PDF.
    var page: Int

    var id: String { "\(page)-\(kind.rawValue)-\(text.prefix(32))" }
}

struct HandbookSection: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var order: Int
    var startPage: Int
    var endPage: Int
    var blocks: [HandbookBlock]
    var plainText: String

    /// Page numbers as printed in the handbook footer, which are 1-based.
    var displayPageRange: String {
        startPage == endPage ? "Page \(startPage + 1)" : "Pages \(startPage + 1)-\(endPage + 1)"
    }

    func contains(page: Int) -> Bool {
        (startPage...endPage).contains(page)
    }
}

struct Handbook: Codable, Hashable {
    var schemaVersion: Int
    var contentVersion: String
    var sourcePdf: String
    var pageCount: Int
    var sections: [HandbookSection]

    /// The section a given PDF page belongs to. Sections can share a page, so the
    /// last one that starts at or before the page wins - that is the section a
    /// reader looking at the page is actually inside.
    func section(forPage page: Int) -> HandbookSection? {
        sections
            .filter { $0.startPage <= page }
            .max(by: { ($0.startPage, $0.order) < ($1.startPage, $1.order) })
    }

    func section(id: String) -> HandbookSection? {
        sections.first { $0.id == id }
    }
}
