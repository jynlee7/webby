import Foundation

/// The identity a workspace groups notes by.
public enum WorkspaceKey: Hashable, Codable, Sendable {
    case host(name: String)
    case app(bundleID: String)
    case localFiles
    case tabsWithoutPage
}

public struct WorkspaceRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var title: String?
    public var keys: [WorkspaceKey]
    public var pinned: Bool
    public var skinID: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String? = nil,
        keys: [WorkspaceKey] = [],
        pinned: Bool = false,
        skinID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.keys = keys
        self.pinned = pinned
        self.skinID = skinID
        self.createdAt = createdAt
    }
}
