import Foundation

/// App-wide identifiers. The Chrome bridge's identifiers live in `BridgeConstants`.
/// `scripts/check-version-identifiers.sh` checks that `Info.plist`, the skin UTI and
/// `extension/manifest.json` agree with these, so keep each on its own `static let` line.
public enum Webby {
    public static let bundleID = "io.github.jynlee7.webby"
    public static let version = "0.1.0"
}
