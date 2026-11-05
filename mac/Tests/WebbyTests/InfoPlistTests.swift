import Foundation
import Testing
import WebbyCore

@Suite struct InfoPlistTests {
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func infoPlist() throws -> [String: Any] {
        let url = Self.repository.appendingPathComponent("mac/Resources/Info.plist")
        let data = try Data(contentsOf: url)
        let root = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(root as? [String: Any])
    }

    @Test func registersTheWebbyURLSchemeForViewing() throws {
        let dictionary = try infoPlist()
        let types = try #require(dictionary["CFBundleURLTypes"] as? [[String: Any]])
        let webby = try #require(types.first)

        #expect(types.count == 1)
        #expect(webby["CFBundleURLName"] as? String == "Webby")
        #expect(webby["CFBundleTypeRole"] as? String == "Viewer")
        #expect(webby["CFBundleURLSchemes"] as? [String] == ["webby"])
    }

    @Test func bundleIdentifierMatchesTheCoreConstant() throws {
        #expect(try infoPlist()["CFBundleIdentifier"] as? String == WebbyCore.Webby.bundleID)
    }

    @Test func marketingVersionMatchesCoreAndTheExtension() throws {
        let manifestURL = Self.repository.appendingPathComponent("extension/manifest.json")
        let manifest = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        let version = try #require(try infoPlist()["CFBundleShortVersionString"] as? String)

        #expect(version == WebbyCore.Webby.version)
        #expect(manifest["version"] as? String == WebbyCore.Webby.version)
        #expect(version.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil)
    }

    @Test func sourceBuildNumberIsAPositiveIntegerAndNotADevelopmentBuild() throws {
        let dictionary = try infoPlist()
        let build = try #require(dictionary["CFBundleVersion"] as? String)

        #expect(build.range(of: #"^[1-9][0-9]*$"#, options: .regularExpression) != nil)
        // Only the staged development bundle carries this key (scripts/build-app.sh).
        #expect(dictionary["WebbyDevelopmentBuild"] == nil)
    }

    @Test func skinTypeSharesTheBundleIdentifierDomain() throws {
        let dictionary = try infoPlist()
        let exported = try #require((dictionary["UTExportedTypeDeclarations"] as? [[String: Any]])?.first)
        let document = try #require((dictionary["CFBundleDocumentTypes"] as? [[String: Any]])?.first)
        let tags = try #require(exported["UTTypeTagSpecification"] as? [String: Any])
        let expected = WebbyCore.Webby.bundleID + ".skin"

        #expect(exported["UTTypeIdentifier"] as? String == expected)
        #expect(document["LSItemContentTypes"] as? [String] == [expected])
        #expect(tags["public.filename-extension"] as? [String] == ["webbyskin"])
        #expect(tags["public.mime-type"] as? [String] == ["application/x-webbyskin"])
    }
}
