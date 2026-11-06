import Foundation

/// One bridge connection as the app last heard it. `hasHello` separates a connection that
/// has only connected from one whose `hello` has arrived, so a version can be trusted.
public struct BridgeConnectionStatus: Equatable, Sendable, Identifiable {
    public let connection: Int
    /// The Chrome profile's key, or `"unknown"` until `hello` arrives.
    public let profile: String
    public let extensionVersion: String?
    public let protocolVersion: Int?
    public let incognitoAllowed: Bool?
    public let hasHello: Bool

    public var id: Int { connection }

    init(
        connection: Int,
        profile: String = "unknown",
        extensionVersion: String? = nil,
        protocolVersion: Int? = nil,
        incognitoAllowed: Bool? = nil,
        hasHello: Bool = false
    ) {
        self.connection = connection
        self.profile = profile
        self.extensionVersion = extensionVersion
        self.protocolVersion = protocolVersion
        self.incognitoAllowed = incognitoAllowed
        self.hasHello = hasHello
    }
}

/// Whether the loaded extension matches the version bundled with the app.
public enum ExtensionReloadState: Equatable, Sendable {
    case current
    case reloadNeeded(reported: String, bundled: String)
    /// Not enough is known yet, or a reported version can't be parsed.
    case unknown
}

/// The bridge connections the app knows about, folded from `BridgeEvent`s. Pure: no
/// logging, no file access, no clock, so it can be tested and called from any actor.
public struct BridgeStatus: Equatable, Sendable {
    /// Always sorted by connection ascending.
    public private(set) var connections: [BridgeConnectionStatus] = []

    public init() {}

    public mutating func receive(_ event: BridgeEvent) {
        switch event {
        case let .connected(connection):
            guard !connections.contains(where: { $0.connection == connection }) else { return }
            connections.append(BridgeConnectionStatus(connection: connection))
            connections.sort { $0.connection < $1.connection }

        case let .message(connection, _, message):
            guard case let .hello(hello) = message else { return }
            guard let index = connections.firstIndex(where: { $0.connection == connection }) else { return }
            connections[index] = BridgeConnectionStatus(
                connection: connection,
                profile: hello.profile,
                extensionVersion: hello.extVersion,
                protocolVersion: hello.v,
                incognitoAllowed: hello.incognitoAllowed,
                hasHello: true
            )

        case let .disconnected(connection, _):
            connections.removeAll { $0.connection == connection }

        case let .dropped(connection, _):
            if let connection {
                connections.removeAll { $0.connection == connection }
            } else {
                connections.removeAll()
            }
        }
    }

    /// Compares every reported extension version with the bundled one. A connection that
    /// hasn't said hello, or whose version can't be parsed, makes the answer `.unknown`
    /// unless another connection is already known to be older.
    public func reloadState(bundledVersion: ExtensionVersion?) -> ExtensionReloadState {
        guard let bundledVersion, !connections.isEmpty else { return .unknown }

        var oldest: (version: ExtensionVersion, reported: String, connection: Int)?
        var sawUnknown = false
        for status in connections {
            guard status.hasHello, let reported = status.extensionVersion, let version = ExtensionVersion(reported) else {
                sawUnknown = true
                continue
            }
            guard version < bundledVersion else { continue }
            if let current = oldest, current.version < version || (current.version == version && current.connection < status.connection) {
                continue
            }
            oldest = (version, reported, status.connection)
        }

        if let oldest {
            return .reloadNeeded(reported: oldest.reported, bundled: bundledVersion.description)
        }
        return sawUnknown ? .unknown : .current
    }
}
