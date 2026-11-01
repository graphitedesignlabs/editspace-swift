import Foundation
import Testing
@testable import EditSpace

private let spaceID = SpaceID(rawValue: "scene")
private let objectID = EntityID(rawValue: "cube")

private func operation(
    actor: String,
    sequence: Int64,
    action: OperationAction,
    fields: [String: Value] = [:],
    dependencies: [OperationID] = []
) -> EditOperation {
    EditOperation(
        spaceID: spaceID,
        actorID: ActorID(rawValue: actor),
        sequence: sequence,
        dependencies: dependencies,
        action: action,
        entity: .object,
        targetID: objectID,
        fields: fields,
        createdAt: nil
    )
}

@Test func operationEnvelopeRoundTripsAsCanonicalJSON() throws {
    let create = operation(actor: "a", sequence: 1, action: .create, fields: ["name": .string("Cube")])
    let envelope = OperationEnvelope(spaceID: spaceID, operations: [create])
    let data = try OperationCodec.encode(envelope)
    #expect(try OperationCodec.decode(data) == envelope)
    #expect(String(decoding: data, as: UTF8.self).contains("\"kind\":\"editspace.operations\""))
}

@Test func concurrentUpdatesConvergeRegardlessOfArrivalOrder() {
    let create = operation(actor: "a", sequence: 1, action: .create, fields: ["x": .number(0)])
    let updateA = operation(actor: "a", sequence: 2, action: .update, fields: ["x": .number(1)])
    let updateB = operation(actor: "b", sequence: 2, action: .update, fields: ["x": .number(2)])
    var first = OperationLog(spaceID: spaceID)
    var second = OperationLog(spaceID: spaceID)
    [create, updateA, updateB].forEach { _ = first.append($0) }
    [updateB, create, updateA].forEach { _ = second.append($0) }
    #expect(Materializer.materialize(first) == Materializer.materialize(second))
    let reference = EntityReference(kind: .object, id: objectID)
    #expect(Materializer.materialize(first).entities[reference]?.fields["x"] == .number(2))
}

@Test func newerCreateRestoresDeletedEntityRegardlessOfArrivalOrder() {
    let create = operation(
        actor: "a",
        sequence: 1,
        action: .create,
        fields: ["name": .string("Original"), "obsolete": .bool(true)]
    )
    let delete = operation(
        actor: "a",
        sequence: 2,
        action: .delete,
        dependencies: [create.operationID]
    )
    let restore = operation(
        actor: "a",
        sequence: 3,
        action: .create,
        fields: ["name": .string("Restored")],
        dependencies: [delete.operationID]
    )
    let reference = EntityReference(kind: .object, id: objectID)

    let ordered = Materializer().materialize(
        spaceID: spaceID,
        operations: [create, delete, restore]
    )
    let shuffled = Materializer().materialize(
        spaceID: spaceID,
        operations: [restore, create, delete]
    )

    #expect(ordered == shuffled)
    #expect(ordered.visibleEntities[reference]?.fields["name"] == .string("Restored"))
    #expect(ordered.visibleEntities[reference]?.fields["obsolete"] == nil)
    #expect(ordered.tombstones[reference]?.deletedBy == delete.operationID)
}

@Test func staleCreateCannotRestoreDeletedEntity() {
    let staleCreate = operation(actor: "a", sequence: 1, action: .create)
    let delete = operation(actor: "a", sequence: 2, action: .delete)
    let reference = EntityReference(kind: .object, id: objectID)
    var state = SpaceState(spaceID: spaceID)
    let materializer = Materializer()

    materializer.materialize(operations: [delete], onto: &state)
    materializer.materialize(operations: [staleCreate], onto: &state)

    #expect(state.visibleEntities[reference] == nil)
    #expect(state.skippedOperationIDs.contains(staleCreate.operationID))
}

@Test func duplicatesAreIdempotentAndCollisionsAreRejected() {
    let create = operation(actor: "a", sequence: 1, action: .create)
    var log = OperationLog(spaceID: spaceID)
    #expect(log.append(create) == .accepted)
    #expect(log.append(create) == .duplicate)
    let collision = operation(actor: "a", sequence: 1, action: .create, fields: ["x": .number(1)])
    guard case .rejected(let problems) = log.append(collision) else {
        Issue.record("Expected an operation ID collision")
        return
    }
    #expect(problems.first?.kind == .operationIDCollision)
}

@Test func peerPresenceExpiresAndDoesNotEnterOperationLog() {
    let now = Date(timeIntervalSince1970: 100)
    let identity = PeerIdentity(peerID: "peer-a", actorID: ActorID(rawValue: "a"), displayName: "Ada")
    let presence = PeerPresence(identity: identity, sessionID: SessionID(rawValue: "session"), sequence: 1, updatedAt: now, timeToLiveSeconds: 10)
    var roster = PresenceRoster()
    let didMerge = roster.merge(presence, now: now)
    #expect(didMerge)
    roster.removeExpired(at: now.addingTimeInterval(11))
    #expect(roster.presences.isEmpty)
}

@Test func presenceEnvelopeRoundTrips() throws {
    let identity = PeerIdentity(peerID: "peer-a", actorID: ActorID(rawValue: "a"), displayName: "Ada")
    let presence = PeerPresence(
        identity: identity,
        sessionID: SessionID(rawValue: "session"),
        sequence: 1,
        updatedAt: Date(timeIntervalSince1970: 1_788_460_800)
    )
    let envelope = PresenceEnvelope(spaceID: spaceID, presence: presence)
    #expect(try PresenceCodec.decode(PresenceCodec.encode(envelope)) == envelope)
}

@Test func omittedOptionalOperationCollectionsUseProtocolDefaults() throws {
    let json = #"{"kind":"editspace.operations","v":1,"doc":"scene","ops":[{"doc":"scene","op":"a:1","actor":"a","seq":1,"action":"create","entity":"object","target":"cube"}]}"#
    let envelope = try OperationCodec.decode(Data(json.utf8))
    #expect(envelope.operations[0].dependencies.isEmpty)
    #expect(envelope.operations[0].fields.isEmpty)
    #expect(envelope.operations[0].arguments.isEmpty)
    #expect(envelope.operations[0].requiredFeatures.isEmpty)
}

@Test func syncEngineRoutesAcceptedOperationsBySource() {
    let create = operation(actor: "a", sequence: 1, action: .create)
    var engine = SyncEngine(spaceID: spaceID)
    let result = engine.append([create], source: .local)
    #expect(result.accepted == [create.operationID])
    #expect(engine.pendingPeerOperationIDs == [create.operationID])
    #expect(engine.pendingStoreOperationIDs == [create.operationID])
}

@Test func sharedSpaceSceneFieldsValidate() {
    let transform = Value.matrix4([
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 1, 0, 1
    ])
    guard let transform else {
        Issue.record("Expected a valid 4×4 transform")
        return
    }
    let create = EditOperation(
        spaceID: spaceID,
        actorID: ActorID(rawValue: "a"),
        sequence: 1,
        action: .create,
        entity: .object,
        targetID: objectID,
        fields: [
            SceneField.objectType.rawValue: .string("mesh"),
            SceneField.transform.rawValue: transform
        ],
        requiredFeatures: [.scene3DV1],
        createdAt: nil
    )
    #expect(create.spaceID == spaceID)
    #expect(SceneFieldValidator.errors(for: create).isEmpty)
}

@Test func malformedTransformAndMeshIndicesAreRejected() {
    let malformedTransform = EditOperation(
        spaceID: spaceID,
        actorID: ActorID(rawValue: "a"),
        sequence: 1,
        action: .create,
        entity: .object,
        targetID: objectID,
        fields: [SceneField.transform.rawValue: .array([.number(1)])],
        requiredFeatures: [.scene3DV1],
        createdAt: nil
    )
    #expect(!SceneFieldValidator.errors(for: malformedTransform).isEmpty)

    let malformedMesh = EditOperation(
        spaceID: spaceID,
        actorID: ActorID(rawValue: "a"),
        sequence: 2,
        action: .create,
        entity: .mesh,
        targetID: EntityID(rawValue: "mesh"),
        fields: [
            SceneField.positions.rawValue: .array([.vector3(0, 0, 0), .vector3(1, 0, 0), .vector3(0, 1, 0)]),
            SceneField.faces.rawValue: .array([.array([.number(0), .number(1), .number(3)])])
        ],
        requiredFeatures: [.scene3DV1, .meshV1],
        createdAt: nil
    )
    #expect(!SceneFieldValidator.errors(for: malformedMesh).isEmpty)
}

@Test func generativeModifierVocabularyValidatesLifecycleOperations() {
    let modifierID = EntityID(rawValue: "generate-1")
    let worker = ActorID(rawValue: "worker")
    let claimID = OperationID(actorID: worker, sequence: 1)
    let bounds = GenerativeBounds(minimum: [-1, 0, -1], maximum: [1, 2, 1])
    let requestFields = GenerativeModifierFields.request(
        objectID: objectID,
        prompt: "A low-poly fox",
        bounds: bounds
    )
    #expect(requestFields != nil)

    let request = EditOperation(
        spaceID: spaceID,
        actorID: ActorID(rawValue: "author"),
        sequence: 1,
        action: .create,
        entity: .modifier,
        targetID: modifierID,
        fields: requestFields ?? [:],
        requiredFeatures: [.coreV1, .modifiersV1],
        createdAt: nil
    )
    let claim = EditOperation(
        spaceID: spaceID,
        actorID: worker,
        sequence: 1,
        dependencies: [request.operationID],
        action: .update,
        entity: .modifier,
        targetID: modifierID,
        fields: GenerativeModifierFields.claim(actorID: worker, claimID: claimID),
        requiredFeatures: [.coreV1, .modifiersV1],
        createdAt: nil
    )
    let completion = EditOperation(
        spaceID: spaceID,
        actorID: worker,
        sequence: 2,
        dependencies: [claim.operationID],
        action: .update,
        entity: .modifier,
        targetID: modifierID,
        fields: GenerativeModifierFields.success(
            claimID: claim.operationID,
            resultMeshID: EntityID(rawValue: "generated-mesh")
        ),
        requiredFeatures: [.coreV1, .modifiersV1],
        createdAt: nil
    )

    #expect(SceneFieldValidator.errors(for: request).isEmpty)
    #expect(SceneFieldValidator.errors(for: claim).isEmpty)
    #expect(SceneFieldValidator.errors(for: completion).isEmpty)

    let failure = EditOperation(
        spaceID: spaceID,
        actorID: worker,
        sequence: 3,
        dependencies: [claim.operationID],
        action: .update,
        entity: .modifier,
        targetID: modifierID,
        fields: GenerativeModifierFields.failure(
            claimID: claim.operationID,
            error: "Generator could not produce a valid mesh"
        ) ?? [:],
        requiredFeatures: [.coreV1, .modifiersV1],
        createdAt: nil
    )
    #expect(SceneFieldValidator.errors(for: failure).isEmpty)

    let malformedClaim = EditOperation(
        spaceID: spaceID,
        actorID: worker,
        sequence: 3,
        action: .update,
        entity: .modifier,
        targetID: modifierID,
        fields: GenerativeModifierFields.claim(
            actorID: ActorID(rawValue: "different-worker"),
            claimID: OperationID(actorID: worker, sequence: 3)
        ),
        createdAt: nil
    )
    #expect(!SceneFieldValidator.errors(for: malformedClaim).isEmpty)
}

@Test func concurrentGenerativeClaimsConvergeByOperationStamp() {
    let modifierID = EntityID(rawValue: "generate-1")
    let request = EditOperation(
        spaceID: spaceID,
        actorID: ActorID(rawValue: "author"),
        sequence: 1,
        action: .create,
        entity: .modifier,
        targetID: modifierID,
        fields: GenerativeModifierFields.request(objectID: objectID, prompt: "A twelve-tooth gear") ?? [:],
        createdAt: nil
    )
    func claim(actor: String) -> EditOperation {
        let actorID = ActorID(rawValue: actor)
        let claimID = OperationID(actorID: actorID, sequence: 2)
        return EditOperation(
            spaceID: spaceID,
            actorID: actorID,
            sequence: 2,
            dependencies: [request.operationID],
            action: .update,
            entity: .modifier,
            targetID: modifierID,
            fields: GenerativeModifierFields.claim(actorID: actorID, claimID: claimID),
            createdAt: nil
        )
    }
    let claimA = claim(actor: "worker-a")
    let claimB = claim(actor: "worker-b")
    let state = Materializer().materialize(
        spaceID: spaceID,
        operations: [claimB, request, claimA]
    )
    let modifier = state.entity(kind: .modifier, id: modifierID)

    #expect(modifier?.fields[SceneField.status.rawValue] == .string(GenerativeModifierStatus.running.rawValue))
    #expect(modifier?.fields[SceneField.claimant.rawValue] == .string("worker-b"))
    #expect(modifier?.fields[SceneField.claimID.rawValue] == .string("worker-b:2"))
}

@Test func unsupportedOperationsArePreservedWithoutBeingMaterialized() {
    let unsupported = operation(
        actor: "a",
        sequence: 1,
        action: OperationAction(rawValue: "futureAction")
    )
    var log = OperationLog(spaceID: spaceID)

    guard case .storedWithCompatibilityProblems(let problems) = log.append(unsupported) else {
        Issue.record("Expected an unsupported operation to be preserved")
        return
    }

    #expect(problems.contains { $0.kind == .unsupportedAction })
    #expect(log.operations == [unsupported])

    let state = log.materialize()
    #expect(state.unappliedOperations == [unsupported])
    #expect(state.visibleEntities.isEmpty)
}

@Test func replicaBindingsProjectOnlyResolvedChanges() {
    let create = operation(
        actor: "a",
        sequence: 1,
        action: .create,
        fields: ["name": .string("Cube"), "x": .number(0)]
    )
    let newestUpdate = operation(
        actor: "a",
        sequence: 3,
        action: .update,
        fields: ["x": .number(3)]
    )
    let staleUpdate = operation(
        actor: "b",
        sequence: 2,
        action: .update,
        fields: ["x": .number(2)]
    )
    var events: [String] = []
    var projectedFields: [EntityReference: [String: Value]] = [:]
    let bindings = ReplicaBindings(
        create: { reference, _, fields, _ in
            projectedFields[reference] = fields
            events.append("create:\(reference)")
        },
        update: { reference, fields, _ in
            projectedFields[reference, default: [:]].merge(fields) { _, newValue in newValue }
            events.append("update:\(reference)")
        },
        delete: { reference in
            projectedFields.removeValue(forKey: reference)
            events.append("delete:\(reference)")
        },
        setLink: { reference, linkedReference, isLinked in
            events.append("link:\(reference):\(linkedReference):\(isLinked)")
        }
    )
    let replica = Replica(spaceID: spaceID, bindings: bindings)

    let initialReport = replica.apply([create, newestUpdate])
    #expect(initialReport.failures.isEmpty)
    #expect(events.count == 2)

    events.removeAll()
    let staleReport = replica.apply([staleUpdate])
    #expect(staleReport.failures.isEmpty)
    #expect(events.isEmpty)

    let reference = EntityReference(kind: .object, id: objectID)
    #expect(projectedFields[reference]?["x"] == .number(3))
}

@Test func replicaMutationContextIncludesOriginAndResolvedEntity() {
    let create = operation(
        actor: "a",
        sequence: 1,
        action: .create,
        fields: ["name": .string("Cube"), "x": .number(0)]
    )
    let update = operation(
        actor: "b",
        sequence: 2,
        action: .update,
        fields: ["x": .number(2)]
    )
    var contexts: [ReplicaMutationContext] = []
    var changedFields: [[String: Value]] = []
    let bindings = ReplicaBindings(
        create: { context in
            contexts.append(context)
        },
        update: { context, fields, _ in
            contexts.append(context)
            changedFields.append(fields)
        },
        delete: { _ in },
        setLink: { _, _, _ in }
    )
    let replica = Replica(spaceID: spaceID, bindings: bindings)

    let report = replica.apply([create, update])

    #expect(report.failures.isEmpty)
    #expect(contexts.map(\.operationID) == [create.operationID, update.operationID])
    #expect(contexts.last?.fields["name"] == .string("Cube"))
    #expect(contexts.last?.fields["x"] == .number(2))
    #expect(contexts.last?.fieldStamps["name"] == create.stamp)
    #expect(contexts.last?.fieldStamps["x"] == update.stamp)
    #expect(changedFields == [["x": .number(2)]])

    contexts.removeAll()
    let replayReport = replica.replay()
    #expect(replayReport.failures.isEmpty)
    #expect(contexts.count == 1)
    #expect(contexts.last?.operation == nil)
    #expect(contexts.last?.fieldStamps["name"] == create.stamp)
    #expect(contexts.last?.fieldStamps["x"] == update.stamp)
}

@Test func replicaReplayCreatesSourcesBeforeDependantsAndLinksLast() {
    let createObject = operation(
        actor: "a",
        sequence: 1,
        action: .create,
        fields: ["name": .string("Cube")]
    )
    let modifierID = EntityID(rawValue: "modifier")
    let createModifier = EditOperation(
        spaceID: spaceID,
        actorID: ActorID(rawValue: "a"),
        sequence: 2,
        dependencies: [createObject.operationID],
        action: .create,
        entity: .modifier,
        targetID: modifierID,
        sourceID: objectID,
        fields: ["kind": .string("box")],
        arguments: ["sourceEntity": .string(EntityKind.object.rawValue)],
        createdAt: nil
    )
    let linkModifier = EditOperation(
        spaceID: spaceID,
        actorID: ActorID(rawValue: "a"),
        sequence: 3,
        dependencies: [createModifier.operationID],
        action: .link,
        entity: .object,
        targetID: objectID,
        sourceID: modifierID,
        arguments: ["sourceEntity": .string(EntityKind.modifier.rawValue)],
        createdAt: nil
    )
    let inertBindings = ReplicaBindings(
        create: { (_: ReplicaMutationContext) in },
        update: { (_: ReplicaMutationContext, _: [String: Value], _: [String: Value]) in },
        delete: { (_: ReplicaMutationContext) in },
        setLink: { (_: ReplicaMutationContext, _: EntityReference, _: Bool) in }
    )
    let replica = Replica(spaceID: spaceID, bindings: inertBindings)
    _ = replica.apply([createObject, createModifier, linkModifier])

    var createdReferences: [EntityReference] = []
    var linkSawEveryEntity = false
    let report = replica.attach(ReplicaBindings(
        create: { context in
            createdReferences.append(context.reference)
        },
        update: { _, _, _ in },
        delete: { _ in },
        setLink: { _, _, _ in
            linkSawEveryEntity = createdReferences.count == 2
        }
    ))

    #expect(report.failures.isEmpty)
    #expect(createdReferences == [
        EntityReference(kind: .object, id: objectID),
        EntityReference(kind: .modifier, id: modifierID)
    ])
    #expect(linkSawEveryEntity)
}

@Test func stateSnapshotRoundTripsResolvedRegistersAndTombstones() throws {
    let retainedID = EntityID(rawValue: "retained")
    let deletedID = EntityID(rawValue: "deleted")
    let createRetained = EditOperation(
        spaceID: spaceID,
        actorID: ActorID(rawValue: "ios"),
        sequence: 1,
        action: .create,
        entity: .object,
        targetID: retainedID,
        fields: ["name": .string("Retained"), "x": .number(1)],
        createdAt: nil
    )
    let updateRetained = EditOperation(
        spaceID: spaceID,
        actorID: ActorID(rawValue: "vision"),
        sequence: 2,
        action: .update,
        entity: .object,
        targetID: retainedID,
        fields: ["x": .number(2)],
        createdAt: nil
    )
    let createDeleted = EditOperation(
        spaceID: spaceID,
        actorID: ActorID(rawValue: "ios"),
        sequence: 3,
        action: .create,
        entity: .object,
        targetID: deletedID,
        createdAt: nil
    )
    let delete = EditOperation(
        spaceID: spaceID,
        actorID: ActorID(rawValue: "ios"),
        sequence: 4,
        dependencies: [createDeleted.operationID],
        action: .delete,
        entity: .object,
        targetID: deletedID,
        createdAt: nil
    )
    let original = Materializer().materialize(
        spaceID: spaceID,
        operations: [createRetained, updateRetained, createDeleted, delete]
    )

    let encoded = try StateSnapshotCodec.encode(StateSnapshot(state: original))
    let wire = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let wireEntities = try #require(wire["entities"] as? [[String: Any]])
    let wireRetainedEntity = try #require(wireEntities.first { entity in
        let reference = entity["reference"] as? [String: Any]
        return reference?["id"] as? String == retainedID.rawValue
    })
    let wireRegisters = try #require(wireRetainedEntity["fieldRegisters"] as? [String: Any])
    let wireXRegister = try #require(wireRegisters["x"] as? [String: Any])
    let wireStamp = try #require(wireXRegister["stamp"] as? [String: Any])
    #expect(wire["kind"] as? String == StateSnapshot.kind)
    #expect(wire["v"] as? Int == StateSnapshot.currentSchemaVersion)
    #expect(wire["doc"] as? String == spaceID.rawValue)
    #expect(wireStamp["seq"] as? Int == Int(updateRetained.sequence))
    #expect(wireStamp["actor"] as? String == updateRetained.actorID.rawValue)
    #expect(wireStamp["op"] as? String == updateRetained.operationID.rawValue)
    let decoded = try StateSnapshotCodec.decode(encoded)
    let restored = SpaceState(snapshot: decoded)
    let retainedReference = EntityReference(kind: .object, id: retainedID)
    let deletedReference = EntityReference(kind: .object, id: deletedID)

    #expect(restored == original)
    #expect(restored.entities[retainedReference]?.fields["x"] == .number(2))
    #expect(restored.entities[retainedReference]?.fieldRegisters["x"]?.stamp == updateRetained.stamp)
    #expect(restored.visibleEntities[deletedReference] == nil)
    #expect(restored.tombstones[deletedReference]?.deletedBy == delete.operationID)

    let negotiatedSpaceID = SpaceID(rawValue: "negotiated")
    let rebased = decoded.resolvingSpace(to: negotiatedSpaceID)
    #expect(rebased.spaceID == negotiatedSpaceID)
    #expect(rebased.entities == decoded.entities)
    #expect(rebased.tombstones == decoded.tombstones)
    #expect(rebased.appliedOperationIDs == decoded.appliedOperationIDs)
}

@Test func replicaSnapshotReplacementDeletesStaleProjectionAndReplaysResolvedState() {
    let staleID = EntityID(rawValue: "stale")
    let retainedID = EntityID(rawValue: "retained")
    let staleCreate = EditOperation(
        spaceID: spaceID,
        actorID: ActorID(rawValue: "ios"),
        sequence: 1,
        action: .create,
        entity: .object,
        targetID: staleID,
        fields: ["name": .string("Stale")],
        createdAt: nil
    )
    let retainedCreate = EditOperation(
        spaceID: spaceID,
        actorID: ActorID(rawValue: "vision"),
        sequence: 2,
        action: .create,
        entity: .object,
        targetID: retainedID,
        fields: ["name": .string("Retained")],
        createdAt: nil
    )
    var projected: [EntityReference: [String: Value]] = [:]
    var events: [String] = []
    let bindings = ReplicaBindings(
        create: { context in
            projected[context.reference] = context.fields
            events.append("create:\(context.reference.id.rawValue)")
        },
        update: { context, fields, _ in
            projected[context.reference, default: [:]].merge(fields) { _, new in new }
        },
        delete: { context in
            projected.removeValue(forKey: context.reference)
            events.append("delete:\(context.reference.id.rawValue)")
        },
        setLink: { _, _, _ in }
    )
    let replica = Replica(spaceID: spaceID, bindings: bindings)
    _ = replica.apply([staleCreate])
    events.removeAll()
    let replacementState = Materializer().materialize(
        spaceID: spaceID,
        operations: [retainedCreate]
    )

    let report = replica.apply(StateSnapshot(state: replacementState))
    let staleReference = EntityReference(kind: .object, id: staleID)
    let retainedReference = EntityReference(kind: .object, id: retainedID)

    #expect(report.failures.isEmpty)
    #expect(events == ["delete:stale", "create:retained"])
    #expect(projected[staleReference] == nil)
    #expect(projected[retainedReference]?["name"] == .string("Retained"))
}

@Test func replicaRejectsSnapshotFromAnotherSpaceWithoutChangingStateOrProjection() {
    let create = operation(
        actor: "ios",
        sequence: 1,
        action: .create,
        fields: ["name": .string("Original")]
    )
    var projectedCreateCount = 0
    var projectedDeleteCount = 0
    var projectedFields: [String: Value] = [:]
    let replica = Replica(spaceID: spaceID, bindings: ReplicaBindings(
        create: { context in
            projectedCreateCount += 1
            projectedFields = context.fields
        },
        update: { _, _, _ in },
        delete: { _ in projectedDeleteCount += 1 },
        setLink: { _, _, _ in }
    ))
    _ = replica.apply([create])
    let foreignState = Materializer().materialize(
        spaceID: SpaceID(rawValue: "foreign"),
        operations: []
    )

    let report = replica.apply(StateSnapshot(state: foreignState))

    #expect(report.failures.isEmpty)
    #expect(projectedCreateCount == 1)
    #expect(projectedDeleteCount == 0)
    #expect(projectedFields["name"] == .string("Original"))

    _ = replica.replay()
    #expect(projectedCreateCount == 2)
    #expect(projectedFields["name"] == .string("Original"))
}

@Test func spaceMergeRegistryConvergesAcrossOrderAndRepeatedDelivery() throws {
    let a = SpaceID(rawValue: "a")
    let b = SpaceID(rawValue: "b")
    let c = SpaceID(rawValue: "c")
    let ab = SpaceMergeDeclaration(a, b)
    let bc = SpaceMergeDeclaration(b, c)

    var first = SpaceMergeRegistry()
    first.apply([ab, bc, ab])
    var second = SpaceMergeRegistry()
    second.apply([bc, ab])

    #expect(first == second)
    #expect(first.canonicalSpaceID(for: c) == a)
    #expect(first.equivalentSpaceIDs(to: b) == [a, b, c])
    #expect(first.areEquivalent(a, c))

    let data = try SpaceMergeCodec.encode(
        SpaceMergeEnvelope(declarations: Array(first.declarations))
    )
    let wire = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(wire["kind"] as? String == "editspace.space-merges")
    #expect(wire["v"] as? Int == 1)
    let wireDeclarations = try #require(wire["declarations"] as? [[String: String]])
    #expect(wireDeclarations.allSatisfy { $0["first"] != nil && $0["second"] != nil })
    let decoded = try SpaceMergeCodec.decode(data)
    var reconnected = SpaceMergeRegistry()
    reconnected.apply(decoded.declarations)
    #expect(reconnected == first)
}

@Test func resolvingOperationSpacePreservesIdentityAndStamp() {
    let original = operation(
        actor: "device-b",
        sequence: 42,
        action: .update,
        fields: ["x": .number(3)]
    )
    let canonical = SpaceID(rawValue: "canonical")
    let resolved = original.resolvingSpace(to: canonical)

    #expect(resolved.spaceID == canonical)
    #expect(resolved.operationID == original.operationID)
    #expect(resolved.stamp == original.stamp)
    #expect(resolved.dependencies == original.dependencies)
    #expect(resolved.fields == original.fields)
}
