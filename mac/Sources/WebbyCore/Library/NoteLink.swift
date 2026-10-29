import Foundation

/// The `webby://note/<uuid>` deep link and its strict parser.
public enum NoteLink {
    public static let scheme = "webby"
    public static let host = "note"

    public static func url(for id: UUID) -> String {
        "\(scheme)://\(host)/\(id.uuidString)"
    }

    /// Accepts exactly `webby://note/<uuid>` with no credentials, port, query,
    /// fragment or extra path components.
    public static func parse(_ string: String) -> UUID? {
        guard !string.isEmpty,
              let components = URLComponents(string: string),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == host,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil
        else { return nil }

        let path = components.path
        guard path.hasPrefix("/") else { return nil }

        let identifier = String(path.dropFirst())
        guard !identifier.isEmpty, !identifier.contains("/") else { return nil }
        guard let id = UUID(uuidString: identifier) else { return nil }

        return id
    }
}
