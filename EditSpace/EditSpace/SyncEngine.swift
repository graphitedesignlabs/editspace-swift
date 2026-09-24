import Foundation

public struct OperationStoreDecodeFailure: Equatable, Sendable {
    public let recordName: String
    public let operationID: OperationID
    public let message: String

    public init(recordName: String,
                operationID: OperationID,
                message: String) {
        self.recordName = recordName
        self.operationID = operationID
        self.message = message
    }
}

public struct OperationStoreRefreshResult: Equatable, Sendable {
    public let page: OperationStorePage
    public let importResult: OperationSyncResult
    public let decodeFailures: [OperationStoreDecodeFailure]

    public init(page: OperationStorePage,
                importResult: OperationSyncResult,
                decodeFailures: [OperationStoreDecodeFailure] = []) {
        self.page = page
        self.importResult = importResult
        self.decodeFailures = decodeFailures
    }
}

public struct SyncEngine: Sendable {
    public let spaceID: SpaceID
    public let configuration: OperationSyncConfiguration
    public private(set) var operationLog: OperationLog
    public private(set) var storeCursor: OperationStoreCursor?

    private var pendingPeerQueue: OperationIDQueue
    private var pendingCloudQueue: OperationIDQueue

    public init(spaceID: SpaceID,
                operations: [EditOperation] = [],
                compatibilityPolicy: CompatibilityPolicy = CompatibilityPolicy(),
                configuration: OperationSyncConfiguration = OperationSyncConfiguration(),
                storeCursor: OperationStoreCursor? = nil) {
        self.spaceID = spaceID
        self.configuration = configuration
        self.operationLog = OperationLog(spaceID: spaceID,
                                                 operations: operations,
                                                 compatibilityPolicy: compatibilityPolicy)
        self.storeCursor = storeCursor
        self.pendingPeerQueue = OperationIDQueue()
        self.pendingCloudQueue = OperationIDQueue()
    }

    public var pendingPeerOperationIDs: [OperationID] {
        pendingPeerQueue.operationIDs
    }

    public var pendingCloudOperationIDs: [OperationID] {
        pendingCloudQueue.operationIDs
    }

    /// The renderer-neutral v0.1 spelling for the durable-store queue.
    public var pendingStoreOperationIDs: [OperationID] {
        pendingCloudOperationIDs
    }

    public var operationCount: Int {
        operationLog.count
    }

    public func materialize() -> SpaceState {
        operationLog.materialize()
    }

    public var state: SpaceState {
        materialize()
    }

    @discardableResult
    public mutating func append(
        _ operations: [EditOperation],
        source: OperationSyncSource
    ) -> OperationSyncResult {
        appendOperations(operations, source: source)
    }

    public func materialize(operations: [EditOperation], onto state: SpaceState) -> SpaceState {
        Materializer(compatibilityPolicy: operationLog.compatibilityPolicy)
            .materialize(operations: operations, onto: state)
    }

    public func materialize(operations: [EditOperation], onto state: inout SpaceState) {
        Materializer(compatibilityPolicy: operationLog.compatibilityPolicy)
            .materialize(operations: operations, onto: &state)
    }

    @discardableResult
    public mutating func appendLocal(_ operation: EditOperation) -> OperationSyncResult {
        appendOperations([operation], source: .local)
    }

    @discardableResult
    public mutating func appendLocal(contentsOf operations: [EditOperation]) -> OperationSyncResult {
        appendOperations(operations, source: .local)
    }

    @discardableResult
    public mutating func importEnvelopeData(_ data: Data,
                                            source: OperationSyncSource) throws -> OperationSyncResult {
        let start = Date()
        let envelope = try OperationCodec.decodeEnvelope(from: data)
        let result = try importEnvelope(envelope, source: source)
        EditSpaceInstrumentation.log(
            "sync.importData",
            keywords: ["transport", "decode", "perf", keyword(for: source)],
            "space=\(spaceID.rawValue) source=\(source.description) bytes=\(data.count) accepted=\(result.acceptedOperationIDs.count) duplicate=\(result.duplicateOperationIDs.count) rejected=\(result.rejectedOperationIDs.count) elapsedMs=\(EditSpaceInstrumentation.milliseconds(since: start))",
            level: result.rejectedOperationIDs.isEmpty ? .info : .warning
        )
        return result
    }

    @discardableResult
    public mutating func importEnvelope(_ envelope: OperationEnvelope,
                                        source: OperationSyncSource) throws -> OperationSyncResult {
        guard envelope.kind == OperationEnvelope.kind else {
            EditSpaceInstrumentation.log(
                "sync.importRejected",
                keywords: ["transport", "decode", "compat", keyword(for: source)],
                "space=\(spaceID.rawValue) source=\(source.description) reason=unsupported-envelope-kind kind=\(envelope.kind)",
                level: .error
            )
            throw OperationSyncError.unsupportedEnvelopeKind(envelope.kind)
        }

        guard envelope.spaceID == spaceID else {
            EditSpaceInstrumentation.log(
                "sync.importRejected",
                keywords: ["transport", "compat", keyword(for: source)],
                "space=\(spaceID.rawValue) source=\(source.description) reason=space-mismatch actual=\(envelope.spaceID.rawValue)",
                level: .error
            )
            throw OperationSyncError.spaceMismatch(expected: spaceID, actual: envelope.spaceID)
        }

        return appendOperations(envelope.operations, source: source)
    }

    public func makePeerBatch(maxOperationCount: Int? = nil,
                              reliability: OperationTransportReliability = .fast) throws -> OperationOutboundBatch? {
        let operationIDs = pendingPeerQueue.prefix(maxOperationCount ?? configuration.maxEnvelopeOperationCount)
        guard !operationIDs.isEmpty else { return nil }
        let operations = try operations(for: operationIDs)
        let batch = try OperationOutboundBatch(spaceID: spaceID,
                                                       operations: operations,
                                                       reliability: reliability)
        EditSpaceInstrumentation.log(
            "sync.peerBatchPrepared",
            keywords: ["transport", "peer", "queue", "codec"],
            "space=\(spaceID.rawValue) ops=\(batch.operationIDs.count) bytes=\(batch.data.count) reliability=\(reliability.rawValue) pendingPeer=\(pendingPeerQueue.count)"
        )
        return batch
    }

    /// Encodes the complete retained operation history without changing either
    /// pending transport queue. Use this to bring a newly connected or
    /// reconnected peer up to date.
    public func makeHistoryBatches(
        maxOperationCount: Int? = nil,
        reliability: OperationTransportReliability = .durable
    ) throws -> [OperationOutboundBatch] {
        let chunkSize = max(1, maxOperationCount ?? configuration.maxEnvelopeOperationCount)
        let operations = operationLog.operations
        guard !operations.isEmpty else { return [] }

        return try stride(from: 0, to: operations.count, by: chunkSize).map { startIndex in
            let endIndex = min(startIndex + chunkSize, operations.count)
            return try OperationOutboundBatch(
                spaceID: spaceID,
                operations: Array(operations[startIndex..<endIndex]),
                reliability: reliability
            )
        }
    }

    public mutating func markPeerBatchSent(_ batch: OperationOutboundBatch) {
        pendingPeerQueue.remove(contentsOf: batch.operationIDs)
        EditSpaceInstrumentation.log(
            "sync.peerBatchSent",
            keywords: ["transport", "peer", "queue"],
            "space=\(spaceID.rawValue) ops=\(batch.operationIDs.count) pendingPeer=\(pendingPeerQueue.count) reliability=\(batch.reliability.rawValue)"
        )
    }

    public func makeCloudRecords(maxOperationCount: Int? = nil) throws -> [OperationStoreRecord] {
        let operationIDs = pendingCloudQueue.prefix(maxOperationCount ?? configuration.maxEnvelopeOperationCount)
        guard !operationIDs.isEmpty else { return [] }
        let records = try operations(for: operationIDs).map(OperationStoreRecord.init(operation:))
        EditSpaceInstrumentation.log(
            "sync.cloudRecordsPrepared",
            keywords: ["transport", "cloud", "queue", "store", "codec"],
            "space=\(spaceID.rawValue) records=\(records.count) pendingCloud=\(pendingCloudQueue.count)"
        )
        return records
    }

    public mutating func markCloudRecordsSaved(_ records: [OperationStoreRecord]) {
        pendingCloudQueue.remove(contentsOf: records.map(\.operationID))
        EditSpaceInstrumentation.log(
            "sync.cloudRecordsMarkedSaved",
            keywords: ["transport", "cloud", "queue", "store"],
            "space=\(spaceID.rawValue) records=\(records.count) pendingCloud=\(pendingCloudQueue.count)"
        )
    }

    public mutating func markCloudSaveResult(_ result: OperationStoreSaveResult) {
        pendingCloudQueue.remove(contentsOf: result.acceptedOperationIDs)
        EditSpaceInstrumentation.log(
            "sync.cloudSaveResult",
            keywords: ["transport", "cloud", "queue", "store", "retry"],
            "space=\(spaceID.rawValue) inserted=\(result.insertedOperationIDs.count) duplicate=\(result.duplicateOperationIDs.count) conflicts=\(result.conflictingOperationIDs.count) pendingCloud=\(pendingCloudQueue.count)",
            level: result.hasConflicts ? .error : .info
        )
    }

    @discardableResult
    public mutating func uploadPendingOperations(to store: any OperationRecordStore,
                                                 maxOperationCount: Int? = nil) async throws -> OperationStoreSaveResult {
        let records = try makeCloudRecords(maxOperationCount: maxOperationCount)
        guard !records.isEmpty else {
            EditSpaceInstrumentation.log(
                "sync.cloudUploadSkipped",
                keywords: ["transport", "cloud", "queue"],
                "space=\(spaceID.rawValue) reason=no-pending-records"
            )
            return OperationStoreSaveResult()
        }

        let result = try await store.save(records)
        markCloudSaveResult(result)
        return result
    }

    @discardableResult
    public mutating func refresh(from store: any OperationRecordStore,
                                 limit: Int = 100) async throws -> OperationStoreRefreshResult {
        let start = Date()
        let page = try await store.fetch(spaceID: spaceID, after: storeCursor, limit: limit)
        var importResult = OperationSyncResult()
        var decodeFailures: [OperationStoreDecodeFailure] = []

        for record in page.records {
            do {
                let operation = try record.operation()
                let result = appendOperations([operation], source: .cloud)
                importResult.merge(result)
            } catch {
                let failure = OperationStoreDecodeFailure(recordName: record.recordName,
                                                                  operationID: record.operationID,
                                                                  message: error.localizedDescription)
                decodeFailures.append(failure)
                EditSpaceInstrumentation.log(
                    "sync.cloudRecordDecodeFailed",
                    keywords: ["transport", "cloud", "store", "decode", "compat"],
                    "space=\(spaceID.rawValue) record=\(record.recordName) op=\(record.operationID.rawValue) error=\(error.localizedDescription)",
                    level: .error
                )
            }
        }

        storeCursor = page.cursor
        let refreshResult = OperationStoreRefreshResult(page: page,
                                                                importResult: importResult,
                                                                decodeFailures: decodeFailures)
        EditSpaceInstrumentation.log(
            "sync.cloudRefreshFinished",
            keywords: ["transport", "cloud", "store", "queue", "perf"],
            "space=\(spaceID.rawValue) fetched=\(page.records.count) accepted=\(importResult.acceptedOperationIDs.count) duplicate=\(importResult.duplicateOperationIDs.count) decodeFailures=\(decodeFailures.count) cursor=\(storeCursor?.rawValue ?? "nil") hasMore=\(page.hasMore) pendingPeer=\(pendingPeerQueue.count) pendingCloud=\(pendingCloudQueue.count) elapsedMs=\(EditSpaceInstrumentation.milliseconds(since: start))",
            level: decodeFailures.isEmpty ? .info : .error
        )
        return refreshResult
    }

    private mutating func appendOperations(_ operations: [EditOperation],
                                           source: OperationSyncSource) -> OperationSyncResult {
        let start = Date()
        var result = OperationSyncResult()

        for operation in operations {
            let appendResult = operationLog.append(operation)
            result.record(operation: operation, appendResult: appendResult)
        }

        enqueueAcceptedOperationIDs(result.acceptedOperationIDs, source: source)
        EditSpaceInstrumentation.log(
            "sync.appendFinished",
            keywords: ["transport", "op-log", "queue", keyword(for: source), "perf"],
            "space=\(spaceID.rawValue) source=\(source.description) input=\(operations.count) accepted=\(result.acceptedOperationIDs.count) duplicate=\(result.duplicateOperationIDs.count) rejected=\(result.rejectedOperationIDs.count) pendingPeer=\(pendingPeerQueue.count) pendingCloud=\(pendingCloudQueue.count) elapsedMs=\(EditSpaceInstrumentation.milliseconds(since: start))",
            level: result.rejectedOperationIDs.isEmpty ? .info : .warning
        )
        return result
    }

    private mutating func enqueueAcceptedOperationIDs(_ operationIDs: [OperationID],
                                                      source: OperationSyncSource) {
        guard !operationIDs.isEmpty else { return }

        switch source {
        case .local:
            pendingPeerQueue.enqueue(contentsOf: operationIDs)
            pendingCloudQueue.enqueue(contentsOf: operationIDs)
        case .peer:
            if configuration.relayPeerImports {
                pendingPeerQueue.enqueue(contentsOf: operationIDs)
            }
            pendingCloudQueue.enqueue(contentsOf: operationIDs)
        case .cloud:
            pendingPeerQueue.enqueue(contentsOf: operationIDs)
        }

        EditSpaceInstrumentation.log(
            "sync.queueUpdated",
            keywords: ["transport", "queue", keyword(for: source)],
            "space=\(spaceID.rawValue) source=\(source.description) accepted=\(operationIDs.count) pendingPeer=\(pendingPeerQueue.count) pendingCloud=\(pendingCloudQueue.count) relayPeerImports=\(configuration.relayPeerImports)"
        )
    }

    private func operations(for operationIDs: [OperationID]) throws -> [EditOperation] {
        try operationIDs.map { operationID in
            guard let operation = operationLog.operationsByID[operationID] else {
                EditSpaceInstrumentation.log(
                    "sync.queueMissingOperation",
                    keywords: ["transport", "queue", "op-log"],
                    "space=\(spaceID.rawValue) op=\(operationID.rawValue)",
                    level: .error
                )
                throw OperationSyncError.missingOperation(operationID)
            }
            return operation
        }
    }

    private func keyword(for source: OperationSyncSource) -> String {
        switch source {
        case .local:
            return "local"
        case .peer:
            return "peer"
        case .cloud:
            return "cloud"
        }
    }
}

import Foundation

public enum OperationTransportReliability: String, Codable, Hashable, Sendable {
    case fast
    case durable
}

public enum OperationSyncSource: Hashable, Sendable, CustomStringConvertible {
    case local
    case peer(String?)
    case cloud

    public var description: String {
        switch self {
        case .local:
            return "local"
        case .peer(let peerID):
            return peerID.map { "peer:\($0)" } ?? "peer"
        case .cloud:
            return "cloud"
        }
    }
}

public struct OperationSyncConfiguration: Equatable, Sendable {
    public var maxEnvelopeOperationCount: Int
    public var relayPeerImports: Bool

    public init(maxEnvelopeOperationCount: Int = 64,
                relayPeerImports: Bool = false) {
        self.maxEnvelopeOperationCount = max(1, maxEnvelopeOperationCount)
        self.relayPeerImports = relayPeerImports
    }
}

public struct OperationOutboundBatch: Equatable, Sendable {
    public let spaceID: SpaceID
    public let operationIDs: [OperationID]
    public let envelope: OperationEnvelope
    public let data: Data
    public let reliability: OperationTransportReliability

    public init(spaceID: SpaceID,
                operations: [EditOperation],
                reliability: OperationTransportReliability) throws {
        self.spaceID = spaceID
        self.operationIDs = operations.map(\.operationID)
        self.envelope = OperationEnvelope(spaceID: spaceID, operations: operations)
        self.data = try OperationCodec.encode(envelope)
        self.reliability = reliability
    }
}

public struct OperationSyncResult: Equatable, Sendable {
    public private(set) var appendedOperationIDs: [OperationID]
    public private(set) var duplicateOperationIDs: [OperationID]
    public private(set) var compatibilityStoredOperationIDs: [OperationID]
    public private(set) var rejectedOperationIDs: [OperationID]
    public private(set) var compatibilityProblems: [CompatibilityProblem]

    public init(appendedOperationIDs: [OperationID] = [],
                duplicateOperationIDs: [OperationID] = [],
                compatibilityStoredOperationIDs: [OperationID] = [],
                rejectedOperationIDs: [OperationID] = [],
                compatibilityProblems: [CompatibilityProblem] = []) {
        self.appendedOperationIDs = appendedOperationIDs
        self.duplicateOperationIDs = duplicateOperationIDs
        self.compatibilityStoredOperationIDs = compatibilityStoredOperationIDs
        self.rejectedOperationIDs = rejectedOperationIDs
        self.compatibilityProblems = compatibilityProblems
    }

    public var acceptedOperationIDs: [OperationID] {
        appendedOperationIDs + compatibilityStoredOperationIDs
    }

    public var accepted: [OperationID] { acceptedOperationIDs }
    public var duplicates: [OperationID] { duplicateOperationIDs }

    public var importedOperationIDs: [OperationID] {
        acceptedOperationIDs + duplicateOperationIDs
    }

    public var hasChanges: Bool {
        !acceptedOperationIDs.isEmpty
    }

    mutating func record(operation: EditOperation, appendResult: AppendResult) {
        switch appendResult {
        case .appended:
            appendedOperationIDs.append(operation.operationID)
        case .duplicate:
            duplicateOperationIDs.append(operation.operationID)
        case .storedWithCompatibilityProblems(let problems):
            compatibilityStoredOperationIDs.append(operation.operationID)
            compatibilityProblems.append(contentsOf: problems)
        case .rejected(let problems):
            rejectedOperationIDs.append(operation.operationID)
            compatibilityProblems.append(contentsOf: problems)
        }
    }

    mutating func merge(_ other: OperationSyncResult) {
        appendedOperationIDs.append(contentsOf: other.appendedOperationIDs)
        duplicateOperationIDs.append(contentsOf: other.duplicateOperationIDs)
        compatibilityStoredOperationIDs.append(contentsOf: other.compatibilityStoredOperationIDs)
        rejectedOperationIDs.append(contentsOf: other.rejectedOperationIDs)
        compatibilityProblems.append(contentsOf: other.compatibilityProblems)
    }
}

public enum OperationSyncError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedEnvelopeKind(String)
    case spaceMismatch(expected: SpaceID, actual: SpaceID)
    case missingOperation(OperationID)

    public var errorDescription: String? {
        switch self {
        case .unsupportedEnvelopeKind(let kind):
            return "Unsupported EditSpace operation envelope kind: \(kind)"
        case .spaceMismatch(let expected, let actual):
            return "EditSpace operation space mismatch: expected \(expected.rawValue), got \(actual.rawValue)"
        case .missingOperation(let operationID):
            return "EditSpace operation queue references missing operation: \(operationID.rawValue)"
        }
    }
}

public struct OperationIDQueue: Equatable, Sendable {
    private var orderedOperationIDs: [OperationID]
    private var queuedOperationIDs: Set<OperationID>

    public init(_ operationIDs: [OperationID] = []) {
        orderedOperationIDs = []
        queuedOperationIDs = []
        enqueue(contentsOf: operationIDs)
    }

    public var operationIDs: [OperationID] {
        orderedOperationIDs
    }

    public var count: Int {
        orderedOperationIDs.count
    }

    public var isEmpty: Bool {
        orderedOperationIDs.isEmpty
    }

    public mutating func enqueue(_ operationID: OperationID) {
        guard !queuedOperationIDs.contains(operationID) else { return }
        orderedOperationIDs.append(operationID)
        queuedOperationIDs.insert(operationID)
    }

    public mutating func enqueue(contentsOf operationIDs: [OperationID]) {
        for operationID in operationIDs {
            enqueue(operationID)
        }
    }

    public func prefix(_ maxCount: Int?) -> [OperationID] {
        guard let maxCount else { return orderedOperationIDs }
        guard maxCount > 0 else { return [] }
        return Array(orderedOperationIDs.prefix(maxCount))
    }

    public mutating func remove(_ operationID: OperationID) {
        guard queuedOperationIDs.remove(operationID) != nil else { return }
        orderedOperationIDs.removeAll { $0 == operationID }
    }

    public mutating func remove(contentsOf operationIDs: [OperationID]) {
        for operationID in operationIDs {
            remove(operationID)
        }
    }
}

import Foundation

public struct OperationStoreCursor: RawRepresentable, Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static func < (lhs: OperationStoreCursor, rhs: OperationStoreCursor) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct OperationStoreRecord: Equatable, Sendable {
    public let recordName: String
    public let spaceID: SpaceID
    public let operationID: OperationID
    public let encodedOperation: Data
    public let createdAt: Date?

    public init(recordName: String,
                spaceID: SpaceID,
                operationID: OperationID,
                encodedOperation: Data,
                createdAt: Date? = Date()) {
        self.recordName = recordName
        self.spaceID = spaceID
        self.operationID = operationID
        self.encodedOperation = encodedOperation
        self.createdAt = createdAt
    }

    public init(operation: EditOperation) throws {
        let data = try OperationCodec.encode(operation)
        self.init(recordName: OperationStoreRecord.recordName(spaceID: operation.spaceID, operationID: operation.operationID),
                  spaceID: operation.spaceID,
                  operationID: operation.operationID,
                  encodedOperation: data,
                  createdAt: operation.createdAt)
    }

    public func operation() throws -> EditOperation {
        try OperationCodec.decodeOperation(from: encodedOperation)
    }

    public static func recordName(spaceID: SpaceID, operationID: OperationID) -> String {
        "\(spaceID.rawValue):\(operationID.rawValue)"
    }
}

public struct OperationStoreSaveResult: Equatable, Sendable {
    public private(set) var insertedOperationIDs: [OperationID]
    public private(set) var duplicateOperationIDs: [OperationID]
    public private(set) var conflictingOperationIDs: [OperationID]

    public init(insertedOperationIDs: [OperationID] = [],
                duplicateOperationIDs: [OperationID] = [],
                conflictingOperationIDs: [OperationID] = []) {
        self.insertedOperationIDs = insertedOperationIDs
        self.duplicateOperationIDs = duplicateOperationIDs
        self.conflictingOperationIDs = conflictingOperationIDs
    }

    public var acceptedOperationIDs: [OperationID] {
        insertedOperationIDs + duplicateOperationIDs
    }

    public var hasConflicts: Bool {
        !conflictingOperationIDs.isEmpty
    }

    mutating func recordInserted(_ operationID: OperationID) {
        insertedOperationIDs.append(operationID)
    }

    mutating func recordDuplicate(_ operationID: OperationID) {
        duplicateOperationIDs.append(operationID)
    }

    mutating func recordConflict(_ operationID: OperationID) {
        conflictingOperationIDs.append(operationID)
    }
}

public struct OperationStorePage: Equatable, Sendable {
    public let records: [OperationStoreRecord]
    public let cursor: OperationStoreCursor?
    public let hasMore: Bool

    public init(records: [OperationStoreRecord],
                cursor: OperationStoreCursor?,
                hasMore: Bool) {
        self.records = records
        self.cursor = cursor
        self.hasMore = hasMore
    }
}

public protocol OperationRecordStore: Sendable {
    func save(_ records: [OperationStoreRecord]) async throws -> OperationStoreSaveResult
    func fetch(spaceID: SpaceID,
               after cursor: OperationStoreCursor?,
               limit: Int) async throws -> OperationStorePage
}

public actor OperationMemoryRecordStore: OperationRecordStore {
    private struct StoredEntry {
        let record: OperationStoreRecord
        let revision: Int
    }

    private var recordsByDocumentID: [SpaceID: [OperationID: StoredEntry]] = [:]
    private var revision = 0

    public init() {}

    public func save(_ records: [OperationStoreRecord]) async throws -> OperationStoreSaveResult {
        let start = Date()
        var result = OperationStoreSaveResult()

        for record in records {
            var documentRecords = recordsByDocumentID[record.spaceID] ?? [:]
            if let existingEntry = documentRecords[record.operationID] {
                if existingEntry.record.encodedOperation == record.encodedOperation {
                    result.recordDuplicate(record.operationID)
                } else {
                    result.recordConflict(record.operationID)
                }
                recordsByDocumentID[record.spaceID] = documentRecords
                continue
            }

            revision += 1
            documentRecords[record.operationID] = StoredEntry(record: record, revision: revision)
            recordsByDocumentID[record.spaceID] = documentRecords
            result.recordInserted(record.operationID)
        }

        EditSpaceInstrumentation.log(
            "store.save",
            keywords: ["transport", "cloud", "store", "perf"],
            "records=\(records.count) inserted=\(result.insertedOperationIDs.count) duplicate=\(result.duplicateOperationIDs.count) conflicts=\(result.conflictingOperationIDs.count) elapsedMs=\(EditSpaceInstrumentation.milliseconds(since: start))",
            level: result.hasConflicts ? .error : .info
        )

        return result
    }

    public func fetch(spaceID: SpaceID,
                      after cursor: OperationStoreCursor?,
                      limit: Int) async throws -> OperationStorePage {
        let start = Date()
        let lowerBoundRevision = cursor.flatMap { Int($0.rawValue) } ?? 0
        let effectiveLimit = max(1, limit)
        let entries = (recordsByDocumentID[spaceID] ?? [:])
            .values
            .filter { $0.revision > lowerBoundRevision }
            .sorted { lhs, rhs in
                if lhs.revision != rhs.revision { return lhs.revision < rhs.revision }
                return lhs.record.operationID < rhs.record.operationID
            }
        let limitedEntries = Array(entries.prefix(effectiveLimit))
        let pageCursor = limitedEntries.last
            .map { OperationStoreCursor(rawValue: String($0.revision)) }
            ?? cursor
        let page = OperationStorePage(records: limitedEntries.map(\.record),
                                              cursor: pageCursor,
                                              hasMore: entries.count > limitedEntries.count)

        EditSpaceInstrumentation.log(
            "store.fetch",
            keywords: ["transport", "cloud", "store", "perf"],
            "space=\(spaceID.rawValue) after=\(cursor?.rawValue ?? "nil") records=\(page.records.count) cursor=\(page.cursor?.rawValue ?? "nil") hasMore=\(page.hasMore) elapsedMs=\(EditSpaceInstrumentation.milliseconds(since: start))"
        )

        return page
    }

    public func records(spaceID: SpaceID) async -> [OperationStoreRecord] {
        (recordsByDocumentID[spaceID] ?? [:])
            .values
            .sorted { lhs, rhs in
                if lhs.revision != rhs.revision { return lhs.revision < rhs.revision }
                return lhs.record.operationID < rhs.record.operationID
            }
            .map(\.record)
    }
}


enum EditSpaceLogLevel {
    case verbose
    case info
    case warning
    case error
}

enum EditSpaceInstrumentation {
    static func log(
        _ event: String,
        keywords: [String],
        _ message: @autoclosure () -> String,
        level: EditSpaceLogLevel = .info
    ) {
        _ = event
        _ = keywords
        _ = message()
        _ = level
    }

    static func milliseconds(since start: Date) -> String {
        String(format: "%.2f", Date().timeIntervalSince(start) * 1_000)
    }
}
