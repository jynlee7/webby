import Foundation

/// A provider-neutral credential that Webby may need from a user or proxy.
public enum CredentialKind: String, CaseIterable, Hashable, Sendable {
    case anthropicAPIKey
    case cartesiaAPIKey
    case cartesiaAccessToken
}

/// A secret and its optional expiry.
///
/// Deliberately not `Codable`: credentials are never written to disk as part of a
/// settings or conversation document. The descriptions redact the secret so it is
/// not exposed through logging or diagnostics.
public struct CredentialValue: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let secret: String
    public let expiresAt: Date?

    public init(secret: String, expiresAt: Date? = nil) {
        self.secret = secret
        self.expiresAt = expiresAt
    }

    public var description: String {
        let expiry = expiresAt.map { String(describing: $0) } ?? "nil"
        return "CredentialValue(secret: <redacted>, expiresAt: \(expiry))"
    }

    public var debugDescription: String {
        description
    }
}

/// Failures reported by a credential provider. The cases carry only the kind, so
/// an underlying Keychain or proxy error cannot leak a secret through its text.
public enum CredentialProviderError: Error, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case unavailable(CredentialKind)
    case denied(CredentialKind)
    case invalid(CredentialKind)

    public var description: String {
        switch self {
        case let .unavailable(kind):
            return "Credential unavailable for \(kind.rawValue)"
        case let .denied(kind):
            return "Credential access denied for \(kind.rawValue)"
        case let .invalid(kind):
            return "Credential invalid for \(kind.rawValue)"
        }
    }

    public var debugDescription: String {
        description
    }
}

/// Supplies credentials without committing callers to a storage mechanism.
public protocol CredentialProvider: Sendable {
    /// Returns the credential for `kind`, or `nil` when none has been stored.
    func credential(for kind: CredentialKind) async throws -> CredentialValue?
}
