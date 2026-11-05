import Foundation
import Testing
@testable import Webby
import WebbyAgent
import WebbyCore

/// Memory-only storage, so no test touches the real Keychain.
private final class MemorySecretStorage: SecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    var failure: SecretStorageError?

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func read(account: String) throws -> String? {
        try locked {
            if let failure { throw failure }
            return values[account]
        }
    }

    func write(_ secret: String, account: String) throws {
        try locked {
            if let failure { throw failure }
            values[account] = secret
        }
    }

    func delete(account: String) throws {
        try locked {
            if let failure { throw failure }
            values[account] = nil
        }
    }

    var accounts: [String: String] { locked { values } }
}

@Suite struct KeychainCredentialStoreTests {
    @Test func savesReadsAndRemovesTheAnthropicKeyUnderItsAccount() async throws {
        let storage = MemorySecretStorage()
        let store = KeychainCredentialStore(storage: storage)

        #expect(try await store.credential(for: .anthropicAPIKey) == nil)
        try store.save("  sk-ant-synthetic-key \n", for: .anthropicAPIKey)
        #expect(storage.accounts == ["anthropic": "sk-ant-synthetic-key"])
        #expect(try await store.credential(for: .anthropicAPIKey) == CredentialValue(secret: "sk-ant-synthetic-key"))
        #expect(try await store.credential(for: .cartesiaAPIKey) == nil)

        try store.remove(.anthropicAPIKey)
        #expect(try await store.credential(for: .anthropicAPIKey) == nil)
        #expect(storage.accounts.isEmpty)
    }

    @Test func rejectsEmptyOrBrokenKeysWithoutStoringThem() {
        let storage = MemorySecretStorage()
        let store = KeychainCredentialStore(storage: storage)

        #expect(throws: CredentialProviderError.invalid(.anthropicAPIKey)) { try store.save("   ", for: .anthropicAPIKey) }
        #expect(throws: CredentialProviderError.invalid(.anthropicAPIKey)) { try store.save("sk-ant one", for: .anthropicAPIKey) }
        #expect(throws: CredentialProviderError.invalid(.cartesiaAccessToken)) { try store.save("token", for: .cartesiaAccessToken) }
        #expect(storage.accounts.isEmpty)
    }

    @Test func storageFailuresSurfaceOnlyTheCredentialKind() async {
        let storage = MemorySecretStorage()
        let store = KeychainCredentialStore(storage: storage)

        storage.failure = .denied
        await #expect(throws: CredentialProviderError.denied(.anthropicAPIKey)) {
            try await store.credential(for: .anthropicAPIKey)
        }
        storage.failure = .failed(-25_300)
        await #expect(throws: CredentialProviderError.unavailable(.anthropicAPIKey)) {
            try await store.credential(for: .anthropicAPIKey)
        }
        #expect(throws: CredentialProviderError.unavailable(.anthropicAPIKey)) {
            try store.save("sk-ant-synthetic", for: .anthropicAPIKey)
        }
    }

    @Test func theKeyedTransportHidesTheKeyFromReflection() {
        let transport = KeyedClaudeTransport(base: KeychainCredentialStoreTests.NullTransport(), apiKey: "sk-ant-SENTINEL")
        var dumped = ""
        dump(transport, to: &dumped)
        #expect(!dumped.contains("SENTINEL"))
        #expect(KeychainSecretStorage.service == "io.github.jynlee7.webby")
        #expect(KeychainCredentialStore.account(for: .anthropicAPIKey) == "anthropic")
    }

    struct NullTransport: ClaudeTransport {
        func stream(_ request: PreparedRequest) -> AsyncThrowingStream<Data, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }
}
