import Foundation
import Testing
@testable import EditSpace

private let documentID = DocumentID(rawValue: "scene")
private let objectID = EntityID(rawValue: "cube")

private func operation(
    actor: String,
    sequence: Int64,
    action: OperationAction,
    fields: [String: Value] = [:],
    dependencies: [OperationID] = []
) -> EditOperation {
    EditOperation(
        documentID: documentID,
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
    let envelope = OperationEnvelope(documentID: documentID, operations: [create])
    let data = try OperationCodec.encode(envelope)
    #expect(try OperationCodec.decode(data) == envelope)
    #expect(String(decoding: data, as: UTF8.self).contains("\"kind\":\"editspace.operations\""))
}

@Test func concurrentUpdatesConvergeRegardlessOfArrivalOrder() {
    let create = operation(actor: "a", sequence: 1, action: .create, fields: ["x": .number(0)])
    let updateA = operation(actor: "a", sequence: 2, action: .update, fields: ["x": .number(1)])
    let updateB = operation(actor: "b", sequence: 2, action: .update, fields: ["x": .number(2)])
    var first = OperationLog(documentID: documentID)
    var second = OperationLog(documentID: documentID)
    [create, updateA, updateB].forEach { _ = first.append($0) }
    [updateB, create, updateA].forEach { _ = second.append($0) }
    #expect(Materializer.materialize(first) == Materializer.materialize(second))
    let reference = EntityReference(kind: .object, id: objectID)
    #expect(Materializer.materialize(first).entities[reference]?.fields["x"] == .number(2))
}

@Test func duplicatesAreIdempotentAndCollisionsAreRejected() {
    let create = operation(actor: "a", sequence: 1, action: .create)
    var log = OperationLog(documentID: documentID)
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
    let envelope = PresenceEnvelope(documentID: documentID, presence: presence)
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
    var engine = SyncEngine(documentID: documentID)
    let result = engine.append([create], source: .local)
    #expect(result.accepted == [create.operationID])
    #expect(engine.pendingPeerOperationIDs == [create.operationID])
    #expect(engine.pendingStoreOperationIDs == [create.operationID])
}
