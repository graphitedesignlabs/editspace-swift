import Foundation

public enum SyncSource: Sendable {
    case local
    case peer
    case durableStore
}

public struct SyncResult: Equatable, Sendable {
    public private(set) var accepted: [OperationID] = []
    public private(set) var duplicates: [OperationID] = []
    public private(set) var rejected: [OperationID: [CompatibilityProblem]] = [:]

    mutating func record(_ operation: EditOperation, result: AppendResult) {
        switch result {
        case .accepted: accepted.append(operation.operationID)
        case .duplicate: duplicates.append(operation.operationID)
        case .rejected(let problems): rejected[operation.operationID] = problems
        }
    }
}

/// The transport-independent reference sync engine.
public struct SyncEngine: Sendable {
    public let documentID: DocumentID
    public private(set) var log: OperationLog
    public private(set) var pendingPeerOperationIDs: [OperationID] = []
    public private(set) var pendingStoreOperationIDs: [OperationID] = []

    public init(documentID: DocumentID, compatibilityPolicy: CompatibilityPolicy = CompatibilityPolicy()) {
        self.documentID = documentID
        self.log = OperationLog(documentID: documentID, compatibilityPolicy: compatibilityPolicy)
    }

    @discardableResult
    public mutating func append(_ operations: [EditOperation], source: SyncSource) -> SyncResult {
        var result = SyncResult()
        for operation in operations { result.record(operation, result: log.append(operation)) }
        switch source {
        case .local:
            Self.enqueue(result.accepted, in: &pendingPeerOperationIDs)
            Self.enqueue(result.accepted, in: &pendingStoreOperationIDs)
        case .peer:
            Self.enqueue(result.accepted, in: &pendingStoreOperationIDs)
        case .durableStore:
            Self.enqueue(result.accepted, in: &pendingPeerOperationIDs)
        }
        return result
    }

    public mutating func nextPeerEnvelope(maximumOperationCount: Int = 128) -> OperationEnvelope? {
        envelope(from: pendingPeerOperationIDs, maximumOperationCount: maximumOperationCount)
    }

    public mutating func nextStoreOperations(maximumOperationCount: Int = 128) -> [EditOperation] {
        operations(from: pendingStoreOperationIDs, maximumOperationCount: maximumOperationCount)
    }

    public mutating func acknowledgePeer(_ operationIDs: [OperationID]) {
        pendingPeerOperationIDs.removeAll { operationIDs.contains($0) }
    }

    public mutating func acknowledgeStore(_ operationIDs: [OperationID]) {
        pendingStoreOperationIDs.removeAll { operationIDs.contains($0) }
    }

    public var state: DocumentState { Materializer.materialize(log) }

    private static func enqueue(_ operationIDs: [OperationID], in queue: inout [OperationID]) {
        let existing = Set(queue)
        queue.append(contentsOf: operationIDs.filter { !existing.contains($0) })
    }

    private func envelope(from queue: [OperationID], maximumOperationCount: Int) -> OperationEnvelope? {
        let batch = Array(queue.prefix(max(1, maximumOperationCount))).compactMap { log.operationsByID[$0] }
        guard !batch.isEmpty else { return nil }
        return OperationEnvelope(documentID: documentID, operations: batch)
    }

    private func operations(from queue: [OperationID], maximumOperationCount: Int) -> [EditOperation] {
        Array(queue.prefix(max(1, maximumOperationCount))).compactMap { log.operationsByID[$0] }
    }
}

/// Adapters implement this interface for MultipeerConnectivity, WebSocket, WebRTC, or another link.
public protocol OperationTransport: Sendable {
    func send(_ data: Data) async throws
}

/// Adapters implement this interface for CloudKit, a server, SQLite, or another append-only store.
public protocol OperationStore: Sendable {
    func append(_ operations: [EditOperation]) async throws
    func fetch(documentID: DocumentID, after cursor: String?) async throws -> (operations: [EditOperation], cursor: String?)
}
