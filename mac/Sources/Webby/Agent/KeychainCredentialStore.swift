import Foundation
import Security
import WebbyCore

/// Where secrets are kept. Production uses the login Keychain; tests inject memory.
protocol SecretStorage: Sendable {
    func read(account: String) throws -> String?
    func write(_ secret: String, account: String) throws
    func delete(account: String) throws
}

enum SecretStorageError: Error, Equatable {
    case denied
    case failed(OSStatus)
}

/// Generic passwords in the login Keychain (plan §6.4: service = bundle ID).
///
/// The service is the approved bundle ID `io.github.jynlee7.webby`, so the stored key
/// does not have to move when `Webby.bundleID` changes to it in Step 10.
struct KeychainSecretStorage: SecretStorage {
    static let service = "io.github.jynlee7.webby"

    let service: String

    init(service: String = KeychainSecretStorage.service) {
        self.service = service
    }

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read(account: String) throws -> String? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw Self.error(status)
        }
    }

    func write(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let update = SecItemUpdate(
            query(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Self.error(update) }
        var item = query(account: account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        item[kSecAttrLabel as String] = "Webby \(account) key"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.error(status) }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status) }
    }

    private static func error(_ status: OSStatus) -> SecretStorageError {
        switch status {
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            return .denied
        default:
            return .failed(status)
        }
    }
}

/// The Keychain-backed implementation of #24's `CredentialProvider` for the
/// Anthropic key. Secrets are never written to `settings.json` or logs; errors carry
/// only the credential kind.
struct KeychainCredentialStore: CredentialProvider {
    let storage: any SecretStorage

    init(storage: any SecretStorage = KeychainSecretStorage()) {
        self.storage = storage
    }

    /// Keychain accounts from plan §6.4. Short-lived access tokens are never stored.
    static func account(for kind: CredentialKind) -> String? {
        switch kind {
        case .anthropicAPIKey: return "anthropic"
        case .cartesiaAPIKey: return "cartesia"
        case .cartesiaAccessToken: return nil
        }
    }

    func credential(for kind: CredentialKind) async throws -> CredentialValue? {
        try storedValue(for: kind)
    }

    func storedValue(for kind: CredentialKind) throws -> CredentialValue? {
        guard let account = Self.account(for: kind) else { return nil }
        do {
            guard let secret = try storage.read(account: account), !secret.isEmpty else { return nil }
            return CredentialValue(secret: secret)
        } catch SecretStorageError.denied {
            throw CredentialProviderError.denied(kind)
        } catch {
            throw CredentialProviderError.unavailable(kind)
        }
    }

    /// Stores a pasted key, trimmed. A key with spaces or line breaks inside is
    /// rejected rather than stored, because it can't be a valid header value.
    func save(_ text: String, for kind: CredentialKind) throws {
        guard let account = Self.account(for: kind) else { throw CredentialProviderError.invalid(kind) }
        let secret = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty,
              secret.count <= 512,
              !secret.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else { throw CredentialProviderError.invalid(kind) }
        do {
            try storage.write(secret, account: account)
        } catch SecretStorageError.denied {
            throw CredentialProviderError.denied(kind)
        } catch {
            throw CredentialProviderError.unavailable(kind)
        }
    }

    func remove(_ kind: CredentialKind) throws {
        guard let account = Self.account(for: kind) else { return }
        do {
            try storage.delete(account: account)
        } catch {
            throw CredentialProviderError.unavailable(kind)
        }
    }
}
