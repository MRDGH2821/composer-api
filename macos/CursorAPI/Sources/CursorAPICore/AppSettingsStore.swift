import Foundation
import LocalAuthentication
import Security

public enum AppSettingsStoreError: Error, LocalizedError, Equatable {
    case keychainPermissionRequired
    case missingCursorAPIKey

    public var errorDescription: String? {
        switch self {
        case .keychainPermissionRequired:
            return "macOS needs permission before CursorAPI can read the saved API key from Keychain."
        case .missingCursorAPIKey:
            return "Enter a Cursor API key to start the local API."
        }
    }
}

public final class AppSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "CursorAPI.settings.v1"
    private let queue = DispatchQueue(label: "CursorAPI.AppSettingsStore")

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> CursorAPISettings {
        queue.sync {
            if let data = defaults.data(forKey: key),
               var value = try? JSONDecoder().decode(CursorAPISettings.self, from: data) {
                applyEnvironmentDefaults(to: &value, onlyWhenMissing: true)
                value.keychainCursorAPIKeyAvailable = value.hasInlineCursorAPIKey || keychainAPIKeyExists()
                return value
            }
            var value = CursorAPISettings()
            applyEnvironmentDefaults(to: &value, onlyWhenMissing: false)
            value.keychainCursorAPIKeyAvailable = value.hasInlineCursorAPIKey || keychainAPIKeyExists()
            return value
        }
    }

    public func save(_ settings: CursorAPISettings) {
        queue.sync {
            if settings.hasInlineCursorAPIKey {
                saveKeychainAPIKey(settings.cursorAPIKey)
            } else if !settings.keychainCursorAPIKeyAvailable {
                deleteKeychainAPIKey()
            }
            var persisted = settings
            persisted.cursorAPIKey = ""
            persisted.keychainCursorAPIKeyAvailable = false
            if let data = try? JSONEncoder.cursorAPIPretty.encode(persisted) {
                defaults.set(data, forKey: key)
            }
        }
    }

    public func resolvingCursorAPIKey(in settings: CursorAPISettings, allowUserPrompt: Bool) throws -> CursorAPISettings {
        try queue.sync {
            if settings.hasInlineCursorAPIKey {
                return settings
            }
            guard settings.keychainCursorAPIKeyAvailable || keychainAPIKeyExists() else {
                throw AppSettingsStoreError.missingCursorAPIKey
            }
            var resolved = settings
            resolved.cursorAPIKey = try readKeychainAPIKey(allowUserPrompt: allowUserPrompt)
            resolved.keychainCursorAPIKeyAvailable = true
            return resolved
        }
    }

    private func applyEnvironmentDefaults(to value: inout CursorAPISettings, onlyWhenMissing: Bool) {
        let env = ProcessInfo.processInfo.environment
        if (!onlyWhenMissing || value.port == 8787), let envPort = env["CURSOR_API_PORT"], let port = UInt16(envPort) {
            value.port = port
        }
        if !onlyWhenMissing || value.cursorAPIKey.isEmpty {
            value.cursorAPIKey = env["CURSOR_API_KEY"] ?? value.cursorAPIKey
        }
        if !onlyWhenMissing || value.cursorAPIBaseURL.isEmpty || value.cursorAPIBaseURL == "https://api.cursor.com" {
            value.cursorAPIBaseURL = env["CURSOR_API_BASE"] ?? value.cursorAPIBaseURL
        }
        if !onlyWhenMissing || value.backendBaseURL.isEmpty {
            value.backendBaseURL = env["CURSOR_BACKEND_BASE_URL"] ?? value.backendBaseURL
        }
        if !onlyWhenMissing || value.localAgentEndpoint.isEmpty {
            value.localAgentEndpoint = env["CURSOR_LOCAL_AGENT_ENDPOINT"] ?? value.localAgentEndpoint
        }
        if !onlyWhenMissing || value.clientVersion.isEmpty || value.clientVersion == "sdk-1.0.13" {
            value.clientVersion = env["CURSOR_SDK_CLIENT_VERSION"] ?? value.clientVersion
        }
    }

    private func keychainAPIKeyExists() -> Bool {
        var query = keychainQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = keychainContext(allowUserPrompt: false)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    private func readKeychainAPIKey(allowUserPrompt: Bool) throws -> String {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = keychainContext(allowUserPrompt: allowUserPrompt)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecInteractionNotAllowed {
            throw AppSettingsStoreError.keychainPermissionRequired
        }
        if !allowUserPrompt, status != errSecSuccess, status != errSecItemNotFound {
            throw AppSettingsStoreError.keychainPermissionRequired
        }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw AppSettingsStoreError.missingCursorAPIKey
        }
        return value
    }

    private func saveKeychainAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var query = keychainQuery()
        if trimmed.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(trimmed.utf8)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            query[kSecValueData as String] = data
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    private func deleteKeychainAPIKey() {
        SecItemDelete(keychainQuery() as CFDictionary)
    }

    private func keychainContext(allowUserPrompt: Bool) -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = !allowUserPrompt
        return context
    }

    private func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ai.standardagents.cursorapi",
            kSecAttrAccount as String: "cursor-api-key"
        ]
    }
}
