import Foundation

public struct FieldRegister: Equatable, Sendable {
    public let value: Value
    public let stamp: OperationStamp

    public init(value: Value, stamp: OperationStamp) {
        self.value = value
        self.stamp = stamp
    }
}

public struct EntityState: Equatable, Sendable {
    public let reference: EntityReference
    public private(set) var sourceID: EntityID?
    public private(set) var fieldRegisters: [String: FieldRegister]
    public private(set) var arguments: [String: Value]
    public private(set) var links: Set<EntityReference>
    public let createdBy: OperationID
    public private(set) var updatedBy: OperationID

    public init(reference: EntityReference,
                sourceID: EntityID? = nil,
                fields: [String: Value],
                arguments: [String: Value] = [:],
                createdBy operation: EditOperation) {
        let stamp = operation.stamp
        self.reference = reference
        self.sourceID = sourceID
        self.fieldRegisters = fields.mapValues { FieldRegister(value: $0, stamp: stamp) }
        self.arguments = arguments
        self.links = []
        self.createdBy = operation.operationID
        self.updatedBy = operation.operationID
    }

    public var fields: [String: Value] {
        fieldRegisters.mapValues(\.value)
    }

    mutating func updateFields(_ fields: [String: Value], with operation: EditOperation) {
        let stamp = operation.stamp
        for (key, value) in fields {
            if let existing = fieldRegisters[key], stamp < existing.stamp {
                continue
            }
            fieldRegisters[key] = FieldRegister(value: value, stamp: stamp)
        }
        updatedBy = operation.operationID
    }

    mutating func updateArguments(_ arguments: [String: Value], with operation: EditOperation) {
        for (key, value) in arguments {
            self.arguments[key] = value
        }
        updatedBy = operation.operationID
    }

    mutating func setSourceID(_ sourceID: EntityID?, with operation: EditOperation) {
        self.sourceID = sourceID
        updatedBy = operation.operationID
    }

    mutating func addLink(_ reference: EntityReference, with operation: EditOperation) {
        links.insert(reference)
        updatedBy = operation.operationID
    }

    mutating func removeLink(_ reference: EntityReference, with operation: EditOperation) {
        links.remove(reference)
        updatedBy = operation.operationID
    }
}

public struct Tombstone: Equatable, Sendable {
    public let reference: EntityReference
    public let deletedBy: OperationID
    public let stamp: OperationStamp

    public init(reference: EntityReference, deletedBy operation: EditOperation) {
        self.reference = reference
        self.deletedBy = operation.operationID
        self.stamp = operation.stamp
    }
}

public enum ConflictKind: String, Equatable, Sendable {
    case compatibility
    case missingTarget
    case missingSource
    case tombstonedTarget
    case duplicateTargetAlreadyExists
    case invalidOperation
}

public struct Conflict: Equatable, Sendable, CustomStringConvertible {
    public let kind: ConflictKind
    public let operationID: OperationID
    public let reference: EntityReference?
    public let message: String
    public let compatibilityProblems: [CompatibilityProblem]

    public init(kind: ConflictKind,
                operationID: OperationID,
                reference: EntityReference? = nil,
                message: String,
                compatibilityProblems: [CompatibilityProblem] = []) {
        self.kind = kind
        self.operationID = operationID
        self.reference = reference
        self.message = message
        self.compatibilityProblems = compatibilityProblems
    }

    public var description: String {
        var parts = ["kind=\(kind.rawValue)", "op=\(operationID.rawValue)", "message=\(message)"]
        if let reference { parts.append("entity=\(reference.description)") }
        if !compatibilityProblems.isEmpty {
            parts.append("compat=\(compatibilityProblems.map(\.description).joined(separator: "|"))")
        }
        return parts.joined(separator: " ")
    }
}

public struct SpaceState: Equatable, Sendable {
    public let spaceID: SpaceID
    public private(set) var entities: [EntityReference: EntityState]
    public private(set) var tombstones: [EntityReference: Tombstone]
    public private(set) var conflicts: [Conflict]
    public private(set) var appliedOperationIDs: Set<OperationID>
    public private(set) var skippedOperationIDs: Set<OperationID>
    /// Operations preserved by the log but not understood or applicable by this materializer.
    public private(set) var unappliedOperations: [EditOperation]

    public init(spaceID: SpaceID) {
        self.spaceID = spaceID
        self.entities = [:]
        self.tombstones = [:]
        self.conflicts = []
        self.appliedOperationIDs = []
        self.skippedOperationIDs = []
        self.unappliedOperations = []
    }

    public var visibleEntities: [EntityReference: EntityState] {
        entities.filter { tombstones[$0.key] == nil }
    }

    public func entity(kind: EntityKind, id: EntityID) -> EntityState? {
        entities[EntityReference(kind: kind, id: id)]
    }

    public func isTombstoned(_ reference: EntityReference) -> Bool {
        tombstones[reference] != nil
    }

    mutating func markApplied(_ operation: EditOperation) {
        appliedOperationIDs.insert(operation.operationID)
    }

    mutating func markSkipped(_ operation: EditOperation) {
        if skippedOperationIDs.insert(operation.operationID).inserted {
            unappliedOperations.append(operation)
        }
    }

    mutating func addConflict(_ conflict: Conflict) {
        conflicts.append(conflict)
    }

    mutating func upsertEntity(_ entity: EntityState) {
        entities[entity.reference] = entity
    }

    mutating func tombstone(_ reference: EntityReference, with operation: EditOperation) {
        if let existing = tombstones[reference], operation.stamp < existing.stamp {
            return
        }
        tombstones[reference] = Tombstone(reference: reference, deletedBy: operation)
    }
}

@available(*, deprecated, renamed: "SpaceState")
public typealias DocumentState = SpaceState
