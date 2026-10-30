import Foundation
import Testing
@testable import WebbyCore

private struct StubCredentialProvider: CredentialProvider {
    let values: [CredentialKind: CredentialValue]
    let failure: CredentialProviderError?

    init(values: [CredentialKind: CredentialValue] = [:], failure: CredentialProviderError? = nil) {
        self.values = values
        self.failure = failure
    }

    func credential(for kind: CredentialKind) async throws -> CredentialValue? {
        if let failure {
            throw failure
        }
        return values[kind]
    }
}

@Test func credentialKindsAreProviderNeutral() {
    #expect(CredentialKind.allCases == [
        .anthropicAPIKey,
        .cartesiaAPIKey,
        .cartesiaAccessToken,
    ])
}

@Test func providerReturnsValueExpiryAndMissingCredential() async throws {
    let expiry = Date(timeIntervalSince1970: 1_800_000_000)
    let provider = StubCredentialProvider(values: [
        .anthropicAPIKey: CredentialValue(secret: "key", expiresAt: expiry),
    ])

    let value = try await provider.credential(for: .anthropicAPIKey)
    #expect(value?.secret == "key")
    #expect(value?.expiresAt == expiry)
    #expect(try await provider.credential(for: .cartesiaAPIKey) == nil)
}

@Test func credentialValueIsNotCodableAndRedactsDescriptions() {
    let secret = "sentinel-credential-secret"
    let value = CredentialValue(secret: secret, expiresAt: nil)

    #expect(!(value is any Encodable))
    #expect(!String(describing: value).contains(secret))
    #expect(!String(reflecting: value).contains(secret))
    #expect(!value.description.contains(secret))
    #expect(!value.debugDescription.contains(secret))
}

@Test func providerFailureDescriptionIsSanitized() {
    let failure = CredentialProviderError.denied(.cartesiaAccessToken)

    #expect(!failure.description.contains("secret"))
    #expect(!failure.debugDescription.contains("secret"))
    #expect(failure.description.contains(CredentialKind.cartesiaAccessToken.rawValue))
}
