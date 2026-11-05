import Foundation
import WebbyAgent
import WebbyCore

/// Adds the Anthropic key to each request just before it reaches the transport.
///
/// `ClaudeConversationRunner` prepares requests without a key, so the key is fetched
/// once through the credential seam when a turn starts and lives only as long as the
/// turn's transport. Reflection is empty so the key can't reach a log through `dump`.
struct KeyedClaudeTransport: ClaudeTransport, CustomReflectable {
    static let headerName = "x-api-key"

    let base: any ClaudeTransport
    private let apiKey: String

    init(base: any ClaudeTransport, apiKey: String) {
        self.base = base
        self.apiKey = apiKey
    }

    var customMirror: Mirror { Mirror(self, children: [:]) }

    func stream(_ request: PreparedRequest) -> AsyncThrowingStream<Data, Error> {
        var headers = request.headers.filter { $0.name.lowercased() != Self.headerName }
        headers.append(PreparedRequest.Header(name: Self.headerName, value: apiKey))
        headers.sort { $0.name < $1.name }
        return base.stream(PreparedRequest(
            url: request.url,
            method: request.method,
            headers: headers,
            body: request.body
        ))
    }
}

/// The model setting. An empty stored value means the reviewed model that #24 pinned
/// in `ClaudeConfiguration`, so the default follows that one constant instead of a
/// second copy of a model name.
enum AgentModelSetting {
    static var pinnedDefault: String {
        ClaudeConfiguration.pendingLiveDocVerification.model
    }

    static func resolve(_ stored: String) -> String {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? pinnedDefault : trimmed
    }

    /// Returns a problem to show, or nil when `text` can be stored. Empty is allowed
    /// and means the default.
    static func problem(with text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= 100 else { return "Model IDs are at most 100 characters." }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._:@"))
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII }) else {
            return "Use the model ID exactly as Anthropic lists it, such as \(pinnedDefault)."
        }
        return nil
    }

    /// The fixed request parameters for a new typed conversation: #24's pinned
    /// configuration with the chosen model and the context the conversation started in.
    static func configuration(model: String, context: Context) -> ClaudeConfiguration {
        var configuration = ClaudeConfiguration.pendingLiveDocVerification
        configuration.model = model
        configuration.tieringContext = context
        return configuration
    }
}

/// How a citation chip is marked, from the live note compared with what was sent.
enum AgentCitationMark: Equatable, Sendable {
    case current
    case editedSince
    case noteDeleted
    case nowExcluded

    var label: String? {
        switch self {
        case .current: return nil
        case .editedSince: return "edited since"
        case .noteDeleted: return "note deleted"
        case .nowExcluded: return "now excluded"
        }
    }

    /// Same order as `CitationValidator`: missing or trashed reads as deleted, then
    /// exclusion, then a newer revision. A stored redaction always wins.
    static func classify(_ citation: CitationValidator.Citation, live: Note?) -> AgentCitationMark {
        if citation.status == .deleted { return .noteDeleted }
        guard let live, live.trashedAt == nil else { return .noteDeleted }
        if live.excludedFromAgent { return .nowExcluded }
        if live.revision != citation.revision { return .editedSince }
        return .current
    }
}

/// Text shown for a failed turn. Errors carry no note text or credential, so these
/// strings never include either.
enum AgentErrorMessage {
    static let notesChanged = "Your notes changed while this answer was running (a note was trashed, deleted, kept away from AI, moved or imported), so it stopped. Retry to ask with the current notes."

    static func text(for error: any Error) -> String {
        switch error {
        case let error as ClaudeClientError:
            return text(for: error)
        case let error as ClaudeTransportError:
            return text(for: ClaudeClientError.transport(error))
        case let error as ClaudeConversationError:
            switch error {
            case .authorizationInvalidated:
                return notesChanged
            case .toolRoundLimitExceeded:
                return "The model asked to read too many notes for one answer. Retry, or ask a narrower question."
            default:
                return "The answer stopped unexpectedly. Retry to ask again."
            }
        case is CredentialProviderError:
            return "Webby couldn't read your Anthropic key from the Keychain. Check it in Settings → AI."
        default:
            return "The answer stopped unexpectedly. Retry to ask again."
        }
    }

    private static func text(for error: ClaudeClientError) -> String {
        switch error {
        case .transport(.httpStatus(let status)) where status == 401 || status == 403:
            return "Anthropic didn't accept the key. Check it in Settings → AI."
        case .transport(.httpStatus(400)):
            return "Anthropic couldn't process this request (HTTP 400). Check the model in Settings → AI, or start a new conversation."
        case .transport(.httpStatus(404)):
            return "Anthropic doesn't know this model (HTTP 404). Check the model in Settings → AI."
        case .transport(.httpStatus(let status)):
            return "Anthropic returned an error (HTTP \(status)). Retry in a moment."
        case .transport(.rateLimited(let status, let retryAfter)):
            let wait = retryAfter.map { " in \(Int($0.rounded(.up))) s" } ?? " in a moment"
            return "Anthropic is busy (HTTP \(status)). Retry\(wait)."
        case .transport(.network), .transport(.invalidResponse):
            return "Couldn't reach Anthropic. Check your connection, then Retry."
        case .transport(.cancelled):
            return "The answer was stopped."
        case .streamError(let stream) where stream.type == "overloaded_error":
            return "Anthropic is busy. Retry in a moment."
        case .streamError:
            return "Anthropic stopped the answer with an error. Retry to ask again."
        case .malformedJSON, .unexpectedSequence, .unexpectedEndOfStream, .sse:
            return "The answer stopped before it finished. Retry to ask again."
        }
    }
}

/// A provider with nothing stored, used until a Keychain-backed store is wired in.
struct NoStoredCredentials: CredentialProvider {
    func credential(for kind: CredentialKind) async throws -> CredentialValue? { nil }
}
