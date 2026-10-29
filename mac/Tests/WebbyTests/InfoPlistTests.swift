import Foundation
import Testing

@Suite struct InfoPlistTests {
    @Test func registersTheWebbyURLSchemeForViewing() throws {
        let infoPlist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")

        let data = try Data(contentsOf: infoPlist)
        let root = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dictionary = try #require(root as? [String: Any])
        let types = try #require(dictionary["CFBundleURLTypes"] as? [[String: Any]])
        let webby = try #require(types.first)

        #expect(types.count == 1)
        #expect(webby["CFBundleURLName"] as? String == "Webby")
        #expect(webby["CFBundleTypeRole"] as? String == "Viewer")
        #expect(webby["CFBundleURLSchemes"] as? [String] == ["webby"])
    }
}
