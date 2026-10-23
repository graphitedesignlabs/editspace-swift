import Foundation

public enum NetworkV1SessionState: Equatable, Sendable {
    case hello
    case selection
    case synchronizing
    case live
    case closed
}

public enum NetworkV1SessionError: Error, Equatable, Sendable {
    case protocolError(NetworkV1ErrorMessage)
}

/// Transport-independent v1 negotiation and history reconciliation for one peer link.
public actor NetworkV1Session {
    private struct OutstandingRequest: Sendable {
        let request: NetworkV1OperationRequest
        var received: Set<String> = []
    }

    public let localPeerID: NetworkPeerID
    public private(set) var remotePeerID: NetworkPeerID?
    public private(set) var state: NetworkV1SessionState = .hello

    private let repository: NetworkV1Repository
    private let selectedSpaces: Set<SpaceID>
    private let expectedRemotePeerID: NetworkPeerID?
    private var remoteHello: NetworkV1Hello?
    private var sentSelection: NetworkV1SpaceSelection?
    private var remoteSelection: NetworkV1SpaceSelection?
    private var activeSpaces: Set<SpaceID> = []
    private var latestRemoteSummaries: [SpaceID: NetworkV1HistorySummary] = [:]
    private var incompleteRequests: [String: OutstandingRequest] = [:]
    private var locallyComplete: Set<SpaceID> = []
    private var remotelyComplete: Set<SpaceID> = []

    public init(
        localPeerID: NetworkPeerID,
        expectedRemotePeerID: NetworkPeerID? = nil,
        repository: NetworkV1Repository,
        selectedSpaces: Set<SpaceID>
    ) {
        self.localPeerID = localPeerID
        self.expectedRemotePeerID = expectedRemotePeerID
        self.repository = repository
        self.selectedSpaces = selectedSpaces
    }

    public func initialMessages() async -> [NetworkV1Message] {
        [.hello(NetworkV1Hello(peerID: localPeerID, spaces: await repository.spaces()))]
    }

    public func receive(_ message: NetworkV1Message) async throws -> [NetworkV1Message] {
        if case .error(let error) = message {
            if error.fatal { state = .closed }
            throw NetworkV1SessionError.protocolError(error)
        }
        switch state {
        case .hello:
            guard case .hello(let hello) = message else { return try fail(.unexpectedMessage, "Expected networkHello") }
            return try await receiveHello(hello)
        case .selection:
            guard case .spaceSelection(let selection) = message else {
                return try fail(.unexpectedMessage, "Expected spaceSelection")
            }
            return try await receiveSelection(selection)
        case .synchronizing, .live:
            return try await receiveSynchronization(message)
        case .closed:
            return []
        }
    }

    public func liveBatch(for operation: EditOperation) async -> NetworkV1Message? {
        let canonicalSpaceID = await repository.canonicalSpaceID(for: operation.spaceID)
        guard state == .live, activeSpaces.contains(canonicalSpaceID) else { return nil }
        return .operationBatch(NetworkV1OperationBatch(
            requestID: nil,
            final: true,
            spaceID: canonicalSpaceID,
            envelopes: [OperationEnvelope(spaceID: operation.spaceID, operations: [operation])]
        ))
    }

    private func receiveHello(_ hello: NetworkV1Hello) async throws -> [NetworkV1Message] {
        guard hello.peerID != localPeerID,
              expectedRemotePeerID.map({ $0 == hello.peerID }) ?? true else {
            return try fail(.peerIDMismatch, "The remote Peer ID does not match discovery")
        }
        guard hello.networkVersions.contains(1) else {
            return try fail(.unsupportedNetworkVersion, "Network v1 is not supported by the remote endpoint")
        }
        guard hello.operationVersions.contains(1) else {
            return try fail(.unsupportedOperationVersion, "Operation v1 is not supported by the remote endpoint")
        }
        remotePeerID = hello.peerID
        remoteHello = hello
        let selection = NetworkV1SpaceSelection(spaces: hello.spaces.filter(selectedSpaces.contains).sorted())
        sentSelection = selection
        state = .selection
        return [.spaceSelection(selection)]
    }

    private func receiveSelection(_ selection: NetworkV1SpaceSelection) async throws -> [NetworkV1Message] {
        guard let remoteHello, let sentSelection, let remotePeerID else {
            return try fail(.unexpectedMessage, "Selection arrived before hello")
        }
        let localOffers = Set(await repository.spaces())
        guard Set(selection.spaces).isSubset(of: localOffers) else {
            return try fail(.invalidSelection, "The remote endpoint selected an unoffered space")
        }
        remoteSelection = selection
        activeSpaces = Set(selection.spaces).union(sentSelection.spaces)
        state = .synchronizing
        if activeSpaces.isEmpty {
            state = .live
            return []
        }
        var messages: [NetworkV1Message] = []
        for spaceID in activeSpaces.sorted() {
            let summary = await repository.makeSummary(for: spaceID, neighbor: remotePeerID)
            messages.append(.historySummary(summary))
        }
        return messages
    }

    private func receiveSynchronization(_ message: NetworkV1Message) async throws -> [NetworkV1Message] {
        guard let remotePeerID else { return try fail(.unexpectedMessage, "Missing remote identity") }
        switch message {
        case .historySummary(let summary):
            for declaration in summary.spaceMerges.declarations {
                await repository.addMerge(declaration, from: remotePeerID)
            }
            var canonicalActiveSpaces: Set<SpaceID> = []
            for spaceID in activeSpaces {
                canonicalActiveSpaces.insert(await repository.canonicalSpaceID(for: spaceID))
            }
            activeSpaces = canonicalActiveSpaces
            var canonicalLocalCompletion: Set<SpaceID> = []
            for spaceID in locallyComplete {
                canonicalLocalCompletion.insert(await repository.canonicalSpaceID(for: spaceID))
            }
            locallyComplete = canonicalLocalCompletion
            var canonicalRemoteCompletion: Set<SpaceID> = []
            for spaceID in remotelyComplete {
                canonicalRemoteCompletion.insert(await repository.canonicalSpaceID(for: spaceID))
            }
            remotelyComplete = canonicalRemoteCompletion
            guard activeSpaces.contains(await repository.canonicalSpaceID(for: summary.spaceID)) else {
                return try fail(.invalidMessage, "Summary is outside the active spaces")
            }
            latestRemoteSummaries[summary.spaceID] = summary
            let missing = await repository.missingRanges(from: summary)
            if missing.isEmpty {
                locallyComplete.insert(summary.spaceID)
                updateLiveState()
                return [.syncComplete(NetworkV1SyncComplete(summaryID: summary.summaryID, spaceID: summary.spaceID))]
            }
            guard incompleteRequests.count < 16 else { return try fail(.resourceLimit, "Too many outstanding requests") }
            let requestID = UUID().uuidString.lowercased()
            let request = NetworkV1OperationRequest(
                requestID: requestID,
                summaryID: summary.summaryID,
                spaceID: summary.spaceID,
                actors: missing
            )
            incompleteRequests[requestID] = OutstandingRequest(request: request)
            locallyComplete.remove(summary.spaceID)
            state = .synchronizing
            return [.operationRequest(request)]
        case .operationRequest(let request):
            guard activeSpaces.contains(request.spaceID) else { return try fail(.invalidMessage, "Request is outside the active spaces") }
            do {
                let operations = try await repository.operations(for: request, from: remotePeerID)
                let batches = try makeBatches(operations: operations, request: request)
                let summary = await repository.makeSummary(for: request.spaceID, neighbor: remotePeerID)
                return batches.map(NetworkV1Message.operationBatch) + [.historySummary(summary)]
            } catch {
                return [.error(NetworkV1ErrorMessage(
                    code: .historyUnavailable,
                    message: "The advertised history is no longer available",
                    spaceID: request.spaceID,
                    requestID: request.requestID
                ))]
            }
        case .operationBatch(let batch):
            guard activeSpaces.contains(batch.spaceID) else { return try fail(.invalidMessage, "Batch is outside the active spaces") }
            if batch.requestID == nil, !batch.final {
                return try fail(.invalidMessage, "A live batch must be final")
            }
            if let requestID = batch.requestID,
               incompleteRequests[requestID]?.request.spaceID != batch.spaceID {
                return try fail(.invalidMessage, "Unknown operation request")
            }
            for envelope in batch.envelopes {
                guard await repository.spacesAreEquivalent(envelope.spaceID, batch.spaceID) else {
                    return try fail(.invalidMessage, "An operation envelope does not match the batch space")
                }
                for operation in envelope.operations {
                    guard await repository.spacesAreEquivalent(operation.spaceID, batch.spaceID) else {
                        return try fail(.invalidMessage, "An operation does not match the batch space")
                    }
                }
            }
            var responses: [NetworkV1Message] = []
            for envelope in batch.envelopes {
                for operation in envelope.operations {
                    if let requestID = batch.requestID {
                        guard var outstanding = incompleteRequests[requestID],
                              outstanding.request.actors.first(where: { $0.actor == operation.actorID })?
                                .ranges.contains(where: { $0.contains(operation.sequence) }) == true else {
                            return try fail(.invalidMessage, "A requested batch contains an unrequested operation")
                        }
                        outstanding.received.insert("\(operation.actorID.rawValue):\(operation.sequence)")
                        incompleteRequests[requestID] = outstanding
                    }
                    let result = await repository.append(operation, from: remotePeerID)
                    if case .rejected(let code) = result {
                        responses.append(.error(NetworkV1ErrorMessage(code: code, spaceID: batch.spaceID, requestID: batch.requestID)))
                    }
                }
            }
            if batch.final, let requestID = batch.requestID {
                guard let outstanding = incompleteRequests.removeValue(forKey: requestID) else {
                    return try fail(.invalidMessage, "Unknown operation request")
                }
                if !isComplete(outstanding) {
                    responses.append(.error(NetworkV1ErrorMessage(
                        code: .historyUnavailable,
                        message: "The final batch did not contain all requested operations",
                        spaceID: batch.spaceID,
                        requestID: requestID
                    )))
                }
            }
            return responses
        case .syncComplete(let complete):
            guard activeSpaces.contains(complete.spaceID) else { return try fail(.invalidMessage, "Completion is outside the active spaces") }
            remotelyComplete.insert(complete.spaceID)
            updateLiveState()
            return []
        default:
            return try fail(.unexpectedMessage, "Message is not valid while synchronizing")
        }
    }

    private func updateLiveState() {
        if locallyComplete == activeSpaces && remotelyComplete == activeSpaces {
            state = .live
        }
    }

    private func isComplete(_ outstanding: OutstandingRequest) -> Bool {
        var expectedCount = 0
        for actor in outstanding.request.actors {
            for range in actor.ranges {
                let width = range.last - range.first + 1
                guard width <= Int64(outstanding.received.count - expectedCount) else { return false }
                expectedCount += Int(width)
            }
        }
        return expectedCount == outstanding.received.count
    }

    private func makeBatches(
        operations: [EditOperation],
        request: NetworkV1OperationRequest
    ) throws -> [NetworkV1OperationBatch] {
        guard !operations.isEmpty else {
            return [NetworkV1OperationBatch(requestID: request.requestID, final: true, spaceID: request.spaceID, envelopes: [])]
        }
        var groups: [[EditOperation]] = []
        var current: [EditOperation] = []
        for operation in operations {
            let candidate = current + [operation]
            let batch = NetworkV1OperationBatch(
                requestID: request.requestID,
                final: false,
                spaceID: request.spaceID,
                envelopes: [OperationEnvelope(spaceID: request.spaceID, operations: candidate)]
            )
            if try NetworkV1MessageCodec.encode(.operationBatch(batch)).count <= NetworkV1FrameCodec.maximumPayloadSize {
                current = candidate
            } else {
                guard !current.isEmpty else { throw NetworkV1RepositoryError.unavailableHistory }
                groups.append(current)
                current = [operation]
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups.enumerated().map { index, operations in
            NetworkV1OperationBatch(
                requestID: request.requestID,
                final: index == groups.count - 1,
                spaceID: request.spaceID,
                envelopes: [OperationEnvelope(spaceID: request.spaceID, operations: operations)]
            )
        }
    }

    private func fail(_ code: NetworkV1ErrorCode, _ message: String) throws -> [NetworkV1Message] {
        let error = NetworkV1ErrorMessage(code: code, message: message)
        if error.fatal { state = .closed }
        return [.error(error)]
    }
}
