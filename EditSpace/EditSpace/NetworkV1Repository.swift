import Foundation

public enum NetworkV1Provenance: Equatable, Sendable {
    case local
    case approvedImport
    case peer(NetworkPeerID)
}

public enum NetworkV1ImportResult: Equatable, Sendable {
    case appended
    case duplicate
    case rejected(NetworkV1ErrorCode)
}

public enum NetworkV1RepositoryError: Error, Equatable, Sendable {
    case unknownSummary
    case unavailableHistory
    case inactiveSpace
}

/// Durable v1 history with the neighbor provenance needed to prevent implicit forwarding.
public actor NetworkV1Repository {
    private struct StoredOperation: Sendable {
        let operation: EditOperation
        var provenance: NetworkV1Provenance
    }

    private struct Snapshot: Sendable {
        let spaceID: SpaceID
        let operations: [EditOperation]
    }

    private var offeredSpaces: Set<SpaceID>
    private var operationsByID: [OperationID: StoredOperation] = [:]
    private var actorSequences: [ActorID: [Int64: OperationID]] = [:]
    private var mergeRegistry = SpaceMergeRegistry()
    private var mergeProvenance: [SpaceMergeDeclaration: NetworkV1Provenance] = [:]
    private var snapshots: [NetworkPeerID: [String: Snapshot]] = [:]

    public init(spaces: Set<SpaceID> = []) {
        offeredSpaces = spaces
    }

    public func offer(_ spaceID: SpaceID) {
        offeredSpaces.insert(spaceID)
    }

    public func withdraw(_ spaceID: SpaceID) {
        offeredSpaces.remove(spaceID)
    }

    public func spaces() -> [SpaceID] {
        offeredSpaces.sorted()
    }

    @discardableResult
    public func appendLocal(_ operation: EditOperation) -> NetworkV1ImportResult {
        insert(operation, provenance: .local)
    }

    @discardableResult
    public func appendApprovedImport(_ operation: EditOperation) -> NetworkV1ImportResult {
        insert(operation, provenance: .approvedImport)
    }

    @discardableResult
    public func append(_ operation: EditOperation, from peerID: NetworkPeerID) -> NetworkV1ImportResult {
        insert(operation, provenance: .peer(peerID))
    }

    public func approveForSharing(_ operationID: OperationID) {
        guard var stored = operationsByID[operationID] else { return }
        stored.provenance = .approvedImport
        operationsByID[operationID] = stored
    }

    public func operations(in spaceID: SpaceID) -> [EditOperation] {
        let component = mergeRegistry.equivalentSpaceIDs(to: spaceID)
        return operationsByID.values.map(\.operation)
            .filter { component.contains($0.spaceID) }
            .sorted(by: operationOrder)
    }

    public func canonicalSpaceID(for spaceID: SpaceID) -> SpaceID {
        mergeRegistry.canonicalSpaceID(for: spaceID)
    }

    public func spacesAreEquivalent(_ lhs: SpaceID, _ rhs: SpaceID) -> Bool {
        mergeRegistry.areEquivalent(lhs, rhs)
    }

    public func addLocalMerge(_ declaration: SpaceMergeDeclaration) {
        mergeRegistry.apply(declaration)
        mergeProvenance[declaration] = .local
    }

    public func addMerge(_ declaration: SpaceMergeDeclaration, from peerID: NetworkPeerID) {
        mergeRegistry.apply(declaration)
        if mergeProvenance[declaration] == nil {
            mergeProvenance[declaration] = .peer(peerID)
        }
    }

    public func makeSummary(for spaceID: SpaceID, neighbor: NetworkPeerID) -> NetworkV1HistorySummary {
        let canonical = mergeRegistry.canonicalSpaceID(for: spaceID)
        let component = mergeRegistry.equivalentSpaceIDs(to: canonical)
        let eligible = operationsByID.values.filter {
            component.contains($0.operation.spaceID) && isEligible($0.provenance, for: neighbor)
        }.map(\.operation).sorted(by: operationOrder)
        let summaryID = UUID().uuidString.lowercased()
        snapshots[neighbor, default: [:]][summaryID] = Snapshot(spaceID: canonical, operations: eligible)
        let declarations = mergeRegistry.declarations.filter {
            component.contains($0.firstSpaceID) && isEligible(mergeProvenance[$0] ?? .local, for: neighbor)
        }.sorted(by: mergeOrder)
        return NetworkV1HistorySummary(
            summaryID: summaryID,
            spaceID: canonical,
            actors: Self.actorRanges(for: eligible),
            spaceMerges: SpaceMergeEnvelope(declarations: declarations)
        )
    }

    public func missingRanges(from summary: NetworkV1HistorySummary) -> [NetworkV1ActorRanges] {
        let local = operations(in: summary.spaceID)
        let sequences = Dictionary(grouping: local, by: \.actorID)
            .mapValues { Set($0.map(\.sequence)) }
        return summary.actors.compactMap { actorSummary in
            let have = sequences[actorSummary.actor] ?? []
            let ranges = actorSummary.ranges.flatMap { range -> [NetworkV1SequenceRange] in
                let present = have.filter { range.contains($0) }.sorted()
                var cursor = range.first
                var missing: [NetworkV1SequenceRange] = []
                for sequence in present {
                    if cursor < sequence {
                        missing.append(NetworkV1SequenceRange(first: cursor, last: sequence - 1))
                    }
                    cursor = sequence + 1
                }
                if cursor <= range.last {
                    missing.append(NetworkV1SequenceRange(first: cursor, last: range.last))
                }
                return missing
            }
            return ranges.isEmpty ? nil : NetworkV1ActorRanges(actor: actorSummary.actor, ranges: ranges)
        }
    }

    public func operations(for request: NetworkV1OperationRequest, from neighbor: NetworkPeerID) throws -> [EditOperation] {
        guard let snapshot = snapshots[neighbor]?[request.summaryID], snapshot.spaceID == request.spaceID else {
            throw NetworkV1RepositoryError.unknownSummary
        }
        let requested = Dictionary(uniqueKeysWithValues: request.actors.map { ($0.actor, $0.ranges) })
        let results = snapshot.operations.filter { operation in
            requested[operation.actorID]?.contains(where: { $0.contains(operation.sequence) }) == true
        }
        let resultKeys = Set(results.map { "\($0.actorID.rawValue):\($0.sequence)" })
        var requestedCount = 0
        for actor in request.actors {
            for range in actor.ranges {
                let width = range.last - range.first + 1
                guard width <= Int64(snapshot.operations.count - requestedCount) else {
                    throw NetworkV1RepositoryError.unavailableHistory
                }
                requestedCount += Int(width)
            }
        }
        guard resultKeys.count == requestedCount else { throw NetworkV1RepositoryError.unavailableHistory }
        return results
    }

    private func insert(_ operation: EditOperation, provenance: NetworkV1Provenance) -> NetworkV1ImportResult {
        if let existing = operationsByID[operation.operationID] {
            return existing.operation == operation ? .duplicate : .rejected(.operationIDCollision)
        }
        if let existingID = actorSequences[operation.actorID]?[operation.sequence],
           existingID != operation.operationID {
            return .rejected(.actorSequenceCollision)
        }
        let probe = NetworkV1OperationBatch(
            requestID: nil,
            final: true,
            spaceID: operation.spaceID,
            envelopes: [OperationEnvelope(spaceID: operation.spaceID, operations: [operation])]
        )
        guard let size = try? NetworkV1MessageCodec.encode(.operationBatch(probe)).count,
              size <= NetworkV1FrameCodec.maximumPayloadSize else {
            return .rejected(.resourceLimit)
        }
        var log = OperationLog(spaceID: operation.spaceID)
        switch log.append(operation) {
        case .rejected:
            return .rejected(.invalidOperation)
        default:
            operationsByID[operation.operationID] = StoredOperation(operation: operation, provenance: provenance)
            actorSequences[operation.actorID, default: [:]][operation.sequence] = operation.operationID
            offeredSpaces.insert(operation.spaceID)
            return .appended
        }
    }

    private func isEligible(_ provenance: NetworkV1Provenance, for neighbor: NetworkPeerID) -> Bool {
        switch provenance {
        case .local, .approvedImport: return true
        case .peer(let source): return source == neighbor
        }
    }

    private func operationOrder(_ lhs: EditOperation, _ rhs: EditOperation) -> Bool {
        lhs.stamp < rhs.stamp
    }

    private func mergeOrder(_ lhs: SpaceMergeDeclaration, _ rhs: SpaceMergeDeclaration) -> Bool {
        if lhs.firstSpaceID != rhs.firstSpaceID { return lhs.firstSpaceID < rhs.firstSpaceID }
        return lhs.secondSpaceID < rhs.secondSpaceID
    }

    private static func actorRanges(for operations: [EditOperation]) -> [NetworkV1ActorRanges] {
        Dictionary(grouping: operations, by: \.actorID).keys.sorted().map { actor in
            let sequences = operations.filter { $0.actorID == actor }.map(\.sequence)
            return NetworkV1ActorRanges(actor: actor, ranges: ranges(for: sequences))
        }
    }

    private static func ranges(for sequences: [Int64]) -> [NetworkV1SequenceRange] {
        let sorted = Array(Set(sequences)).sorted()
        guard var first = sorted.first else { return [] }
        var last = first
        var result: [NetworkV1SequenceRange] = []
        for sequence in sorted.dropFirst() {
            if sequence == last + 1 {
                last = sequence
            } else {
                result.append(NetworkV1SequenceRange(first: first, last: last))
                first = sequence
                last = sequence
            }
        }
        result.append(NetworkV1SequenceRange(first: first, last: last))
        return result
    }
}
