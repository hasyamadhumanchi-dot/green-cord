import Foundation

/// Talks to the Green Cord server over HTTPS.
///
/// Plain HTTP is refused before a request is ever made, so a misconfigured base
/// URL fails loudly rather than sending a student's record in the clear.
final class RemoteAPI: GreenCordAPI, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Transport

    private func send<Body: Encodable>(
        _ method: String,
        _ path: String,
        token: String? = nil,
        body: Body?,
        query: [URLQueryItem] = []
    ) async throws -> Data {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError(status: 0, code: "bad_url", message: "The server address is not valid.")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw APIError(status: 0, code: "bad_url", message: "The server address is not valid.")
        }
        guard url.scheme?.lowercased() == "https" else {
            throw APIError(
                status: 0, code: "insecure",
                message: "The app only talks to the server over https."
            )
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.timeoutInterval = 20
        if let token {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try encoder.encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw APIError.offline
        }

        guard let http = response as? HTTPURLResponse else { throw APIError.offline }
        guard (200..<300).contains(http.statusCode) else {
            let payload = try? decoder.decode(ServerError.self, from: data)
            throw APIError(
                status: http.statusCode,
                code: payload?.code ?? "error",
                message: payload?.error ?? "The server could not complete that request."
            )
        }
        return data
    }

    /// A request with no body. `Empty` only exists to give the generic a type.
    private struct Empty: Encodable {}

    private func send(
        _ method: String, _ path: String,
        token: String? = nil, query: [URLQueryItem] = []
    ) async throws -> Data {
        try await send(method, path, token: token, body: Optional<Empty>.none, query: query)
    }

    /// The server wraps every response in a single named key: `{"entry": {...}}`,
    /// `{"students": [...]}`. Lift that one value out, then decode it.
    private func unwrap<T: Decodable>(_ type: T.Type, _ data: Data, key: String) throws -> T {
        do {
            guard
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let inner = object[key]
            else {
                throw APIError(
                    status: 0, code: "bad_response",
                    message: "The server sent something the app did not expect."
                )
            }
            let innerData = try JSONSerialization.data(
                withJSONObject: inner, options: [.fragmentsAllowed]
            )
            return try decoder.decode(T.self, from: innerData)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError(
                status: 0, code: "bad_response",
                message: "The server sent something the app did not expect."
            )
        }
    }

    private struct ServerError: Decodable {
        let error: String
        let code: String
    }

    // MARK: - Request bodies

    private struct RedeemBody: Encodable {
        let code: String
        let username: String
        let password: String
    }

    private struct SignInBody: Encodable {
        let username: String
        let password: String
    }

    private struct EntryBody: Encodable {
        let serviceDate: String
        let hours: Double
        let category: String
        let organization: String
        let description: String
        let verifierName: String
        let verifierContact: String
        let evidenceURL: String?
        let studentId: String?

        init(draft: EntryDraft, studentId: String? = nil) {
            serviceDate = draft.serviceDate
            hours = draft.hours
            category = draft.category
            organization = draft.organization
            description = draft.description
            verifierName = draft.verifierName
            verifierContact = draft.verifierContact
            evidenceURL = draft.evidenceURL
            self.studentId = studentId
        }
    }

    private struct DecisionBody: Encodable {
        let action: String
        let note: String
    }

    private struct CodeBatchBody: Encodable {
        let students: [NewStudent]
    }

    private struct CheckedBody: Encodable {
        let checked: Bool
    }

    // MARK: - Auth

    func lookupCode(code: String) async throws -> CodeHolder {
        let data = try await send(
            "GET", "invite-codes/lookup",
            query: [URLQueryItem(name: "code", value: code)]
        )
        return try decoder.decode(CodeHolder.self, from: data)
    }

    func redeem(code: String, username: String, password: String) async throws -> Session {
        let data = try await send("POST", "auth/redeem", body: RedeemBody(
            code: code, username: username, password: password
        ))
        return try decoder.decode(Session.self, from: data)
    }

    func signIn(username: String, password: String) async throws -> Session {
        let data = try await send(
            "POST", "auth/login", body: SignInBody(username: username, password: password)
        )
        return try decoder.decode(Session.self, from: data)
    }

    func signOut(token: String) async throws {
        _ = try await send("POST", "auth/logout", token: token)
    }

    func account(token: String) async throws -> Account {
        try unwrap(Account.self, try await send("GET", "me", token: token), key: "account")
    }

    func deleteAccount(token: String) async throws {
        _ = try await send("DELETE", "me", token: token)
    }

    // MARK: - Entries

    func entries(token: String) async throws -> [HourEntry] {
        try await entries(token: token, studentId: nil, status: nil)
    }

    func entries(token: String, studentId: String?, status: String?) async throws -> [HourEntry] {
        var query: [URLQueryItem] = []
        if let studentId { query.append(URLQueryItem(name: "studentId", value: studentId)) }
        if let status { query.append(URLQueryItem(name: "status", value: status)) }
        let data = try await send("GET", "entries", token: token, query: query)
        return try unwrap([HourEntry].self, data, key: "entries")
    }

    func createEntry(token: String, draft: EntryDraft, studentId: String?) async throws -> HourEntry {
        let data = try await send(
            "POST", "entries", token: token, body: EntryBody(draft: draft, studentId: studentId)
        )
        return try unwrap(HourEntry.self, data, key: "entry")
    }

    func updateEntry(token: String, id: String, changes: EntryDraft) async throws -> HourEntry {
        let data = try await send(
            "PATCH", "entries/\(id)", token: token, body: EntryBody(draft: changes)
        )
        return try unwrap(HourEntry.self, data, key: "entry")
    }

    func deleteEntry(token: String, id: String) async throws {
        _ = try await send("DELETE", "entries/\(id)", token: token)
    }

    func submitEntry(token: String, id: String) async throws -> HourEntry {
        let data = try await send("POST", "entries/\(id)/submit", token: token)
        return try unwrap(HourEntry.self, data, key: "entry")
    }

    func decideEntry(
        token: String, id: String, action: ReviewAction, note: String
    ) async throws -> HourEntry {
        let data = try await send(
            "POST", "entries/\(id)/decision", token: token,
            body: DecisionBody(action: action.rawValue, note: note)
        )
        return try unwrap(HourEntry.self, data, key: "entry")
    }

    func history(token: String, entryId: String) async throws -> [AuditEvent] {
        let data = try await send("GET", "entries/\(entryId)/history", token: token)
        return try unwrap([AuditEvent].self, data, key: "history")
    }

    // MARK: - Progress and roster

    func progress(token: String) async throws -> ServerProgress {
        let data = try await send("GET", "progress", token: token)
        return try unwrap(ServerProgress.self, data, key: "progress")
    }

    func roster(
        token: String, grade: Int?, letterFrom: String?, letterTo: String?
    ) async throws -> [RosterRow] {
        let data = try await send(
            "GET", "roster", token: token, query: rosterQuery(grade, letterFrom, letterTo)
        )
        return try unwrap([RosterRow].self, data, key: "students")
    }

    func rosterCSV(
        token: String, grade: Int?, letterFrom: String?, letterTo: String?
    ) async throws -> String {
        let data = try await send(
            "GET", "roster.csv", token: token, query: rosterQuery(grade, letterFrom, letterTo)
        )
        return String(decoding: data, as: UTF8.self)
    }

    func exportCSV(token: String) async throws -> String {
        let data = try await send("GET", "export.csv", token: token)
        return String(decoding: data, as: UTF8.self)
    }

    private func rosterQuery(_ grade: Int?, _ from: String?, _ to: String?) -> [URLQueryItem] {
        var query: [URLQueryItem] = []
        if let grade { query.append(URLQueryItem(name: "grade", value: String(grade))) }
        if let from, !from.isEmpty { query.append(URLQueryItem(name: "letterFrom", value: from)) }
        if let to, !to.isEmpty { query.append(URLQueryItem(name: "letterTo", value: to)) }
        return query
    }

    // MARK: - Invite codes

    func inviteCodes(token: String) async throws -> [InviteCode] {
        let data = try await send("GET", "invite-codes", token: token)
        return try unwrap([InviteCode].self, data, key: "codes")
    }

    func createInviteCodes(
        token: String, students: [NewStudent]
    ) async throws -> [InviteCode] {
        let data = try await send(
            "POST", "invite-codes", token: token, body: CodeBatchBody(students: students)
        )
        return try unwrap([InviteCode].self, data, key: "codes")
    }

    func revokeInviteCode(token: String, code: String) async throws {
        _ = try await send("DELETE", "invite-codes/\(code)", token: token)
    }

    // MARK: - Staff

    private struct InviteStaffBody: Encodable {
        let firstName: String
        let lastName: String
        let role: String
    }

    private struct RoleBody: Encodable {
        let role: String
    }

    private struct ResetRequestBody: Encodable {
        let accountId: String
    }

    private struct ResetBody: Encodable {
        let code: String
        let password: String
    }

    func staff(token: String) async throws -> StaffList {
        let data = try await send("GET", "staff", token: token)
        return try decoder.decode(StaffList.self, from: data)
    }

    func inviteStaff(
        token: String, firstName: String, lastName: String, role: Account.Role
    ) async throws -> PendingStaffInvite {
        let data = try await send(
            "POST", "staff/invites", token: token,
            body: InviteStaffBody(
                firstName: firstName, lastName: lastName, role: role.rawValue
            )
        )
        return try decoder.decode(PendingStaffInvite.self, from: data)
    }

    func setStaffRole(
        token: String, id: String, role: Account.Role
    ) async throws -> StaffMember {
        let data = try await send(
            "POST", "staff/\(id)/role", token: token, body: RoleBody(role: role.rawValue)
        )
        return try unwrap(StaffMember.self, data, key: "staff")
    }

    func removeStaff(token: String, id: String) async throws {
        _ = try await send("DELETE", "staff/\(id)", token: token)
    }

    func issuePasswordReset(token: String, accountId: String) async throws -> PasswordReset {
        let data = try await send(
            "POST", "password-resets", token: token,
            body: ResetRequestBody(accountId: accountId)
        )
        return try decoder.decode(PasswordReset.self, from: data)
    }

    func resetPassword(code: String, password: String) async throws {
        _ = try await send(
            "POST", "auth/reset", body: ResetBody(code: code, password: password)
        )
    }

    // MARK: - Checklist

    func checklist(token: String) async throws -> [ChecklistItem] {
        let data = try await send("GET", "checklist", token: token)
        return try unwrap([ChecklistItem].self, data, key: "items")
    }

    func setChecklist(token: String, itemId: String, checked: Bool) async throws {
        _ = try await send(
            "PUT", "checklist/\(itemId)", token: token, body: CheckedBody(checked: checked)
        )
    }
}

