import Foundation
import WebbyCore

// Chrome native-messaging host. Chrome starts one per profile when the extension connects,
// and it relays between Chrome (stdin/stdout) and the Webby app's socket until Chrome
// closes stdin. stdout carries only protocol frames, so logs go to stderr.

func log(_ message: String) {
    FileHandle.standardError.write(Data("webby-bridge: \(message)\n".utf8))
}

signal(SIGPIPE, SIG_IGN)

guard BridgeConstants.isAllowedCaller(CommandLine.arguments) else {
    log("refusing to run for caller \(CommandLine.arguments.dropFirst().first ?? "(none)")")
    exit(1)
}

let relay = BridgeRelay { message in log(message) }
relay.start()
relay.wait()
exit(0)
