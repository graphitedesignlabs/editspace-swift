import Foundation

public struct FieldRegister: Codable, Equatable, Sendable {
    public let value: Value
    public let stamp: OperationStamp

    public init(value: Value, stamp: OperationStamp) {
        self.value = value
        self.stamp = stamp
    }
}

public struct EntityIDRegister: Codable, Equatable, Sendable {
    public let value: EntityID?
    public let stamp: OperationStamp

    public init(value: EntityID?, stamp: OperationStamp) {
        self.value = value
        self.stamp = stamp
    }
}

public struct LinkRegister: Codable, Equatable, Sendable {
    public let isLinked: Bool
    public let stamp: OperationStamp

    public init(isLinked: Bool, stamp: OperationStamp) {
        self.isLinked = isLinked
        self.stamp = stamp
    }
}

public struct EntityState: Equatable, Sendable {
    public let reference: EntityReference
    public private(set) var sourceRegister: EntityIDRegister?
    public private(set) var fieldRegisters: [String: FieldRegister]
    public private(set) var argumentRegisters: [String: FieldRegister]
    public private(set) var linkRegisters: [EntityReference: LinkRegister]
    public let createdBy: OperationID
    public let creationStamp: OperationStamp
    public private(set) var updatedBy: OperationID
    public private(set) var updatedStamp: OperationStamp

    public init(reference: EntityReference,
                sourceID: EntityID? = nil,
                fields: [String: Value],
                arguments: [String: Value] = [:],
                createdBy operation: EditOperation) {
        let stamp = operation.stamp
        self.reference = reference
        self.sourceRegister = sourceID.map {
            EntityIDRegister(value: $0, stamp: stamp)
        }
        self.fieldRegisters = fields.mapValues { FieldRegister(value: $0, stamp: stamp) }
        self.argumentRegisters = arguments.mapValues {
            FieldRegister(value: $0, stamp: stamp)
        }
        self.linkRegisters = [:]
        self.createdBy = operation.operationID
        self.creationStamp = stamp
        self.updatedBy = operation.operationID
        self.updatedStamp = stamp
    }

    init(snapshot: StateSnapshotEntity) {
        self.reference = snapshot.reference
        self.sourceRegister = snapshot.sourceRegister
            ?? snapshot.sourceID.map {
                EntityIDRegister(
                    value: $0,
                    stamp: snapshot.updatedStamp ?? snapshot.creationStamp
                )
            }
        self.fieldRegisters = snapshot.fieldRegisters
        self.argumentRegisters = snapshot.argumentRegisters
            ?? snapshot.arguments.mapValues {
                FieldRegister(
                    value: $0,
                    stamp: snapshot.updatedStamp ?? snapshot.creationStamp
                )
            }
        self.linkRegisters = snapshot.linkRegisters.map {
            Dictionary(
                uniqueKeysWithValues: $0.map {
                    (
                        $0.reference,
                        LinkRegister(
                            isLinked: $0.isLinked,
                            stamp: $0.stamp
                        )
                    )
                }
            )
        } ?? Dictionary(
                uniqueKeysWithValues: snapshot.links.map {
                    (
                        $0,
                        LinkRegister(
                            isLinked: true,
                            stamp: snapshot.updatedStamp ?? snapshot.creationStamp
                        )
                    )
                }
            )
        self.createdBy = snapshot.createdBy
        self.creationStamp = snapshot.creationStamp
        self.updatedBy = snapshot.updatedBy
        self.updatedStamp = snapshot.updatedStamp ?? snapshot.creationStamp
    }

    public var sourceID: EntityID? { sourceRegister?.value }

    public var fields: [String: Value] {
        fieldRegisters.mapValues(\.value)
    }

    public var arguments: [String: Value] {
        argumentRegisters.mapValues(\.value)
    }

    public var links: Set<EntityReference> {
        Set(linkRegisters.compactMap { reference, register in
            register.isLinked ? reference : nil
        })
    }

    mutating func updateFields(_ fields: [String: Value], with operation: EditOperation) {
        let stamp = operation.stamp
        var changed = false
        for (key, value) in fields {
            if let existing = fieldRegisters[key], stamp < existing.stamp {
                continue
            }
            fieldRegisters[key] = FieldRegister(value: value, stamp: stamp)
            changed = true
        }
        if changed { recordUpdate(operation) }
    }

    mutating func updateArguments(_ arguments: [String: Value], with operation: EditOperation) {
        let stamp = operation.stamp
        var changed = false
        for (key, value) in arguments {
            if let existing = argumentRegisters[key], stamp < existing.stamp {
                continue
            }
            argumentRegisters[key] = FieldRegister(value: value, stamp: stamp)
            changed = true
        }
        if changed { recordUpdate(operation) }
    }

    mutating func setSourceID(_ sourceID: EntityID?, with operation: EditOperation) {
        let stamp = operation.stamp
        if let existing = sourceRegister, stamp < existing.stamp {
            return
        }
        sourceRegister = EntityIDRegister(value: sourceID, stamp: stamp)
        recordUpdate(operation)
    }

    mutating func addLink(_ reference: EntityReference, with operation: EditOperation) {
        setLink(reference, isLinked: true, with: operation)
    }

    mutating func removeLink(_ reference: EntityReference, with operation: EditOperation) {
        setLink(reference, isLinked: false, with: operation)
    }

    func merging(_ other: EntityState) -> EntityState {
        precondition(reference == other.reference)
        guard creationStamp == other.creationStamp else {
            return creationStamp < other.creationStamp ? other : self
        }

        var merged = self
        merged.sourceRegister = Self.newest(sourceRegister, other.sourceRegister)
        merged.fieldRegisters = Self.merging(fieldRegisters, other.fieldRegisters)
        merged.argumentRegisters = Self.merging(argumentRegisters, other.argumentRegisters)
        merged.linkRegisters = Self.merging(linkRegisters, other.linkRegisters)
        if merged.updatedStamp < other.updatedStamp {
            merged.updatedStamp = other.updatedStamp
            merged.updatedBy = other.updatedBy
        }
        return merged
    }

    private mutating func setLink(
        _ reference: EntityReference,
        isLinked: Bool,
        with operation: EditOperation
    ) {
        let stamp = operation.stamp
        if let existing = linkRegisters[reference], stamp < existing.stamp {
            return
        }
        linkRegisters[reference] = LinkRegister(isLinked: isLinked, stamp: stamp)
        recordUpdate(operation)
    }

    private mutating func recordUpdate(_ operation: EditOperation) {
        guard !(operation.stamp < updatedStamp) else { return }
        updatedBy = operation.operationID
        updatedStamp = operation.stamp
    }

    private static func newest<T>(
        _ first: T?,
        _ second: T?
    ) -> T? where T: SnapshotRegister {
        guard let first else { return second }
        guard let second else { return first }
        return first.registerStamp < second.registerStamp ? second : first
    }

    private static func merging<Key: Hashable, Register: SnapshotRegister>(
        _ first: [Key: Register],
        _ second: [Key: Register]
    ) -> [Key: Register] {
        var result = first
        for (key, candidate) in second {
            guard let existing = result[key] else {
                result[key] = candidate
                continue
            }
            if existing.registerStamp < candidate.registerStamp {
                result[key] = candidate
            }
        }
        return result
    }
}

private protocol SnapshotRegister {
    var registerStamp: OperationStamp { get }
}

extension FieldRegister: SnapshotRegister {
    fileprivate var registerStamp: OperationStamp { stamp }
}

extension EntityIDRegister: SnapshotRegister {
    fileprivate var registerStamp: OperationStamp { stamp }
}

extension LinkRegister: SnapshotRegister {
    fileprivate var registerStamp: OperationStamp { stamp }
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

    init(snapshot: StateSnapshotTombstone) {
        self.reference = snapshot.reference
        self.deletedBy = snapshot.deletedBy
        self.stamp = snapshot.stamp
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

    public init(snapshot: StateSnapshot) {
        self.spaceID = snapshot.spaceID
        self.entities = Dictionary(
            uniqueKeysWithValues: snapshot.entities.map {
                ($0.reference, EntityState(snapshot: $0))
            }
        )
        self.tombstones = Dictionary(
            uniqueKeysWithValues: snapshot.tombstones.map {
                ($0.reference, Tombstone(snapshot: $0))
            }
        )
        self.conflicts = []
        self.appliedOperationIDs = Set(snapshot.appliedOperationIDs)
        self.skippedOperationIDs = []
        self.unappliedOperations = []
    }

    public mutating func merge(_ snapshot: StateSnapshot) throws {
        guard snapshot.spaceID == spaceID else {
            throw SnapshotJoinError.spaceMismatch(expected: spaceID, actual: snapshot.spaceID)
        }

        for snapshotEntity in snapshot.entities {
            let incoming = EntityState(snapshot: snapshotEntity)
            if let existing = entities[incoming.reference] {
                entities[incoming.reference] = existing.merging(incoming)
            } else {
                entities[incoming.reference] = incoming
            }
        }

        for snapshotTombstone in snapshot.tombstones {
            let incoming = Tombstone(snapshot: snapshotTombstone)
            if let existing = tombstones[incoming.reference],
               !(existing.stamp < incoming.stamp) {
                continue
            }
            tombstones[incoming.reference] = incoming
        }

        appliedOperationIDs.formUnion(snapshot.appliedOperationIDs)
    }

    public var visibleEntities: [EntityReference: EntityState] {
        entities.filter { reference, entity in
            guard let tombstone = tombstones[reference] else { return true }
            return tombstone.stamp < entity.creationStamp
        }
    }

    public func entity(kind: EntityKind, id: EntityID) -> EntityState? {
        entities[EntityReference(kind: kind, id: id)]
    }

    public func isTombstoned(_ reference: EntityReference) -> Bool {
        guard let tombstone = tombstones[reference] else { return false }
        guard let entity = entities[reference] else { return true }
        return !(tombstone.stamp < entity.creationStamp)
    }

    mutating func markApplied(_ operation: EditOperation) {
        appliedOperationIDs.insert(operation.operationID)
        skippedOperationIDs.remove(operation.operationID)
        unappliedOperations.removeAll { $0.operationID == operation.operationID }
        conflicts.removeAll { $0.operationID == operation.operationID }
    }

    mutating func markSkipped(_ operation: EditOperation) {
        if skippedOperationIDs.insert(operation.operationID).inserted {
            unappliedOperations.append(operation)
        }
    }

    var transientlyUnappliedOperations: [EditOperation] {
        let transientIDs = Set(conflicts.compactMap { conflict in
            switch conflict.kind {
            case .missingTarget, .missingSource:
                conflict.operationID
            default:
                nil
            }
        })
        return unappliedOperations.filter { transientIDs.contains($0.operationID) }
    }

    mutating func prepareTransientRetry(_ operation: EditOperation) {
        skippedOperationIDs.remove(operation.operationID)
        unappliedOperations.removeAll { $0.operationID == operation.operationID }
        conflicts.removeAll { conflict in
            conflict.operationID == operation.operationID &&
                (conflict.kind == .missingTarget || conflict.kind == .missingSource)
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
