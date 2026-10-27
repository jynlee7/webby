import Foundation

/// What the app hears from bridges, in arrival order per connection.
public enum BridgeEvent: Equatable, Sendable {
    case connected(connection: Int)
    /// A validated message. `profile` comes from the connection's `hello`, so messages
    /// from two Chrome profiles are never mixed up.
    case message(connection: Int, profile: String, ExtensionMessage)
    /// Something was refused: a connection (when `connection` is nil), a message or a command.
    case dropped(connection: Int?, reason: String)
    case disconnected(connection: Int, profile: String?)
}

/// The app's end of the bridge: a Unix socket that each Chrome profile's bridge process
/// connects to. Only processes of `allowedUID` (the current user) are accepted. Frames are
/// limited to `BridgeConstants.maxMessageFromChrome`, and every message is validated
/// before it reaches `events`. All state lives on one serial queue.
public final class BridgeServer: @unchecked Sendable {
    public enum ServerError: Error, Equatable {
        /// Another server owns the socket, whether or not it is listening yet.
        case alreadyRunning
        /// Something other than a socket exists at the socket path; it is left alone.
        case pathInUse
    }

    /// One bridge process per Chrome profile; this only bounds misuse.
    static let maxConnections = 32

    public let socketURL: URL
    public let events: AsyncStream<BridgeEvent>

    private let allowedUID: uid_t
    private let continuation: AsyncStream<BridgeEvent>.Continuation
    private let queue = DispatchQueue(label: "com.webby.bridge-server")
    private var listener: DispatchSourceRead?
    /// Held from before the socket is checked until after it is removed.
    private var ownershipLock: Int32?
    private var connections: [Int: Connection] = [:]
    private var nextConnectionID = 1

    private final class Connection {
        let id: Int
        let fd: Int32
        /// Commands are written here so a slow reader never blocks the server queue.
        let writeQueue: DispatchQueue
        var source: DispatchSourceRead?
        var framer = NativeMessageFramer(limit: BridgeConstants.maxMessageFromChrome)
        var profile: String?

        init(id: Int, fd: Int32) {
            self.id = id
            self.fd = fd
            self.writeQueue = DispatchQueue(label: "com.webby.bridge-server.write.\(id)")
        }
    }

    public init(socketURL: URL = BridgeConstants.defaultSocketURL, allowedUID: uid_t = getuid()) {
        self.socketURL = socketURL
        self.allowedUID = allowedUID
        (events, continuation) = AsyncStream.makeStream(of: BridgeEvent.self)
    }

    /// Starts listening. A stale socket left by a crashed run is replaced; a live one means
    /// another Webby is running, and nothing is changed. Only the holder of the socket's
    /// lock may replace or remove it, so a server that has bound the socket but isn't
    /// listening yet is never mistaken for a stale one.
    public func start() throws {
        try queue.sync {
            guard listener == nil else { return }
            let path = socketURL.path
            try FileManager.default.createDirectory(
                at: socketURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard let lock = try Self.lockOwnership(ofSocketAt: path) else {
                throw ServerError.alreadyRunning
            }
            do {
                switch UnixSocket.isSocket(atPath: path) {
                case nil:
                    break
                case false?:
                    throw ServerError.pathInUse
                case true?:
                    do {
                        let fd = try UnixSocket.makeConnection(path: path)
                        close(fd)
                        throw ServerError.alreadyRunning
                    } catch let error as UnixSocket.Failure where error.code == ECONNREFUSED {
                        unlink(path)
                    }
                }

                let fd = try UnixSocket.makeListener(path: path)
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [weak self] in self?.acceptPending(on: fd) }
                source.setCancelHandler { close(fd) }
                listener = source
                ownershipLock = lock
                source.resume()
            } catch {
                close(lock)
                throw error
            }
        }
    }

    /// Stops listening, closes every connection, removes the socket and ends `events`.
    public func stop() {
        queue.sync {
            guard let listener else { return }
            listener.cancel()
            self.listener = nil
            for id in connections.keys.sorted() {
                disconnect(id)
            }
            unlink(socketURL.path)
            if let ownershipLock {
                close(ownershipLock)
                self.ownershipLock = nil
            }
        }
        continuation.finish()
    }

    /// Takes the exclusive lock beside the socket at `path`, or returns nil if another
    /// server holds it. The system releases the lock when its holder exits, even by crashing.
    /// The lock file is never removed, so two servers can never lock different files.
    static func lockOwnership(ofSocketAt path: String) throws -> Int32? {
        let fd = Darwin.open(path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw UnixSocket.Failure(operation: "open lock", code: errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { return nil }
            throw UnixSocket.Failure(operation: "lock", code: code)
        }
        return fd
    }

    /// Sends a command to the newest connection for `profile`.
    public func send(_ command: AppCommand, toProfile profile: String) {
        queue.async { [self] in
            guard let connection = connections.values.filter({ $0.profile == profile }).max(by: { $0.id < $1.id }) else {
                emit(.dropped(connection: nil, reason: "no bridge for profile \(profile); \(command.type) not sent"))
                return
            }
            let frame: Data
            do {
                frame = try NativeMessageFramer.frame(command.encoded(), limit: BridgeConstants.maxMessageToChrome)
            } catch {
                emit(.dropped(connection: connection.id, reason: "\(command.type) not sent: \(error)"))
                return
            }
            let fd = connection.fd
            let id = connection.id
            connection.writeQueue.async { [weak self] in
                do {
                    try UnixSocket.send(frame, to: fd)
                } catch {
                    // A partial frame cannot be retried on this stream. A write failure
                    // need not produce read EOF, so explicitly retire the connection.
                    self?.queue.async { [weak self] in self?.disconnect(id) }
                }
            }
        }
    }

    // MARK: - Queue-confined

    private func emit(_ event: BridgeEvent) {
        continuation.yield(event)
    }

    private func acceptPending(on listenerFD: Int32) {
        while let fd = UnixSocket.acceptConnection(listenerFD) {
            guard UnixSocket.peerUID(of: fd) == allowedUID else {
                close(fd)
                emit(.dropped(connection: nil, reason: "refused a connection from another user"))
                continue
            }
            guard connections.count < Self.maxConnections else {
                close(fd)
                emit(.dropped(connection: nil, reason: "refused a connection: too many bridges"))
                continue
            }
            open(fd)
        }
    }

    private func open(_ fd: Int32) {
        let connection = Connection(id: nextConnectionID, fd: fd)
        nextConnectionID += 1

        let id = connection.id
        let writeQueue = connection.writeQueue
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable(on: id) }
        source.setCancelHandler {
            // Unblock any pending write, then close once queued writes are done, so a
            // write can never land on a reused descriptor.
            shutdown(fd, SHUT_RDWR)
            writeQueue.async { close(fd) }
        }
        connection.source = source
        connections[id] = connection
        emit(.connected(connection: id))
        source.resume()
    }

    private func readAvailable(on id: Int) {
        guard let connection = connections[id] else { return }
        let bytes: Data
        do {
            bytes = try UnixSocket.receive(from: connection.fd)
        } catch {
            disconnect(id)
            return
        }
        guard !bytes.isEmpty else {
            disconnect(id)
            return
        }

        let payloads: [Data]
        do {
            payloads = try connection.framer.append(bytes)
        } catch {
            emit(.dropped(connection: id, reason: "closing connection: \(error)"))
            disconnect(id)
            return
        }
        for payload in payloads {
            deliver(payload, from: connection)
        }
    }

    private func deliver(_ payload: Data, from connection: Connection) {
        let message: ExtensionMessage
        do {
            message = try ExtensionMessage.decode(payload)
        } catch {
            emit(.dropped(connection: connection.id, reason: "invalid message"))
            return
        }
        if case .hello(let hello) = message {
            connection.profile = hello.profile
        }
        guard let profile = connection.profile else {
            emit(.dropped(connection: connection.id, reason: "\(message.type) arrived before hello"))
            return
        }
        emit(.message(connection: connection.id, profile: profile, message))
    }

    private func disconnect(_ id: Int) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.source?.cancel()
        emit(.disconnected(connection: id, profile: connection.profile))
    }
}
