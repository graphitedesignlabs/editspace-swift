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
