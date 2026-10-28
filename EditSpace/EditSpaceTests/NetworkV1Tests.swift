import Foundation
import Testing
@testable import EditSpace

private let networkSpaceID = SpaceID(rawValue: "network-space")
private let peerA = NetworkPeerID(rawValue: "00000000-0000-0000-0000-00000000000a")
private let peerB = NetworkPeerID(rawValue: "00000000-0000-0000-0000-00000000000b")
private let peerC = NetworkPeerID(rawValue: "00000000-0000-0000-0000-00000000000c")

private func networkOperation(
    actor: String = "artist-a",
    sequence: Int64 = 1,
    operationID: String? = nil,
    name: String = "Cube"
) -> EditOperation {
    EditOperation(
        spaceID: networkSpaceID,
        operationID: operationID.map(OperationID.init(rawValue:)),
        actorID: ActorID(rawValue: actor),
        sequence: sequence,
        action: .create,
        entity: .object,
        targetID: EntityID(rawValue: "cube-\(sequence)"),
        fields: ["name": .string(name)],
        createdAt: nil
    )
}

@Test func discoveryTXTMatchesNetworkV1ConformanceVector() throws {
    let peerID = NetworkPeerID(rawValue: "11111111-1111-4111-8111-111111111111")
    let record = try NetworkV1DiscoveryRecord(
        networkVersions: [1, 2],
        operationVersions: [1],
        peerID: peerID,
        capabilities: ["tcp", "history-ranges"]
    )

    #expect(record.txtValues == [
        "net": "2,1",
        "ops": "1",
        "peer": peerID.rawValue,
        "caps": "history-ranges,tcp"
    ])
    #expect(try NetworkV1DiscoveryRecord(txtData: record.encodedTXTData()) == record)
}

@Test func connectionSelectionUsesPeerThenSourcePort() {
    let wrongDirection = NetworkV1ConnectionCandidate(initiatorPeerID: peerB, initiatorPort: 49_152)
    let firstCorrect = NetworkV1ConnectionCandidate(initiatorPeerID: peerA, initiatorPort: 53_002)
    let preferred = NetworkV1ConnectionCandidate(initiatorPeerID: peerA, initiatorPort: 53_001)
    let candidates = [wrongDirection, firstCorrect, preferred]
    let result = candidates.dropFirst().reduce(candidates[0]) {
        NetworkV1ConnectionSelection.preferred(between: $0, and: $1)
    }
    #expect(result == preferred)
}

@Test func discoveryTXTPreservesOptionalProcessInstance() throws {
    let instanceID = "22222222-2222-4222-8222-222222222222"
    let record = try NetworkV1DiscoveryRecord(peerID: peerA, instanceID: instanceID)

    #expect(record.txtValues["instance"] == instanceID)
    #expect(try NetworkV1DiscoveryRecord(txtData: record.encodedTXTData()) == record)
}

@Test func discoveryTXTPreservesAppleDeviceSharingName() throws {
    let record = try NetworkV1DiscoveryRecord(
        peerID: peerA,
        sharingName: "Ian’s iPhone"
    )

    #expect(record.txtValues["name"] == "Ian’s iPhone")
    #expect(try NetworkV1DiscoveryRecord(txtData: record.encodedTXTData()).sharingName == "Ian’s iPhone")
}

@Test func sharingNamesAreBonjourSafe() {
    #expect(NetworkV1SharingName.sanitized("  Ian’s iPhone  ") == "Ian’s iPhone")
    #expect(NetworkV1SharingName.sanitized("   ") == "EditSpace")
    #expect(NetworkV1SharingName.sanitized(String(repeating: "📱", count: 40)).utf8.count <= 63)
}

@Test func restartedPeerCannotBeReplacedByItsStaleBonjourResult() {
    var tracker = NetworkV1PeerInstanceTracker()

    #expect(tracker.consider("old-process", for: peerA) == .selected)
    #expect(tracker.consider("new-process", for: peerA) == .replaced)
    #expect(tracker.consider("old-process", for: peerA) == .superseded)
    #expect(tracker.currentInstanceIDs[peerA] == "new-process")

    #expect(tracker.consider("newer-process", for: peerA) == .replaced)
    #expect(tracker.consider("new-process", for: peerA) == .superseded)
    #expect(tracker.currentInstanceIDs[peerA] == "newer-process")
}

@Test func networkV1MessageUsesSpecifiedWireNames() throws {
    let hello = NetworkV1Hello(peerID: peerA, instanceID: "process-a", spaces: [networkSpaceID])
    let data = try NetworkV1MessageCodec.encode(.hello(hello))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["kind"] as? String == "editspace.network.hello")
    #expect(object["v"] as? Int == 1)
    #expect(object["peerID"] as? String == peerA.rawValue)
    #expect(object["instanceID"] as? String == "process-a")
    #expect(object["spaces"] as? [String] == [networkSpaceID.rawValue])
    #expect(try NetworkV1MessageCodec.decode(data) == .hello(hello))
}

@Test func sessionHelloIncludesCurrentProcessInstance() async {
    let repository = NetworkV1Repository(spaces: [])
    let session = NetworkV1Session(
        localPeerID: peerA,
        localInstanceID: "current-process",
        repository: repository,
        selectedSpaces: []
    )

    let messages = await session.initialMessages()
    guard case .hello(let hello) = messages.first else {
        Issue.record("Expected the initial message to be a hello")
        return
    }
    #expect(hello.instanceID == "current-process")
}

@Test func applicationMessageRoundTripsOpaquePayload() throws {
    let application = NetworkV1ApplicationMessage(
        messageID: "calibration-1",
        channel: "org.example.calibration",
        payload: Data([0, 1, 2, 255])
    )
    let data = try NetworkV1MessageCodec.encode(.application(application))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["kind"] as? String == NetworkV1ApplicationMessage.kind)
    #expect(object["channel"] as? String == application.channel)
    #expect(try NetworkV1MessageCodec.decode(data) == .application(application))
}

@Test func frameCodecHandlesFragmentedAndCoalescedTCPReads() throws {
    let first = try NetworkV1FrameCodec.encode(message: .hello(NetworkV1Hello(peerID: peerA, spaces: [])))
    let second = try NetworkV1FrameCodec.encode(message: .spaceSelection(NetworkV1SpaceSelection(spaces: [])))
    let bytes = first + second
    var decoder = NetworkV1FrameCodec()

    #expect(try decoder.append(bytes.prefix(2)).isEmpty)
    #expect(try decoder.append(bytes.dropFirst(2).prefix(9)).isEmpty)
    let frames = try decoder.append(bytes.dropFirst(11))

    #expect(frames.count == 2)
    #expect(try NetworkV1MessageCodec.decode(frames[0]) == .hello(NetworkV1Hello(peerID: peerA, spaces: [])))
    #expect(try NetworkV1MessageCodec.decode(frames[1]) == .spaceSelection(NetworkV1SpaceSelection(spaces: [])))
    #expect(!decoder.hasPartialFrame)
}

@Test func frameCodecRejectsInvalidLengthsAndRoots() throws {
    var decoder = NetworkV1FrameCodec()
    #expect(throws: NetworkV1FrameError.zeroLength) {
        try decoder.append(Data([0, 0, 0, 0]))
    }

    decoder = NetworkV1FrameCodec()
    let arrayPayload = Data("[]".utf8)
    let frame = try NetworkV1FrameCodec.encode(payload: arrayPayload)
    #expect(throws: NetworkV1FrameError.nonObjectRoot) {
        try decoder.append(frame)
    }

    decoder = NetworkV1FrameCodec()
    let duplicateKeyFrame = try NetworkV1FrameCodec.encode(payload: Data(#"{"kind":"a","kind":"b"}"#.utf8))
    #expect(throws: NetworkV1FrameError.duplicateJSONKey("kind")) {
        try decoder.append(duplicateKeyFrame)
    }
}

@Test func repositoryBuildsRangesAndPreventsImplicitRelay() async throws {
    let repository = NetworkV1Repository(spaces: [networkSpaceID])
    let first = networkOperation(sequence: 1)
    let third = networkOperation(sequence: 3)
    #expect(await repository.append(first, from: peerB) == .appended)
    #expect(await repository.append(third, from: peerB) == .appended)

    let summaryForSource = await repository.makeSummary(for: networkSpaceID, neighbor: peerB)
    #expect(summaryForSource.actors == [
        NetworkV1ActorRanges(actor: first.actorID, ranges: [
            NetworkV1SequenceRange(first: 1, last: 1),
            NetworkV1SequenceRange(first: 3, last: 3)
        ])
    ])

    let summaryForOtherPeer = await repository.makeSummary(for: networkSpaceID, neighbor: peerC)
    #expect(summaryForOtherPeer.actors.isEmpty)

    await repository.approveForSharing(first.operationID)
    let approvedSummary = await repository.makeSummary(for: networkSpaceID, neighbor: peerC)
    #expect(approvedSummary.actors.first?.ranges == [NetworkV1SequenceRange(first: 1, last: 1)])
}

@Test func repositoryComputesMissingRangeGapsWithoutExpandingRanges() async {
    let repository = NetworkV1Repository(spaces: [networkSpaceID])
    for sequence in [1, 2, 3, 8, 9] as [Int64] {
        _ = await repository.appendLocal(networkOperation(sequence: sequence))
    }
    for sequence in [2] as [Int64] {
        _ = await repository.appendLocal(networkOperation(actor: "artist-b", sequence: sequence))
    }
    let summary = NetworkV1HistorySummary(
        summaryID: "remote-summary",
        spaceID: networkSpaceID,
        actors: [
            NetworkV1ActorRanges(actor: ActorID(rawValue: "artist-a"), ranges: [NetworkV1SequenceRange(first: 1, last: 10)]),
            NetworkV1ActorRanges(actor: ActorID(rawValue: "artist-b"), ranges: [NetworkV1SequenceRange(first: 1, last: 4)])
        ],
        spaceMerges: SpaceMergeEnvelope(declarations: [])
    )

    #expect(await repository.missingRanges(from: summary) == [
        NetworkV1ActorRanges(actor: ActorID(rawValue: "artist-a"), ranges: [
            NetworkV1SequenceRange(first: 4, last: 7),
            NetworkV1SequenceRange(first: 10, last: 10)
        ]),
        NetworkV1ActorRanges(actor: ActorID(rawValue: "artist-b"), ranges: [
            NetworkV1SequenceRange(first: 1, last: 1),
            NetworkV1SequenceRange(first: 3, last: 4)
        ])
    ])
}

@Test func repositoryReportsIdentityAndActorSequenceCollisions() async {
    let repository = NetworkV1Repository(spaces: [networkSpaceID])
    let original = networkOperation(sequence: 1, operationID: "one", name: "Cube")
    let operationIDCollision = networkOperation(sequence: 2, operationID: "one", name: "Sphere")
    let actorSequenceCollision = networkOperation(sequence: 1, operationID: "two", name: "Cone")

    #expect(await repository.appendLocal(original) == .appended)
    #expect(await repository.appendLocal(original) == .duplicate)
    #expect(await repository.appendLocal(operationIDCollision) == .rejected(.operationIDCollision))
    #expect(await repository.appendLocal(actorSequenceCollision) == .rejected(.actorSequenceCollision))
}

@Test func repositorySeedsExistingLocalHistoryIdempotently() async {
    let repository = NetworkV1Repository(spaces: [networkSpaceID])
    let operations = [
        networkOperation(sequence: 1),
        networkOperation(sequence: 2)
    ]

    #expect(await repository.seedLocalHistory(operations) == [.appended, .appended])
    #expect(await repository.seedLocalHistory(operations) == [.duplicate, .duplicate])
    #expect(await repository.operations(in: networkSpaceID) == operations)
}

@Test func twoSessionsNegotiateAndReconcileMissingHistory() async throws {
    let repositoryA = NetworkV1Repository(spaces: [networkSpaceID])
    let repositoryB = NetworkV1Repository(spaces: [networkSpaceID])
    let operation = networkOperation()
    #expect(await repositoryB.appendLocal(operation) == .appended)

    let sessionA = NetworkV1Session(
        localPeerID: peerA,
        expectedRemotePeerID: peerB,
        repository: repositoryA,
        selectedSpaces: [networkSpaceID]
    )
    let sessionB = NetworkV1Session(
        localPeerID: peerB,
        expectedRemotePeerID: peerA,
        repository: repositoryB,
        selectedSpaces: [networkSpaceID]
    )

    var toA = await sessionB.initialMessages()
    var toB = await sessionA.initialMessages()
    var iterations = 0
    while (!toA.isEmpty || !toB.isEmpty) && iterations < 30 {
        let inboundA = toA
        let inboundB = toB
        toA = []
        toB = []
        for message in inboundA { toB.append(contentsOf: try await sessionA.receive(message)) }
        for message in inboundB { toA.append(contentsOf: try await sessionB.receive(message)) }
        iterations += 1
    }

    #expect(await repositoryA.operations(in: networkSpaceID) == [operation])
    #expect(await sessionA.state == .live)
    #expect(await sessionB.state == .live)
    let application = NetworkV1ApplicationMessage(
        messageID: "live-message",
        channel: "org.example.selection",
        payload: Data("cube-1".utf8)
    )
    #expect(await sessionA.applicationMessage(application) == .application(application))
}

@Test func liveSessionsReconcileHistoryAddedAfterHandshake() async throws {
    let repositoryA = NetworkV1Repository(spaces: [networkSpaceID])
    let repositoryB = NetworkV1Repository(spaces: [networkSpaceID])
    let sessionA = NetworkV1Session(
        localPeerID: peerA,
        expectedRemotePeerID: peerB,
        repository: repositoryA,
        selectedSpaces: [networkSpaceID]
    )
    let sessionB = NetworkV1Session(
        localPeerID: peerB,
        expectedRemotePeerID: peerA,
        repository: repositoryB,
        selectedSpaces: [networkSpaceID]
    )

    var toA = await sessionB.initialMessages()
    var toB = await sessionA.initialMessages()
    var iterations = 0
    while (!toA.isEmpty || !toB.isEmpty) && iterations < 30 {
        let inboundA = toA
        let inboundB = toB
        toA = []
        toB = []
        for message in inboundA { toB.append(contentsOf: try await sessionA.receive(message)) }
        for message in inboundB { toA.append(contentsOf: try await sessionB.receive(message)) }
        iterations += 1
    }
    #expect(await sessionA.state == .live)
    #expect(await sessionB.state == .live)

    let restoredOperation = networkOperation()
    #expect(await repositoryB.seedLocalHistory([restoredOperation]) == [.appended])
    toA = await sessionB.reconciliationMessages()
    iterations = 0
    while (!toA.isEmpty || !toB.isEmpty) && iterations < 30 {
        let inboundA = toA
        let inboundB = toB
        toA = []
        toB = []
        for message in inboundA { toB.append(contentsOf: try await sessionA.receive(message)) }
        for message in inboundB { toA.append(contentsOf: try await sessionB.receive(message)) }
        iterations += 1
    }

    #expect(await repositoryA.operations(in: networkSpaceID) == [restoredOperation])
    #expect(await sessionA.state == .live)
    #expect(await sessionB.state == .live)
}
