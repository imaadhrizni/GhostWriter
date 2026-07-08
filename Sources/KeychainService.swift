import Security
import Foundation

// MARK: - Keychain Service

/// Reads and writes secrets to the macOS Keychain.
/// The Groq API key never touches disk as plaintext — only Keychain secure storage.
enum KeychainService {

    private static let service = "com.voiceeee.groq-api-key"
    private static let account = "voiceeee"

    // MARK: - Read

    /// Retrieve the Groq API key from Keychain.
    /// Falls back to the GROQ_API_KEY environment variable for local dev convenience.
    static func groqAPIKey() -> String? {
        // 1. Try Keychain first
        if let key = readFromKeychain() {
            return key
        }
        // 2. Dev fallback: environment variable
        let envKey = ProcessInfo.processInfo.environment["GROQ_API_KEY"]
        return envKey?.isEmpty == false ? envKey : nil
    }

    // MARK: - Private

    private static func readFromKeychain() -> String? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      account,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    /// Write (or overwrite) an API key into Keychain.
    @discardableResult
    static func saveGroqAPIKey(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }

        // Try update first
        let updateQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let updateAttrs: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)

        if updateStatus == errSecSuccess { return true }

        // Not found — add new
        let addQuery: [CFString: Any] = [
            kSecClass:             kSecClassGenericPassword,
            kSecAttrService:       service,
            kSecAttrAccount:       account,
            kSecValueData:         data,
            kSecAttrAccessible:    kSecAttrAccessibleWhenUnlocked
        ]
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }
}
