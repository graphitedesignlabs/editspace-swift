import Foundation

public struct FieldRegister: Equatable, Sendable {
    public let value: Value
    public let stamp: OperationStamp
}

public struct EntityState: Equatable, Sendable {
    public let reference: EntityReference
    public private(set) var sourceID: EntityID?
    public private(set) var fieldRegisters: [String: FieldRegister]
    public private(set) var arguments: [String: Value]
    public private(set) var links: Set<EntityReference>
    public let createdBy: OperationID
    public private(set) var tombstone: OperationStamp?

    public init(reference: EntityReference, sourceID: EntityID?, fields: [String: Value], arguments: [String: Value], createdBy: OperationID, stamp: OperationStamp) {
        self.reference = reference
        self.sourceID = sourceID
        self.fieldRegisters = fields.mapValues { FieldRegister(value: $0, stamp: stamp) }
        self.arguments = arguments
        self.links = []
        self.createdBy = createdBy
    }

    public var fields: [String: Value] { fieldRegisters.mapValues(\.value) }
    public var isDeleted: Bool { tombstone != nil }

    mutating func apply(fields: [String: Value], arguments: [String: Value], stamp: OperationStamp) {
        for (key, value) in fields {
            if let current = fieldRegisters[key], current.stamp >= stamp { continue }
            fieldRegisters[key] = FieldRegister(value: value, stamp: stamp)
        }
        if tombstone == nil { self.arguments.merge(arguments) { _, new in new } }
    }

    mutating func delete(stamp: OperationStamp) {
        if tombstone == nil || tombstone! < stamp { tombstone = stamp }
    }

    mutating func link(_ reference: EntityReference) { links.insert(reference) }
    mutating func unlink(_ reference: EntityReference) { links.remove(reference) }
}

public struct SpaceState: Equatable, Sendable {
    public let spaceID: SpaceID
    public private(set) var entities: [EntityReference: EntityState]
    public private(set) var unappliedOperations: [EditOperation]

    public init(spaceID: SpaceID, entities: [EntityReference: EntityState] = [:], unappliedOperations: [EditOperation] = []) {
        self.spaceID = spaceID
        self.entities = entities
        self.unappliedOperations = unappliedOperations
    }

    mutating func set(_ entity: EntityState) { entities[entity.reference] = entity }
    mutating func deferOperation(_ operation: EditOperation) { unappliedOperations.append(operation) }
}

/// The early-v1 source-compatibility spelling for ``SpaceState``.
@available(*, deprecated, renamed: "SpaceState")
public typealias DocumentState = SpaceState
