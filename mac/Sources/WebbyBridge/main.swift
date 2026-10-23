import Foundation
import WebbyCore

// Chrome native-messaging host. Implemented in step 4; for now it just exits cleanly.
FileHandle.standardError.write("webby-bridge \(Webby.version)\n".data(using: .utf8)!)
