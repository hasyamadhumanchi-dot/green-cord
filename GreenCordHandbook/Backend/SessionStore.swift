import Foundation
import Security

/// Keeps the signed-in session across launches.
///
/// The app is gated behind sign-in, so without this a student would be sent
/// back to the welcome screen every time they opened it - and, with no
/// connection, would have no way back in. That would undo the offline promise:
/// hours logged on a bus with no signal are only useful if the app opens.
///
/// The token lives in the keychain rather than in UserDefaults because it is a
/// credential. Nothing here is required for correctness: every read tolerates an
/// empty or unreadable store and reports no session, which sends the student to
/// the welcome screen - inconvenient, never wrong.
struct SessionStore {
    private let service: String
    private let account = "session"

    init(service: String = "net.princetonisd.pshs.greencord.session") {
        self.service = service
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func save(_ session: Session) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        // Not synchronised to iCloud and not readable until the device has been
        // unlocked once: a school record should not ride along to other devices.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func load() -> Session? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard
            SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    func clear() {
        SecItemDelete(query as CFDictionary)
    }
}
