import Testing
@testable import EditSpace

private let joinSpaceID = SpaceID(rawValue: "snapshot-join")
private let joinObjectID = EntityID(rawValue: "object")

private func joinOperation(
    actor: String,
    sequence: Int64,
    action: OperationAction,
    entity: EntityKind = .object,
    targetID: EntityID = joinObjectID,
    sourceID: EntityID? = nil,
    fields: [String: Value] = [:],
    arguments: [String: Value] = [:]
) -> EditOperation {
    EditOperation(
        spaceID: joinSpaceID,
        actorID: ActorID(rawValue: actor),
        sequence: sequence,
        action: action,
        entity: entity,
        targetID: targetID,
        sourceID: sourceID,
        fields: fields,
        arguments: arguments,
        createdAt: nil
    )
}

private func snapshot(_ operations: [EditOperation]) -> StateSnapshot {
    StateSnapshot(
        state: Materializer().materialize(
            spaceID: joinSpaceID,
            operations: operations
        )
    )
}

@Test func replicaExportsCurrentSnapshot() {
    let create = joinOperation(
        actor: "actor",
        sequence: 1,
        action: .create,
        fields: ["name": .string("Cube")]
    )
    let replica = Replica(
        spaceID: joinSpaceID,
        bindings: ReplicaBindings(
            create: { _ in },
            update: { _, _, _ in },
            delete: { _ in },
            setLink: { _, _, _ in }
        )
    )

    replica.apply([create])
    let exported = replica.snapshot()

    #expect(exported.spaceID == joinSpaceID)
    #expect(exported.appliedOperationIDs == [create.operationID])
    #expect(exported.entities.first?.reference.id == joinObjectID)
}

@Test func snapshotJoinIsCommutativeAssociativeAndIdempotent() throws {
    let create = joinOperation(
        actor: "origin",
        sequence: 1,
        action: .create,
        fields: ["name": .string("Original"), "width": .number(1)]
    )
    let rename = joinOperation(
        actor: "ios",
        sequence: 2,
        action: .update,
        fields: ["name": .string("Renamed")]
    )
    let resize = joinOperation(
        actor: "vision",
        sequence: 3,
        action: .update,
        fields: ["width": .number(4)]
    )
    let recolor = joinOperation(
        actor: "cloud",
        sequence: 4,
        action: .update,
        fields: ["color": .string("blue")]
    )

    let a = snapshot([create, rename])
    let b = snapshot([create, resize])
    let c = snapshot([create, recolor])

    let ab = try a.merging(b)
    let ba = try b.merging(a)
    let leftAssociated = try ab.merging(c)
    let rightAssociated = try a.merging(b.merging(c))
    let idempotent = try leftAssociated.merging(leftAssociated)

    #expect(ab == ba)
    #expect(leftAssociated == rightAssociated)
    #expect(idempotent == leftAssociated)

    let state = SpaceState(snapshot: leftAssociated)
    let reference = EntityReference(kind: .object, id: joinObjectID)
    #expect(state.entities[reference]?.fields["name"] == .string("Renamed"))
    #expect(state.entities[reference]?.fields["width"] == .number(4))
    #expect(state.entities[reference]?.fields["color"] == .string("blue"))
}

@Test func snapshotJoinPreservesTombstonesAgainstStaleState() throws {
    let create = joinOperation(
        actor: "origin",
        sequence: 1,
        action: .create,
        fields: ["name": .string("Object")]
    )
    let staleUpdate = joinOperation(
        actor: "offline",
        sequence: 2,
        action: .update,
        fields: ["name": .string("Stale")]
    )
    let delete = joinOperation(actor: "cloud", sequence: 3, action: .delete)

    let merged = try snapshot([create, staleUpdate]).merging(snapshot([create, delete]))
    let state = SpaceState(snapshot: merged)
    let reference = EntityReference(kind: .object, id: joinObjectID)

    #expect(state.visibleEntities[reference] == nil)
    #expect(state.tombstones[reference]?.deletedBy == delete.operationID)
}

@Test func snapshotJoinKeepsConcurrentLinksAndUnlinkTombstones() throws {
    let firstTarget = EntityID(rawValue: "first-target")
    let secondTarget = EntityID(rawValue: "second-target")
    let createObject = joinOperation(actor: "origin", sequence: 1, action: .create)
    let createFirst = joinOperation(
        actor: "origin",
        sequence: 2,
        action: .create,
        targetID: firstTarget
    )
    let createSecond = joinOperation(
        actor: "origin",
        sequence: 3,
        action: .create,
        targetID: secondTarget
    )
    let linkFirst = joinOperation(
        actor: "ios",
        sequence: 4,
        action: .link,
        sourceID: firstTarget
    )
    let linkSecond = joinOperation(
        actor: "vision",
        sequence: 5,
        action: .link,
        sourceID: secondTarget
    )
    let unlinkFirst = joinOperation(
        actor: "cloud",
        sequence: 6,
        action: .unlink,
        sourceID: firstTarget
    )
    let base = [createObject, createFirst, createSecond]

    let concurrentLinks = try snapshot(base + [linkFirst])
        .merging(snapshot(base + [linkSecond]))
    let unlinked = try concurrentLinks
        .merging(snapshot(base + [linkFirst, unlinkFirst]))
    let state = SpaceState(snapshot: unlinked)
    let objectReference = EntityReference(kind: .object, id: joinObjectID)
    let firstReference = EntityReference(kind: .object, id: firstTarget)
    let secondReference = EntityReference(kind: .object, id: secondTarget)

    #expect(state.entities[objectReference]?.links.contains(firstReference) == false)
    #expect(state.entities[objectReference]?.links.contains(secondReference) == true)
}

@Test func replicaSnapshotJoinProjectsOnlyWinningChangesOnce() throws {
    let create = joinOperation(
        actor: "origin",
        sequence: 1,
        action: .create,
        fields: ["name": .string("Original")]
    )
    let update = joinOperation(
        actor: "cloud",
        sequence: 2,
        action: .update,
        fields: ["name": .string("Cloud")]
    )
    var created = 0
    var updated = 0
    let replica = Replica(
        spaceID: joinSpaceID,
        bindings: ReplicaBindings(
            create: { _ in created += 1 },
            update: { _, _, _ in updated += 1 },
            delete: { _ in },
            setLink: { _, _, _ in }
        )
    )

    _ = replica.apply([create])
    let first = replica.merge(snapshot([create, update]))
    let second = replica.merge(snapshot([create, update]))

    #expect(first.failures.isEmpty)
    #expect(second.failures.isEmpty)
    #expect(created == 1)
    #expect(updated == 1)
    #expect(
        replica.entity(kind: .object, id: joinObjectID)?
            .fields["name"] == .string("Cloud")
    )
}

@Test func snapshotJoinRejectsDifferentSpaces() throws {
    let local = snapshot([])
    let foreign = StateSnapshot(
        state: SpaceState(spaceID: SpaceID(rawValue: "foreign"))
    )

    #expect(throws: SnapshotJoinError.self) {
        _ = try local.merging(foreign)
    }
}
