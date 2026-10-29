import Foundation

/// Produces the only page URL that compiled output may contain.
///
/// The URL assumes `https`, keeps a non-default port that is already embedded in
/// the stored host, and keeps only query parameters that the effective significant
/// query rules select. It never reads a file and returns `nil` for every scope
/// that has no durable web URL.
public enum CanonicalExportURL {
    public static func make(
        for page: PageURL,
        queryRules: [QueryRule] = QueryRules.builtIns
    ) -> String? {
        guard page.host != "file" else { return nil }
        guard let host = validatedHost(page.host) else { return nil }
        guard let path = validatedPath(page.path) else { return nil }

        let query = QueryRules.canonicalQuery(
            for: page.query,
            host: page.host,
            rules: queryRules
        )

        var result = "https://" + host + path
        if let query {
            result += "?" + query
        }

        guard let components = URLComponents(string: result),
              components.scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil
        else { return nil }

        return result
    }

    /// Convenience for anchor-driven callers. App anchors have no export URL.
    public static func make(
        for anchor: Anchor,
        queryRules: [QueryRule] = QueryRules.builtIns
    ) -> String? {
        guard case let .web(page, _) = anchor else { return nil }
        return make(for: page, queryRules: queryRules)
    }

    private static func validatedHost(_ rawHost: String) -> String? {
        let host = rawHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !host.isEmpty,
              !host.contains("@"),
              !host.contains("/"),
              !host.contains("\\"),
              !host.contains("?"),
              !host.contains("#"),
              !host.unicodeScalars.contains(where: {
                  $0.properties.isWhitespace || $0.value < 0x21 || $0.value == 0x7F
              })
        else { return nil }

        var authorityInput = host
        if host.hasPrefix("[") {
            guard host.contains("]") else { return nil }
        } else {
            let colonCount = host.filter { $0 == ":" }.count
            if colonCount > 1 {
                // PageURL can hold an IPv6 literal without URL brackets.
                authorityInput = "[\(host)]"
            } else {
                let name = host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
                guard !name.isEmpty,
                      !name.hasPrefix("."),
                      !name.hasSuffix("."),
                      !name.contains("..")
                else { return nil }
            }
        }

        // Let Foundation serialize Unicode/IDN and IPv6 authorities. This avoids
        // silently dropping valid stored hosts while still rejecting userinfo,
        // invalid ports and extra URL structure.
        guard let components = URLComponents(string: "https://\(authorityInput)/"),
              components.scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path == "/",
              let rendered = components.string,
              rendered.hasPrefix("https://"),
              rendered.hasSuffix("/")
        else { return nil }

        let start = rendered.index(rendered.startIndex, offsetBy: "https://".count)
        let end = rendered.index(before: rendered.endIndex)
        let authority = String(rendered[start..<end])
        return authority.isEmpty ? nil : authority
    }

    private static func validatedPath(_ rawPath: String) -> String? {
        if rawPath.isEmpty {
            return "/"
        }

        guard rawPath.hasPrefix("/") else { return nil }
        guard !rawPath.contains("#"),
              !rawPath.contains("?"),
              !rawPath.contains("\\")
        else { return nil }

        guard !rawPath.unicodeScalars.contains(where: {
            $0.properties.isWhitespace || $0.value < 0x20 || $0.value == 0x7F
        }) else { return nil }

        return rawPath
    }
}
