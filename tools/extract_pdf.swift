import Foundation
import PDFKit
import AppKit

let args = CommandLine.arguments
guard args.count > 1, let doc = PDFDocument(url: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write("cannot open pdf\n".data(using:.utf8)!); exit(1)
}
var pages: [[String: Any]] = []
for i in 0..<doc.pageCount {
    guard let page = doc.page(at: i) else { continue }
    let plain = page.string ?? ""
    var runs: [[String: Any]] = []
    if let attr = page.attributedString {
        attr.enumerateAttributes(in: NSRange(location: 0, length: attr.length), options: []) { attrs, range, _ in
            let s = (attr.string as NSString).substring(with: range)
            var size: Double = 0
            var name = ""
            if let f = attrs[.font] as? NSFont { size = Double(f.pointSize); name = f.fontName }
            runs.append(["t": s, "size": size, "font": name])
        }
    }
    let b = page.bounds(for: .mediaBox)
    pages.append(["index": i, "label": page.label ?? "\(i+1)", "text": plain, "runs": runs,
                  "w": Double(b.width), "h": Double(b.height)])
}
let out: [String: Any] = ["pageCount": doc.pageCount, "pages": pages]
let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
