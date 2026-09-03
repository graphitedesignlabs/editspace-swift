import Foundation

public enum AppendResult: Equatable, Sendable {
    case accepted
    case duplicate
    case rejected([CompatibilityProblem])
}

/// An immutable, idempotent operation set. Unsupported operations remain preserved.
public struct OperationLog: Sendable {
    public let documentID: DocumentID
    public let compatibilityPolicy: CompatibilityPolicy
    public private(set) var operationsByID: [OperationID: EditOperation] = [:]
    public private(set) var rejectedOperationsByID: [OperationID: EditOperation] = [:]
    public private(set) var problems: [CompatibilityProblem] = []

    public init(documentID: DocumentID, compatibilityPolicy: CompatibilityPolicy = CompatibilityPolicy()) {
        self.documentID = documentID
        self.compatibilityPolicy = compatibilityPolicy
    }

    @discardableResult
    public mutating func append(_ operation: EditOperation) -> AppendResult {
        if let existing = operationsByID[operation.operationID] ?? rejectedOperationsByID[operation.operationID] {
            guard existing == operation else {
                let collision = CompatibilityProblem(
                    kind: .operationIDCollision,
                    operationID: operation.operationID,
                    producer: operation.producer,
                    message: "Operation ID has different immutable content"
                )
                problems.append(collision)
                return .rejected([collision])
            }
            return .duplicate
        }

        let operationProblems = compatibilityPolicy.problems(for: operation, expectedDocumentID: documentID)
        guard operationProblems.isEmpty else {
            rejectedOperationsByID[operation.operationID] = operation
            problems.append(contentsOf: operationProblems)
            return .rejected(operationProblems)
        }
        operationsByID[operation.operationID] = operation
        return .accepted
    }

    public var operations: [EditOperation] {
        Self.causallyOrdered(Array(operationsByID.values))
    }

    /// Deterministic topological ordering; missing or cyclic dependencies fall back to stamp order.
    public static func causallyOrdered(_ operations: [EditOperation]) -> [EditOperation] {
        let byID = Dictionary(uniqueKeysWithValues: operations.map { ($0.operationID, $0) })
        var remaining = Set(byID.keys)
        var emitted = Set<OperationID>()
        var output: [EditOperation] = []

        while !remaining.isEmpty {
            let ready = remaining.compactMap { byID[$0] }.filter { operation in
                operation.dependencies.allSatisfy { byID[$0] == nil || emitted.contains($0) }
            }.sorted { $0.stamp < $1.stamp }
            guard !ready.isEmpty else {
                output.append(contentsOf: remaining.compactMap { byID[$0] }.sorted { $0.stamp < $1.stamp })
                break
            }
            for operation in ready {
                output.append(operation)
                emitted.insert(operation.operationID)
                remaining.remove(operation.operationID)
            }
        }
        return output
    }
}
