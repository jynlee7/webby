import Foundation

/// The bridge process: relays framed messages from Chrome (stdin) to the app's socket, and
/// the app's commands back to Chrome (stdout). It keeps running while the app is down,
/// reconnecting every `reconnectInterval`. Meanwhile it keeps only the latest `hello`,
/// `inventory` and `active`, replays them on reconnecting, and asks the extension to
/// resend if anything else may have been missed. Both directions are validated, and
/// everything runs on one serial queue, so messages keep their order.
public final class BridgeRelay: @unchecked Sendable {
    private let input: Int32
    private let output: Int32
    private let socketPath: String
    private let reconnectInterval: TimeInterval
    private let log: @Sendable (String) -> Void

    private let queue = DispatchQueue(label: "com.webby.bridge-relay")
    private let finished = DispatchSemaphore(value: 0)
    private var isFinished = false
    private var inputSource: DispatchSourceRead?
    private var reconnectTimer: DispatchSourceTimer?
    private var appSocket: Int32 = -1
    private var appSource: DispatchSourceRead?

    private var fromChrome = NativeMessageFramer(limit: BridgeConstants.maxMessageFromChrome)
    private var fromApp = NativeMessageFramer(limit: BridgeConstants.maxMessageToChrome)
    private var latestHello: Data?
    private var latestInventory: Data?
    private var latestActive: Data?
    /// Set when the app may have missed a message that the replay doesn't cover.
    private var needsResend = false

    public init(
        input: Int32 = STDIN_FILENO,
        output: Int32 = STDOUT_FILENO,
        socketURL: URL = BridgeConstants.defaultSocketURL,
        reconnectInterval: TimeInterval = 1,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.input = input
        self.output = output
        self.socketPath = socketURL.path
        self.reconnectInterval = reconnectInterval
        self.log = log
    }

    public func start() {
        queue.async { [self] in
            let source = DispatchSource.makeReadSource(fileDescriptor: input, queue: queue)
            source.setEventHandler { [weak self] in self?.readFromChrome() }
            inputSource = source
            source.resume()

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: reconnectInterval)
            timer.setEventHandler { [weak self] in self?.connectIfNeeded() }
            reconnectTimer = timer
            timer.resume()
        }
    }

    /// Blocks until Chrome closes stdin or the relay can't continue.
    public func wait() {
        finished.wait()
    }

    // MARK: - Chrome → app

    private func readFromChrome() {
        let bytes: Data
        do {
            bytes = try UnixSocket.receive(from: input)
        } catch {
            finish("can't read from Chrome: \(error)")
            return
        }
        guard !bytes.isEmpty else {
            finish("Chrome closed the connection")
            return
        }

        let payloads: [Data]
        do {
            payloads = try fromChrome.append(bytes)
        } catch {
            finish("bad frame from Chrome: \(error)")
            return
        }
        for payload in payloads {
            relayToApp(payload)
        }
    }

    private func relayToApp(_ payload: Data) {
        let message: ExtensionMessage
        do {
            message = try ExtensionMessage.decode(payload)
        } catch {
            log("dropping an invalid message from Chrome")
            return
        }

        if case .hello = message {
            latestHello = payload
            latestInventory = nil
            latestActive = nil
        }
        guard latestHello != nil else {
            log("dropping \(message.type): it arrived before hello")
            return
        }
        switch message {
        case .inventory: latestInventory = payload
        case .active: latestActive = payload
        default: break
        }

        if appSocket >= 0 {
            sendToApp(payload)
        } else {
            switch message {
            case .hello, .inventory, .active: break
            default: needsResend = true
            }
        }
    }

    private func sendToApp(_ payload: Data) {
        do {
            try UnixSocket.send(NativeMessageFramer.frame(payload, limit: BridgeConstants.maxMessageFromChrome), to: appSocket)
        } catch {
            log("lost the connection to Webby: \(error)")
            disconnectFromApp()
        }
    }

    // MARK: - App connection

    private func connectIfNeeded() {
        guard appSocket < 0, !isFinished,
              let fd = try? UnixSocket.makeConnection(path: socketPath)
        else { return }

        appSocket = fd
        fromApp = NativeMessageFramer(limit: BridgeConstants.maxMessageToChrome)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readFromApp() }
        source.setCancelHandler { close(fd) }
        appSource = source
        source.resume()
        log("connected to Webby")

        for payload in [latestHello, latestInventory, latestActive].compactMap({ $0 }) {
            sendToApp(payload)
            guard appSocket >= 0 else { return }
        }
        if needsResend, latestHello != nil {
            needsResend = false
            sendToChrome(.resend)
        }
    }

    private func disconnectFromApp() {
        guard appSocket >= 0 else { return }
        appSource?.cancel()
        appSource = nil
        appSocket = -1
        // Anything written just before the app went away may have been lost.
        needsResend = true
    }

    // MARK: - App → Chrome

    private func readFromApp() {
        let bytes: Data
        do {
            bytes = try UnixSocket.receive(from: appSocket)
        } catch {
            log("lost the connection to Webby: \(error)")
            disconnectFromApp()
            return
        }
        guard !bytes.isEmpty else {
            log("Webby disconnected")
            disconnectFromApp()
            return
        }

        let payloads: [Data]
        do {
            payloads = try fromApp.append(bytes)
        } catch {
            log("bad frame from Webby: \(error)")
            disconnectFromApp()
            return
        }
        for payload in payloads {
            do {
                sendToChrome(try AppCommand.decode(payload))
            } catch {
                log("dropping an invalid command from Webby")
            }
        }
    }

    private func sendToChrome(_ command: AppCommand) {
        let frame: Data
        do {
            frame = try NativeMessageFramer.frame(command.encoded(), limit: BridgeConstants.maxMessageToChrome)
        } catch {
            log("dropping \(command.type): \(error)")
            return
        }
        do {
            try UnixSocket.send(frame, to: output)
        } catch {
            finish("can't write to Chrome: \(error)")
        }
    }

    private func finish(_ reason: String) {
        guard !isFinished else { return }
        isFinished = true
        log(reason)
        inputSource?.cancel()
        reconnectTimer?.cancel()
        disconnectFromApp()
        finished.signal()
    }
}
