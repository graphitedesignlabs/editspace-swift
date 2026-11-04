import Foundation

/// A compact, renderer-neutral representation of the current resolved scene.
///
/// Snapshots transfer winning state, register stamps, and tombstones without
/// replaying the transaction history that produced them.
public struct StateSnapshot: Codable, Equatable, Sendable {
    public static let kind = "editspace-state-snapshot"
    public static let currentSchemaVersion = 2

    public let kind: String
    public let schemaVersion: Int
    public let spaceID: SpaceID
    public let entities: [StateSnapshotEntity]
    public let tombstones: [StateSnapshotTombstone]
    public let appliedOperationIDs: [OperationID]

    public init(state: SpaceState) {
        self.kind = Self.kind
        self.schemaVersion = Self.currentSchemaVersion
        self.spaceID = state.spaceID
        self.entities = state.entities.values
            .map(StateSnapshotEntity.init)
            .sorted { $0.reference < $1.reference }
        self.tombstones = state.tombstones.values
            .map(StateSnapshotTombstone.init)
            .sorted { $0.reference < $1.reference }
        self.appliedOperationIDs = state.appliedOperationIDs.sorted()
    }

    /// Returns the same resolved state addressed through a negotiated space alias.
    public func resolvingSpace(to spaceID: SpaceID) -> StateSnapshot {
        StateSnapshot(
            kind: kind,
            schemaVersion: schemaVersion,
            spaceID: spaceID,
            entities: entities,
            tombstones: tombstones,
            appliedOperationIDs: appliedOperationIDs
        )
    }

    /// Joins two snapshots of the same space without replaying their operation
    /// histories. The result is deterministic, commutative, associative, and
    /// idempotent for snapshots produced from valid EditSpace replicas.
    public func merging(_ other: StateSnapshot) throws -> StateSnapshot {
        var state = SpaceState(snapshot: self)
        try state.merge(other)
        return StateSnapshot(state: state)
    }

    private init(
        kind: String,
        schemaVersion: Int,
        spaceID: SpaceID,
        entities: [StateSnapshotEntity],
        tombstones: [StateSnapshotTombstone],
        appliedOperationIDs: [OperationID]
    ) {
        self.kind = kind
        self.schemaVersion = schemaVersion
        self.spaceID = spaceID
        self.entities = entities
        self.tombstones = tombstones
        self.appliedOperationIDs = appliedOperationIDs
    }

    private enum CodingKeys: String, CodingKey {
        case kind, schemaVersion = "v", spaceID = "doc"
        case entities, tombstones, appliedOperationIDs = "applied"
    }
}

public struct StateSnapshotEntity: Codable, Equatable, Sendable {
    public let reference: EntityReference
    public let sourceID: EntityID?
    public let sourceRegister: EntityIDRegister?
    public let fieldRegisters: [String: FieldRegister]
    public let arguments: [String: Value]
    public let argumentRegisters: [String: FieldRegister]?
    public let links: [EntityReference]
    public let linkRegisters: [StateSnapshotLinkRegister]?
    public let createdBy: OperationID
    public let creationStamp: OperationStamp
    public let updatedBy: OperationID
    public let updatedStamp: OperationStamp?

    public init(_ entity: EntityState) {
        self.reference = entity.reference
        self.sourceID = entity.sourceID
        self.sourceRegister = entity.sourceRegister
        self.fieldRegisters = entity.fieldRegisters
        self.arguments = entity.arguments
        self.argumentRegisters = entity.argumentRegisters
        self.links = entity.links.sorted()
        self.linkRegisters = entity.linkRegisters
            .map { reference, register in
                StateSnapshotLinkRegister(
                    reference: reference,
                    isLinked: register.isLinked,
                    stamp: register.stamp
                )
            }
            .sorted { $0.reference < $1.reference }
        self.createdBy = entity.createdBy
        self.creationStamp = entity.creationStamp
        self.updatedBy = entity.updatedBy
        self.updatedStamp = entity.updatedStamp
    }
}

public struct StateSnapshotLinkRegister: Codable, Equatable, Sendable {
    public let reference: EntityReference
    public let isLinked: Bool
    public let stamp: OperationStamp

    public init(
        reference: EntityReference,
        isLinked: Bool,
        stamp: OperationStamp
    ) {
        self.reference = reference
        self.isLinked = isLinked
        self.stamp = stamp
    }
}

public struct StateSnapshotTombstone: Codable, Equatable, Sendable {
    public let reference: EntityReference
    public let deletedBy: OperationID
    public let stamp: OperationStamp

    public init(_ tombstone: Tombstone) {
        self.reference = tombstone.reference
        self.deletedBy = tombstone.deletedBy
        self.stamp = tombstone.stamp
    }
}

public enum StateSnapshotCodec {
    public static func encode(_ snapshot: StateSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(snapshot)
    }

    public static func decode(_ data: Data) throws -> StateSnapshot {
        let snapshot = try JSONDecoder().decode(StateSnapshot.self, from: data)
        guard snapshot.kind == StateSnapshot.kind else {
            throw CodecError.wrongMessageKind(snapshot.kind)
        }
        guard snapshot.schemaVersion <= StateSnapshot.currentSchemaVersion else {
            throw CodecError.unsupportedEnvelopeSchema(snapshot.schemaVersion)
        }
        return snapshot
    }
}

public enum SnapshotJoinError: Error, Equatable, Sendable {
    case spaceMismatch(expected: SpaceID, actual: SpaceID)
}
