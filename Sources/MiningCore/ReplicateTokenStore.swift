import Foundation
import Security

public struct ReplicateTokenStore: Sendable {
    private let service: String
    public init(service: String = "io.antoine.vg-sentence-mining.replicate") { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "api-token", kSecAttrSynchronizable as String: false]
    }

    public func load() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw MiningError.message("Could not read the Replicate key from Keychain.")
        }
        return token
    }

    public func save(_ token: String) throws {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw MiningError.message("Enter your Replicate API key.") }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw MiningError.message("Could not save the Replicate key in Keychain.")
            }
        } else if status != errSecSuccess {
            throw MiningError.message("Could not update the Replicate key in Keychain.")
        }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MiningError.message("Could not remove the Replicate key from Keychain.")
        }
    }
}
