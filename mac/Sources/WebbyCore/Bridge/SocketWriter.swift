import Foundation

/// Writes frames to a socket on its own serial queue, so a peer that stops reading never
/// blocks the owner's queue. Writes keep their order, and at most `limit` bytes wait at
/// once; a single larger frame is still accepted when nothing is waiting.
///
/// A failed write may leave a partial frame on the stream, so the writer then drops every
/// later write and calls `onFailure` once. `cancel()` unblocks a stuck write, drops the
/// writes still waiting, and closes the descriptor once the write queue is idle, so no
/// write can land on a reused descriptor. The writer owns the descriptor from `init`.
final class SocketWriter: @unchecked Sendable {
    let fd: Int32
    private let limit: Int
    private let queue: DispatchQueue
    private let onFailure: @Sendable () -> Void

    private let lock = NSLock()
    private var queuedBytes = 0
    private var isStopped = false
    private var isCancelled = false

    init(fd: Int32, label: String, limit: Int, onFailure: @escaping @Sendable () -> Void) {
        self.fd = fd
        self.limit = limit
        self.queue = DispatchQueue(label: label)
        self.onFailure = onFailure
    }

    /// Queues `data` behind earlier writes. Returns false, queuing nothing, if the writer has
    /// stopped or `data` would put more than `limit` bytes in the queue.
    func enqueue(_ data: Data) -> Bool {
        lock.lock()
        guard !isStopped, queuedBytes == 0 || queuedBytes + data.count <= limit else {
            lock.unlock()
            return false
        }
        queuedBytes += data.count
        lock.unlock()

        queue.async { [self] in
            if !stopped {
                do {
                    try UnixSocket.send(data, to: fd)
                } catch {
                    fail()
                }
            }
            lock.lock()
            queuedBytes -= data.count
            lock.unlock()
        }
        return true
    }

    func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        isStopped = true
        lock.unlock()

        // The descriptor stays valid until the close below, so this can't hit another file.
        shutdown(fd, SHUT_RDWR)
        let fd = fd
        queue.async { close(fd) }
    }

    private var stopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStopped
    }

    private func fail() {
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        isStopped = true
        lock.unlock()
        onFailure()
    }
}
