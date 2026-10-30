import Foundation

/// A deterministic HTTP request produced by the request builder.
public struct PreparedRequest: Equatable, Sendable {
    public struct Header: Equatable, Hashable, Sendable {
        public let name: String
        public let value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public let url: URL
    public let method: String
    public let headers: [Header]
    public let body: Data

    public init(url: URL, method: String = "POST", headers: [Header] = [], body: Data = Data()) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }

    /// Sorts header names so the same inputs always produce the same header order.
    public init(url: URL, method: String = "POST", headers: [String: String], body: Data = Data()) {
        self.init(
            url: url,
            method: method,
            headers: headers
                .map { Header(name: $0.key, value: $0.value) }
                .sorted { lhs, rhs in lhs.name < rhs.name },
            body: body
        )
    }
}

public enum ClaudeTransportError: Error, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case invalidResponse
    case httpStatus(Int)
    case network
    case cancelled

    public var description: String {
        switch self {
        case .invalidResponse:
            return "Claude transport received an invalid response"
        case let .httpStatus(status):
            return "Claude transport received HTTP \(status)"
        case .network:
            return "Claude transport network failure"
        case .cancelled:
            return "Claude transport cancelled"
        }
    }

    public var debugDescription: String {
        description
    }
}

/// Streams raw response bytes. Implementations must not retry transparently.
public protocol ClaudeTransport: Sendable {
    func stream(_ request: PreparedRequest) -> AsyncThrowingStream<Data, Error>
}

/// URLSession transport used in production once the app links WebbyAgent.
public struct URLSessionClaudeTransport: ClaudeTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    private static func makeURLRequest(_ request: PreparedRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for header in request.headers {
            urlRequest.setValue(header.value, forHTTPHeaderField: header.name)
        }
        return urlRequest
    }

    public func stream(_ request: PreparedRequest) -> AsyncThrowingStream<Data, Error> {
        let session = self.session
        return AsyncThrowingStream { continuation in
            let urlRequest = Self.makeURLRequest(request)

            let task = Task { @Sendable in
                do {
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw ClaudeTransportError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw ClaudeTransportError.httpStatus(http.statusCode)
                    }

                    var buffer = Data()
                    buffer.reserveCapacity(4_096)
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        buffer.append(byte)
                        if buffer.count >= 4_096 {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ClaudeTransportError.cancelled)
                } catch let error as ClaudeTransportError {
                    continuation.finish(throwing: error)
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: ClaudeTransportError.cancelled)
                } catch {
                    continuation.finish(throwing: ClaudeTransportError.network)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
