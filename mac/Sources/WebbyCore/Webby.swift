import Foundation

/// Shared identifiers used by the app, the native-messaging bridge, and the extension.
public enum Webby {
    public static let bundleID = "com.webby.app"
    public static let version = "0.0.1"

    /// Distributed notification the bridge posts when Chrome reports a new active tab.
    public static let chromeContextNotification = Notification.Name("com.webby.chromeContext")
    /// Distributed notification the app posts to ask the bridge to have the extension resend.
    public static let requestContextNotification = Notification.Name("com.webby.requestContext")
}
