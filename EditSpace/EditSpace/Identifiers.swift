import Foundation

/// A stable identifier for an EditSpace document.
public struct DocumentID: RawRepresentable, Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A stable author identifier. It must survive reconnects and app launches.
public struct ActorID: RawRepresentable, Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A stable identifier for any entity in a document.
public struct EntityID: RawRepresentable, Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// An immutable operation identifier, conventionally `actor:sequence`.
public struct OperationID: RawRepresentable, Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(actorID: ActorID, sequence: Int64) { rawValue = "\(actorID.rawValue):\(sequence)" }
    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A connection-scoped session identifier used only for ephemeral presence.
public struct SessionID: RawRepresentable, Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// An extensible protocol token. Unknown values can be preserved by every implementation.
public struct ProtocolToken: RawRepresentable, Codable, Hashable, Comparable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public typealias OperationAction = ProtocolToken
public typealias EntityKind = ProtocolToken
public typealias Feature = ProtocolToken

public extension OperationAction {
    static let create: Self = "create"
    static let update: Self = "update"
    static let delete: Self = "delete"
    static let duplicate: Self = "duplicate"
    static let link: Self = "link"
    static let unlink: Self = "unlink"
}

public extension EntityKind {
    static let document: Self = "document"
    static let object: Self = "object"
    static let modifier: Self = "modifier"
    static let material: Self = "material"
    static let asset: Self = "asset"
    static let constraint: Self = "constraint"
    static let parameter: Self = "parameter"
    static let dependency: Self = "dependency"
    static let legacySnapshot: Self = "legacySnapshot"
}

public extension Feature {
    static let coreV1: Self = "core.v1"
    static let crudV1: Self = "crud.v1"
    static let duplicateV1: Self = "duplicate.v1"
    static let linkedDuplicateV1: Self = "linkedDuplicate.v1"
    static let dependencyGraphV1: Self = "dependencyGraph.v1"
    static let presenceV1: Self = "presence.v1"
}

public struct EntityReference: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let kind: EntityKind
    public let id: EntityID

    public init(kind: EntityKind, id: EntityID) {
        self.kind = kind
        self.id = id
    }

    public var description: String { "\(kind.rawValue):\(id.rawValue)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind ? lhs.id < rhs.id : lhs.kind < rhs.kind
    }
}

public struct OperationStamp: Codable, Hashable, Comparable, Sendable {
    public let sequence: Int64
    public let actorID: ActorID
    public let operationID: OperationID

    public init(sequence: Int64, actorID: ActorID, operationID: OperationID) {
        self.sequence = sequence
        self.actorID = actorID
        self.operationID = operationID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        if lhs.actorID != rhs.actorID { return lhs.actorID < rhs.actorID }
        return lhs.operationID < rhs.operationID
    }
}
