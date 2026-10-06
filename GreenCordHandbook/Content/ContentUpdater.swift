import CryptoKit
import Foundation

/// The one way the app talks to the network. Everything that fetches goes
/// through this, so tests can substitute a stub and an offline run is a stub
/// that always throws.
protocol NetworkFetching: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: NetworkFetching {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, delegate: nil)
    }
}

enum NetworkError: Error, LocalizedError {
    case insecureURL(URL)
    case badStatus(Int)
    case offline

    var errorDescription: String? {
        switch self {
        case let .insecureURL(url):
            return "Refused to fetch \(url.absoluteString): the app only accepts https."
        case let .badStatus(code):
            return "The school website answered with status \(code)."
        case .offline:
            return "No network connection."
        }
    }
}

/// Checks the school site for newer handbook content and installs it, but only
/// when it is genuinely newer and every file matches its published checksum.
///
/// A failure here is never fatal and never blocks the reader: whatever the app
/// already has stays in place and stays readable.
actor ContentUpdater {
    enum Outcome: Equatable {
        case upToDate(version: String)
        case updated(from: String, to: String)
        case ignoredOlder(remote: String, local: String)
        case rejected(reason: String)
        case unreachable(reason: String)
    }

    private let store: ContentStore
    private let network: NetworkFetching
    private let manifestURL: URL

    init(
        store: ContentStore,
        network: NetworkFetching,
        manifestURL: URL = ContentSource.manifestURL
    ) {
        self.store = store
        self.network = network
        self.manifestURL = manifestURL
    }

    @discardableResult
    func checkForUpdate() async -> Outcome {
        let localVersion = store.currentVersion()
        do {
            let manifest = try await fetchManifest()

            guard manifest.schemaVersion == ContentSource.supportedSchemaVersion else {
                return .rejected(
                    reason: "content format \(manifest.schemaVersion) is newer than this app understands"
                )
            }
            guard ContentVersion.isNewer(manifest.contentVersion, than: localVersion) else {
                return manifest.contentVersion == localVersion
                    ? .upToDate(version: localVersion)
                    : .ignoredOlder(remote: manifest.contentVersion, local: localVersion)
            }

            guard
                let handbookFile = manifest.file(role: .handbook),
                let requirementsFile = manifest.file(role: .requirements),
                let pdfFile = manifest.file(role: .pdf)
            else {
                return .rejected(reason: "the manifest does not list all three content files")
            }

            let handbook = try await fetchVerified(handbookFile)
            let requirements = try await fetchVerified(requirementsFile)
            let pdf = try await fetchVerified(pdfFile)

            try store.install(handbook: handbook, requirements: requirements, pdf: pdf)
            return .updated(from: localVersion, to: manifest.contentVersion)
        } catch let error as ContentError {
            return .rejected(reason: error.localizedDescription)
        } catch let error as NetworkError {
            switch error {
            case .insecureURL:
                return .rejected(reason: error.localizedDescription)
            default:
                return .unreachable(reason: error.localizedDescription)
            }
        } catch {
            return .unreachable(reason: error.localizedDescription)
        }
    }

    private func fetchManifest() async throws -> ContentManifest {
        let data = try await fetch(manifestURL)
        do {
            return try JSONDecoder().decode(ContentManifest.self, from: data)
        } catch {
            throw ContentError.decodeFailed(file: "manifest.json")
        }
    }

    /// Downloads one file and refuses it unless its SHA-256 is exactly what the
    /// manifest published.
    private func fetchVerified(_ file: ContentManifest.File) async throws -> Data {
        let data = try await fetch(file.url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256.lowercased() else {
            throw ContentError.checksumMismatch(
                file: file.name, expected: file.sha256, actual: digest
            )
        }
        return data
    }

    private func fetch(_ url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else {
            throw NetworkError.insecureURL(url)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await network.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NetworkError.badStatus(http.statusCode)
        }
        return data
    }
}
