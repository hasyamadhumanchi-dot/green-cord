import CryptoKit
import Foundation
import Testing
@testable import GreenCordHandbook

/// Gates C18 and C20: a content update is applied only when it is genuinely
/// newer and genuinely intact, and never costs a student their record.
@Suite("Content updating")
struct ContentUpdateTests {

    /// A network that serves a scripted set of URLs, or fails.
    final class StubNetwork: NetworkFetching, @unchecked Sendable {
        var responses: [String: Data] = [:]
        var statusCodes: [String: Int] = [:]
        var failEverything = false
        private(set) var requestedURLs: [String] = []

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let key = request.url?.absoluteString ?? ""
            requestedURLs.append(key)
            if failEverything {
                throw URLError(.notConnectedToInternet)
            }
            guard let body = responses[key] else {
                throw URLError(.fileDoesNotExist)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCodes[key] ?? 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (body, response)
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static let manifestURL = URL(string: "https://example.org/content/manifest.json")!

    /// A complete, valid payload at the given version.
    static func payload(version: String) throws -> (
        manifest: Data, handbook: Data, requirements: Data, pdf: Data
    ) {
        let bundle = Bundle(for: BundleToken.self)
        let handbookURL = try #require(bundle.url(forResource: "handbook", withExtension: "json"))
        let requirementsURL = try #require(
            bundle.url(forResource: "requirements", withExtension: "json")
        )
        let pdfURL = try #require(
            bundle.url(forResource: "PISDGreenCordHandbook", withExtension: "pdf")
        )

        var handbook = try JSONDecoder().decode(
            Handbook.self, from: Data(contentsOf: handbookURL)
        )
        handbook.contentVersion = version
        // A visible marker, so the test can prove the new copy is what loaded.
        handbook.sections[0].title = "UPDATED \(version)"
        let handbookData = try JSONEncoder().encode(handbook)
        let requirementsData = try Data(contentsOf: requirementsURL)
        let pdfData = try Data(contentsOf: pdfURL)

        let manifest = """
        {
          "schemaVersion": 1,
          "contentVersion": "\(version)",
          "publishedAt": "2026-09-20T00:00:00Z",
          "files": [
            {"role":"handbook","name":"handbook.json","url":"https://example.org/content/handbook.json","sha256":"\(sha256(handbookData))","bytes":\(handbookData.count)},
            {"role":"requirements","name":"requirements.json","url":"https://example.org/content/requirements.json","sha256":"\(sha256(requirementsData))","bytes":\(requirementsData.count)},
            {"role":"pdf","name":"PISDGreenCordHandbook.pdf","url":"https://example.org/content/PISDGreenCordHandbook.pdf","sha256":"\(sha256(pdfData))","bytes":\(pdfData.count)}
          ]
        }
        """
        return (Data(manifest.utf8), handbookData, requirementsData, pdfData)
    }

    static func makeStore() -> ContentStore {
        ContentStore(
            bundle: Bundle(for: BundleToken.self),
            cacheDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("update-tests-\(UUID().uuidString)")
        )
    }

    static func serve(_ network: StubNetwork, _ payload: (
        manifest: Data, handbook: Data, requirements: Data, pdf: Data
    )) {
        network.responses = [
            manifestURL.absoluteString: payload.manifest,
            "https://example.org/content/handbook.json": payload.handbook,
            "https://example.org/content/requirements.json": payload.requirements,
            "https://example.org/content/PISDGreenCordHandbook.pdf": payload.pdf,
        ]
    }

    // MARK: - Version comparison

    @Test("Version comparison, including malformed input")
    func versionComparison() {
        #expect(ContentVersion.isNewer("2026.09.01", than: "2026.08.21"))
        #expect(ContentVersion.isNewer("2027.01.01", than: "2026.12.31"))
        #expect(!ContentVersion.isNewer("2026.08.21", than: "2026.08.21"))
        #expect(!ContentVersion.isNewer("2026.08.01", than: "2026.08.21"))
        // A version the app cannot parse must never be treated as newer.
        #expect(!ContentVersion.isNewer("not-a-version", than: "2026.08.21"))
        #expect(!ContentVersion.isNewer("", than: "2026.08.21"))
        #expect(!ContentVersion.isNewer("2026.08", than: "2026.08.21"))
    }

    // MARK: - The three update outcomes

    @Test("C18a a newer version replaces the installed content")
    func newerVersionIsInstalled() async throws {
        let store = Self.makeStore()
        let network = StubNetwork()
        Self.serve(network, try Self.payload(version: "2027.01.15"))

        let before = store.load()
        #expect(before.origin == .bundled)

        let updater = ContentUpdater(
            store: store, network: network, manifestURL: Self.manifestURL
        )
        let outcome = await updater.checkForUpdate()

        guard case let .updated(from, to) = outcome else {
            Issue.record("expected .updated, got \(outcome)")
            return
        }
        #expect(from == before.contentVersion)
        #expect(to == "2027.01.15")

        let after = store.load()
        #expect(after.origin == .downloaded)
        #expect(after.contentVersion == "2027.01.15")
        #expect(after.handbook.sections[0].title == "UPDATED 2027.01.15")
        #expect(after.handbook.sections.count == before.handbook.sections.count)
    }

    @Test("C18b an equal or older version is ignored")
    func olderVersionIsIgnored() async throws {
        let store = Self.makeStore()
        let bundledVersion = store.bundledVersion()

        for version in ["2020.01.01", bundledVersion] {
            let network = StubNetwork()
            Self.serve(network, try Self.payload(version: version))
            let updater = ContentUpdater(
                store: store, network: network, manifestURL: Self.manifestURL
            )
            let outcome = await updater.checkForUpdate()

            switch outcome {
            case .ignoredOlder, .upToDate:
                break
            default:
                Issue.record("version \(version) should have been ignored, got \(outcome)")
            }
            #expect(store.load().origin == .bundled)
            #expect(store.load().contentVersion == bundledVersion)
            // Only the manifest is fetched; nothing else is downloaded.
            #expect(network.requestedURLs == [Self.manifestURL.absoluteString])
        }
    }

    @Test("C18c a checksum mismatch is rejected and the good copy is kept")
    func checksumMismatchIsRejected() async throws {
        let store = Self.makeStore()
        let network = StubNetwork()
        var payload = try Self.payload(version: "2027.02.01")
        Self.serve(network, payload)
        // Corrupt the handbook after the manifest's checksum was computed.
        payload.handbook = Data("{\"tampered\": true}".utf8)
        network.responses["https://example.org/content/handbook.json"] = payload.handbook

        let bundledVersion = store.bundledVersion()
        let updater = ContentUpdater(
            store: store, network: network, manifestURL: Self.manifestURL
        )
        let outcome = await updater.checkForUpdate()

        guard case let .rejected(reason) = outcome else {
            Issue.record("expected .rejected, got \(outcome)")
            return
        }
        #expect(reason.contains("checksum") || reason.contains("did not match"))
        #expect(store.load().origin == .bundled)
        #expect(store.load().contentVersion == bundledVersion)
    }

    @Test("C18c malformed JSON is rejected and the good copy is kept")
    func malformedContentIsRejected() async throws {
        let store = Self.makeStore()
        let network = StubNetwork()
        network.responses = [Self.manifestURL.absoluteString: Data("{ not json".utf8)]

        let bundledVersion = store.bundledVersion()
        let updater = ContentUpdater(
            store: store, network: network, manifestURL: Self.manifestURL
        )
        let outcome = await updater.checkForUpdate()

        guard case .rejected = outcome else {
            Issue.record("expected .rejected, got \(outcome)")
            return
        }
        #expect(store.load().contentVersion == bundledVersion)
    }

    @Test("A schema version the app does not understand is refused")
    func unknownSchemaIsRefused() async throws {
        let store = Self.makeStore()
        let network = StubNetwork()
        let manifest = """
        {"schemaVersion": 99, "contentVersion": "2099.01.01",
         "publishedAt": "2026-09-20T00:00:00Z", "files": []}
        """
        network.responses = [Self.manifestURL.absoluteString: Data(manifest.utf8)]

        let updater = ContentUpdater(
            store: store, network: network, manifestURL: Self.manifestURL
        )
        guard case let .rejected(reason) = await updater.checkForUpdate() else {
            Issue.record("a manifest with schemaVersion 99 should be rejected")
            return
        }
        #expect(reason.contains("99"))
        #expect(store.load().origin == .bundled)
    }

    @Test("C17 a plain-http manifest URL is refused outright")
    func insecureURLIsRefused() async throws {
        let store = Self.makeStore()
        let network = StubNetwork()
        let insecure = URL(string: "http://example.org/content/manifest.json")!
        network.responses = [insecure.absoluteString: Data("{}".utf8)]

        let updater = ContentUpdater(store: store, network: network, manifestURL: insecure)
        guard case let .rejected(reason) = await updater.checkForUpdate() else {
            Issue.record("a plain-http manifest should be refused")
            return
        }
        #expect(reason.lowercased().contains("https"))
        // The request must not have been made at all.
        #expect(network.requestedURLs.isEmpty)
    }

    // MARK: - Offline

    @Test("C19 with no network at all, the handbook is still fully readable")
    func offlineStillReads() async throws {
        let store = Self.makeStore()
        let network = StubNetwork()
        network.failEverything = true

        let updater = ContentUpdater(
            store: store, network: network, manifestURL: Self.manifestURL
        )
        guard case .unreachable = await updater.checkForUpdate() else {
            Issue.record("a dead network should report .unreachable, not an error state")
            return
        }

        // Everything a reader needs is still there.
        let content = store.load()
        #expect(content.handbook.sections.count == 30)
        #expect(content.handbook.pageCount == 20)
        #expect(FileManager.default.fileExists(atPath: content.pdfURL.path))
        #expect(content.requirements.grades.count == 4)

        let index = SearchIndex(handbook: content.handbook)
        #expect(!index.search("Silver Service Distinction").isEmpty)
    }

    // MARK: - User data survives an update

    @Test("C20 a content update does not disturb a student's entries")
    func updateKeepsEntries() async throws {
        let store = Self.makeStore()
        let network = StubNetwork()
        Self.serve(network, try Self.payload(version: "2027.03.01"))

        // The record a student has built up, held independently of content.
        let entries = [
            RequirementsTests.entry(12, .approved),
            RequirementsTests.entry(6, .submitted),
        ]
        let before = ProgressCalculator.summarise(
            entries: entries, grade: 9, requirements: store.load().requirements
        )

        let updater = ContentUpdater(
            store: store, network: network, manifestURL: Self.manifestURL
        )
        guard case .updated = await updater.checkForUpdate() else {
            Issue.record("the update should have applied")
            return
        }

        let after = ProgressCalculator.summarise(
            entries: entries, grade: 9, requirements: store.load().requirements
        )
        #expect(after.verifiedHours == before.verifiedHours)
        #expect(after.pendingHours == before.pendingHours)
        #expect(after.thresholdHours == before.thresholdHours)
    }

    @Test("C20 a requirement id that disappears does not crash anything")
    func renamedRequirementIsSafe() throws {
        let requirements = try RequirementsTests.loadRequirements()
        let known = Set(requirements.checklist.map(\.id))

        // Checklist state saved against an id the new content no longer has.
        let stale = ["membership-fee": true, "a-requirement-that-was-renamed": true]
        let rendered = requirements.checklist(forGrade: 9).map { requirement in
            ChecklistItem(
                id: requirement.id,
                title: requirement.title,
                page: requirement.page,
                checked: stale[requirement.id] ?? false
            )
        }

        #expect(!rendered.isEmpty)
        #expect(rendered.allSatisfy { known.contains($0.id) })
        #expect(rendered.first { $0.id == "membership-fee" }?.checked == true)
        // The unknown id is simply not shown. It is not an error.
        #expect(!rendered.contains { $0.id == "a-requirement-that-was-renamed" })
    }
}
