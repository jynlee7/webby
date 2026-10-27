import Foundation

/// Minimal blocking Unix-domain stream sockets, shared by the app's `BridgeServer` and the
/// bridge's `BridgeRelay`. Every socket is close-on-exec and never raises `SIGPIPE`.
enum UnixSocket {
    struct Failure: Error, Equatable, CustomStringConvertible {
        let operation: String
        let code: Int32

        var description: String { "\(operation): \(String(cString: strerror(code)))" }
    }

    /// Creates a listening socket at `path` with mode 0600. Accepting doesn't block.
    static func makeListener(path: String, backlog: Int32 = 8) throws -> Int32 {
        let fd = try makeSocket()
        do {
            try withAddress(path) { address, length in
                guard bind(fd, address, length) == 0 else { throw Failure(operation: "bind", code: errno) }
            }
            guard chmod(path, 0o600) == 0 else { throw Failure(operation: "chmod", code: errno) }
            guard listen(fd, backlog) == 0 else { throw Failure(operation: "listen", code: errno) }
            try setNonBlocking(fd, true)
        } catch {
            close(fd)
            throw error
        }
        return fd
    }

    static func makeConnection(path: String) throws -> Int32 {
        let fd = try makeSocket()
        do {
            try withAddress(path) { address, length in
                guard connect(fd, address, length) == 0 else { throw Failure(operation: "connect", code: errno) }
            }
        } catch {
            close(fd)
            throw error
        }
        return fd
    }

    /// Accepts one pending connection as a blocking socket, or returns nil if none is pending.
    static func acceptConnection(_ listener: Int32) -> Int32? {
        while true {
            let fd = accept(listener, nil, nil)
            if fd >= 0 {
                configure(fd)
                // Accepted sockets inherit O_NONBLOCK from the listener on Darwin.
                try? setNonBlocking(fd, false)
                return fd
            }
            if errno == EINTR { continue }
            return nil
        }
    }

    /// The user ID of the process on the other end of a connected socket.
    static func peerUID(of fd: Int32) -> uid_t? {
        var uid = uid_t()
        var gid = gid_t()
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    /// What exists at `path`: nil if nothing, otherwise whether it is a socket.
    static func isSocket(atPath path: String) -> Bool? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return (info.st_mode & S_IFMT) == S_IFSOCK
    }

    /// Writes all of `data`, retrying short writes. Socket writes have a bounded timeout.
    static func send(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    guard poll(&descriptor, 1, 1000) > 0 else {
                        throw Failure(operation: "write timeout", code: ETIMEDOUT)
                    }
                } else {
                    throw Failure(operation: "write", code: errno)
                }
            }
        }
    }

    /// Reads what is available, blocking until at least one byte arrives. Empty means EOF.
    static func receive(from fd: Int32, maxLength: Int = 64 * 1024) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        while true {
            let count = read(fd, &buffer, maxLength)
            if count >= 0 { return Data(buffer[0..<count]) }
            if errno == EINTR { continue }
            throw Failure(operation: "read", code: errno)
        }
    }

    private static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(operation: "socket", code: errno) }
        configure(fd)
        return fd
    }

    private static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // A stalled peer must not hold the relay queue indefinitely (including EOF handling).
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setNonBlocking(_ fd: Int32, _ enabled: Bool) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { throw Failure(operation: "fcntl", code: errno) }
        let updated = enabled ? flags | O_NONBLOCK : flags & ~O_NONBLOCK
        guard fcntl(fd, F_SETFL, updated) == 0 else { throw Failure(operation: "fcntl", code: errno) }
    }

    private static func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Void) throws {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        // sun_path is 104 bytes on Darwin, including the terminating NUL.
        guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw Failure(operation: "socket path", code: ENAMETOOLONG)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                try body(address, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}
