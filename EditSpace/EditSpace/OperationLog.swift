import Foundation

public enum AppendResult: Equatable, Sendable {
    case appended
    case duplicate
    case storedWithCompatibilityProblems([CompatibilityProblem])
    case rejected([CompatibilityProblem])
}

public extension AppendResult {
    /// The v0.1 spelling retained for source compatibility.
    static var accepted: Self { .appended }
}

public struct OperationLog: Sendable {
    public let spaceID: SpaceID
    public let compatibilityPolicy: CompatibilityPolicy
    public private(set) var operationsByID: [OperationID: EditOperation]

    public init(spaceID: SpaceID,
                operations: [EditOperation] = [],
                compatibilityPolicy: CompatibilityPolicy = CompatibilityPolicy()) {
        self.spaceID = spaceID
        self.compatibilityPolicy = compatibilityPolicy
        self.operationsByID = [:]
        for operation in operations {
            _ = append(operation)
        }
    }

    public var operations: [EditOperation] {
        Materializer.orderedOperations(Array(operationsByID.values))
    }

    public var count: Int {
        operationsByID.count
    }

    @discardableResult
    public mutating func append(_ operation: EditOperation) -> AppendResult {
        if let existing = operationsByID[operation.operationID] {
            guard existing != operation else {
                EditSpaceInstrumentation.log(
                    "append.duplicate",
                    keywords: ["op-log"],
                    "space=\(spaceID.rawValue) op=\(operation.operationID.rawValue) actor=\(operation.actorID.rawValue) seq=\(operation.sequence)"
                )
                return .duplicate
            }

            let collision = CompatibilityProblem(
                kind: .operationIDCollision,
                operationID: operation.operationID,
                producer: operation.producer,
                message: "Operation ID is already associated with different immutable content"
            )
            EditSpaceInstrumentation.log(
                "append.rejected",
                keywords: ["op-log", "compat"],
                "space=\(spaceID.rawValue) op=\(operation.operationID.rawValue) problems=\(collision.description)",
                level: .error
            )
            return .rejected([collision])
        }

        let problems = compatibilityPolicy.problems(for: operation, expectedSpaceID: spaceID)
        let rejectionKinds: Set<CompatibilityProblemKind> = [
            .spaceMismatch,
            .invalidOperation,
            .operationIDCollision
        ]
        if problems.contains(where: { rejectionKinds.contains($0.kind) }) {
            EditSpaceInstrumentation.log(
                "append.rejected",
                keywords: ["op-log", "compat"],
                "space=\(spaceID.rawValue) op=\(operation.operationID.rawValue) problems=\(problems.map(\.description).joined(separator: " | "))",
                level: .error
            )
            return .rejected(problems)
        }

        operationsByID[operation.operationID] = operation

        if problems.isEmpty {
            EditSpaceInstrumentation.log(
                "append.success",
                keywords: ["op-log"],
                "space=\(spaceID.rawValue) op=\(operation.operationID.rawValue) actor=\(operation.actorID.rawValue) seq=\(operation.sequence) action=\(operation.action.rawValue) entity=\(operation.entity.rawValue) target=\(operation.targetID?.rawValue ?? "nil") count=\(operationsByID.count)"
            )
            return .appended
        } else {
            EditSpaceInstrumentation.log(
                "append.compatibilityStored",
                keywords: ["op-log", "compat", "schema"],
                "space=\(spaceID.rawValue) op=\(operation.operationID.rawValue) problems=\(problems.map(\.description).joined(separator: " | ")) count=\(operationsByID.count)",
                level: .warning
            )
            return .storedWithCompatibilityProblems(problems)
        }
    }

    @discardableResult
    public mutating func append(contentsOf operations: [EditOperation]) -> [AppendResult] {
        operations.map { append($0) }
    }

    public func materialize() -> SpaceState {
        Materializer(compatibilityPolicy: compatibilityPolicy)
            .materialize(spaceID: spaceID, operations: operations)
    }
}
