import Foundation

/// Names one run of Chrome. Tab IDs are unique only within a run, so every tab binding,
/// `TabRef` and Open Tabs window carries this string. Both bridge reducers must get it
/// from here: if their strings differed, no binding would ever match a live tab.
public enum ChromeSessionIdentity {
    /// `"<pid>@<launch date in seconds since 1970>"`.
    public static func session(processIdentifier: Int32, launchDate: Date) -> String {
        "\(processIdentifier)@\(launchDate.timeIntervalSince1970)"
    }
}
