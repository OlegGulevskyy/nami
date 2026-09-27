import Foundation
import Security

/// Injected separately from the workspace so credentials never enter JSON or reports.
@MainActor struct ComparisonAPIKeyStore {
    var load: () throws -> String?
    var save: (String) throws -> Void

    static func keychain(account: String) -> Self {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.nami.studio.elevenlabs",
            kSecAttrAccount as String: account,
        ]
        return Self(load: {
            var request = query
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            try check(status)
            guard let data = result as? Data, let key = try? JSONDecoder().decode(String.self, from: data) else {
                throw StudioError.message("The saved ElevenLabs API key could not be read.")
            }
            return key
        }, save: { key in
            // Encode even an empty key as nonempty data: Keychain can ignore zero-byte updates.
            // This also remembers an explicit clear when an environment key exists.
            let attributes = [kSecValueData as String: try JSONEncoder().encode(key)]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item.merge(attributes) { _, new in new }
                try check(SecItemAdd(item as CFDictionary, nil))
            } else {
                try check(status)
            }
        })
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw StudioError.message("Keychain access failed (status \(status)).")
        }
    }
}
