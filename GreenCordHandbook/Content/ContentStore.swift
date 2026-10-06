import Foundation

/// Where the app's handbook content is configured.
///
/// The manifest URL is a build-time constant. It is a **documented placeholder**
/// until the school webmaster confirms a writable path - see
/// `content/source-of-truth.md`. Only this one value needs to change.
enum ContentSource {
    static let manifestURL = URL(
        string: "https://pshs.princetonisd.net/greencord-app-content/manifest.json"
    )!

    /// Bumped only when the *shape* of the content changes. A manifest declaring
    /// a schemaVersion this build does not understand is ignored rather than
    /// guessed at.
    static let supportedSchemaVersion = 1
}

/// The manifest the school site serves. Data only - it names JSON and a PDF and
/// nothing else, so a content update can never deliver code.
struct ContentManifest: Codable, Hashable {
    struct File: Codable, Hashable {
        enum Role: String, Codable {
            case handbook
            case requirements
            case pdf
        }

        var role: Role
        var name: String
        var url: URL
        var sha256: String
        var bytes: Int
    }

    var schemaVersion: Int
    var contentVersion: String
    var publishedAt: String
    var notes: String?
    var files: [File]

    func file(role: File.Role) -> File? { files.first { $0.role == role } }
}

/// Compares versions of the form YYYY.MM.DD. Anything unparseable sorts lowest,
/// so a malformed remote version can never look newer than what is installed.
enum ContentVersion {
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let remote = components(candidate)
        guard remote != malformed else { return false }
        return components(current).lexicographicallyPrecedes(remote)
    }

    private static let malformed = [-1, -1, -1]

    static func components(_ version: String) -> [Int] {
        let parts = version.split(separator: ".").map { Int($0) ?? -1 }
        guard parts.count == 3, parts.allSatisfy({ $0 >= 0 }) else { return malformed }
        return parts
    }
}

/// The content the app is currently showing, and where it came from.
struct LoadedContent: Hashable {
    enum Origin: String {
        case bundled
        case downloaded
    }

    var handbook: Handbook
    var requirements: Requirements
    var pdfURL: URL
    var contentVersion: String
    var origin: Origin
}

enum ContentError: Error, LocalizedError {
    case missingBundledResource(String)
    case unsupportedSchema(Int)
    case notNewer(remote: String, local: String)
    case checksumMismatch(file: String, expected: String, actual: String)
    case decodeFailed(file: String)

    var errorDescription: String? {
        switch self {
        case let .missingBundledResource(name):
            return "The app is missing its bundled copy of \(name)."
        case let .unsupportedSchema(version):
            return "The handbook update uses format \(version), which this version of the app does not understand. Update the app from the App Store."
        case let .notNewer(remote, local):
            return "The published handbook (\(remote)) is not newer than the one installed (\(local))."
        case let .checksumMismatch(file, _, _):
            return "The downloaded file \(file) did not match its published checksum, so it was discarded."
        case let .decodeFailed(file):
            return "The downloaded file \(file) could not be read, so it was discarded."
        }
    }
}

/// Holds the bundled snapshot and any downloaded content, and decides which the
/// app should be using.
///
/// The bundled copy is never overwritten or deleted; a download is stored beside
/// it. If a download is ever found to be bad, the app falls straight back to the
/// bundled snapshot, so the handbook is always readable.
final class ContentStore {
    private let bundle: Bundle
    private let cacheDirectory: URL
    private let fileManager: FileManager

    init(
        bundle: Bundle = .main,
        cacheDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.bundle = bundle
        self.fileManager = fileManager
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.cacheDirectory = support.appendingPathComponent("HandbookContent", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Loading

    /// The content the app should show: the downloaded copy when there is a
    /// valid, newer one, otherwise the copy that shipped in the app.
    func load() -> LoadedContent {
        if let downloaded = try? loadDownloaded() {
            if ContentVersion.isNewer(downloaded.contentVersion, than: bundledVersion()) {
                return downloaded
            }
        }
        // Force-unwrapped on purpose: an app that cannot read its own bundled
        // handbook is broken beyond anything a fallback could rescue, and the
        // bundled-resource test catches it long before a build ships.
        return try! loadBundled()
    }

    func loadBundled() throws -> LoadedContent {
        let handbookData = try bundledData("handbook", "json")
        let requirementsData = try bundledData("requirements", "json")
        guard let pdfURL = bundle.url(forResource: "PISDGreenCordHandbook", withExtension: "pdf") else {
            throw ContentError.missingBundledResource("PISDGreenCordHandbook.pdf")
        }
        let handbook = try JSONDecoder().decode(Handbook.self, from: handbookData)
        let requirements = try JSONDecoder().decode(Requirements.self, from: requirementsData)
        return LoadedContent(
            handbook: handbook,
            requirements: requirements,
            pdfURL: pdfURL,
            contentVersion: handbook.contentVersion,
            origin: .bundled
        )
    }

    func loadDownloaded() throws -> LoadedContent {
        let handbookData = try Data(contentsOf: cachedURL("handbook.json"))
        let requirementsData = try Data(contentsOf: cachedURL("requirements.json"))
        let pdfURL = cachedURL("PISDGreenCordHandbook.pdf")
        guard fileManager.fileExists(atPath: pdfURL.path) else {
            throw ContentError.missingBundledResource("downloaded PDF")
        }
        let handbook = try JSONDecoder().decode(Handbook.self, from: handbookData)
        let requirements = try JSONDecoder().decode(Requirements.self, from: requirementsData)
        return LoadedContent(
            handbook: handbook,
            requirements: requirements,
            pdfURL: pdfURL,
            contentVersion: handbook.contentVersion,
            origin: .downloaded
        )
    }

    func bundledVersion() -> String {
        (try? loadBundled().contentVersion) ?? "0000.00.00"
    }

    /// The version the app is actually showing.
    func currentVersion() -> String {
        load().contentVersion
    }

    // MARK: - Installing an update

    /// Writes a verified payload into the cache in one step. Called only after
    /// every file has passed its checksum, so a half-written update cannot be
    /// left behind.
    func install(handbook: Data, requirements: Data, pdf: Data) throws {
        // Decode before writing anything: content that will not parse never
        // reaches disk, and the previous good copy stays untouched.
        let decodedHandbook: Handbook
        do {
            decodedHandbook = try JSONDecoder().decode(Handbook.self, from: handbook)
        } catch {
            throw ContentError.decodeFailed(file: "handbook.json")
        }
        do {
            _ = try JSONDecoder().decode(Requirements.self, from: requirements)
        } catch {
            throw ContentError.decodeFailed(file: "requirements.json")
        }
        guard decodedHandbook.schemaVersion == ContentSource.supportedSchemaVersion else {
            throw ContentError.unsupportedSchema(decodedHandbook.schemaVersion)
        }

        let staging = cacheDirectory.appendingPathComponent("staging", isDirectory: true)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try handbook.write(to: staging.appendingPathComponent("handbook.json"))
        try requirements.write(to: staging.appendingPathComponent("requirements.json"))
        try pdf.write(to: staging.appendingPathComponent("PISDGreenCordHandbook.pdf"))

        for name in ["handbook.json", "requirements.json", "PISDGreenCordHandbook.pdf"] {
            let destination = cachedURL(name)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: staging.appendingPathComponent(name), to: destination)
        }
        try? fileManager.removeItem(at: staging)
    }

    /// Throws away any downloaded copy and goes back to what shipped in the app.
    func revertToBundled() {
        for name in ["handbook.json", "requirements.json", "PISDGreenCordHandbook.pdf"] {
            try? fileManager.removeItem(at: cachedURL(name))
        }
    }

    private func cachedURL(_ name: String) -> URL {
        cacheDirectory.appendingPathComponent(name)
    }

    private func bundledData(_ name: String, _ ext: String) throws -> Data {
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw ContentError.missingBundledResource("\(name).\(ext)")
        }
        return try Data(contentsOf: url)
    }
}
