import Foundation

public struct Materializer: Sendable {
    public let compatibilityPolicy: CompatibilityPolicy

    public init(compatibilityPolicy: CompatibilityPolicy = CompatibilityPolicy()) {
        self.compatibilityPolicy = compatibilityPolicy
    }

    /// Materializes the accepted operations in a log using its compatibility policy.
    public static func materialize(_ log: OperationLog) -> SpaceState {
        Materializer(compatibilityPolicy: log.compatibilityPolicy)
            .materialize(spaceID: log.spaceID, operations: log.operations)
    }

    public func materialize(spaceID: SpaceID, operations: [EditOperation]) -> SpaceState {
        let start = Date()
        let orderedOperations = Self.orderedOperations(operations)
        var state = SpaceState(spaceID: spaceID)

        EditSpaceInstrumentation.log(
            "materialize.start",
            keywords: ["merge", "materialize", "perf"],
            "space=\(spaceID.rawValue) ops=\(operations.count) orderedOps=\(orderedOperations.count)"
        )

        for operation in orderedOperations {
            apply(operation, to: &state, expectedSpaceID: spaceID)
        }

        EditSpaceInstrumentation.log(
            "materialize.finish",
            keywords: ["merge", "materialize", "perf"],
            "space=\(spaceID.rawValue) ops=\(operations.count) applied=\(state.appliedOperationIDs.count) skipped=\(state.skippedOperationIDs.count) conflicts=\(state.conflicts.count) elapsedMs=\(EditSpaceInstrumentation.milliseconds(since: start))"
        )

        return state
    }

    /// Applies a newly accepted batch to an existing materialized state. This keeps
    /// high-frequency edits proportional to the batch size instead of the full log.
    public func materialize(operations: [EditOperation], onto existingState: SpaceState) -> SpaceState {
        var state = existingState
        materialize(operations: operations, onto: &state)
        return state
    }

    /// Mutates an existing state in place so high-frequency streams don't
    /// repeatedly copy the state's growing operation-ID sets and dictionaries.
    public func materialize(operations: [EditOperation], onto state: inout SpaceState) {
        let start = Date()
        let orderedOperations = Self.orderedOperations(operations)

        for operation in orderedOperations {
            apply(operation, to: &state, expectedSpaceID: state.spaceID)
        }

        EditSpaceInstrumentation.log(
            "materialize.incremental",
            keywords: ["merge", "materialize", "perf"],
            "space=\(state.spaceID.rawValue) ops=\(operations.count) elapsedMs=\(EditSpaceInstrumentation.milliseconds(since: start))"
        )
    }

    public static func orderedOperations(_ operations: [EditOperation]) -> [EditOperation] {
        var operationsByID: [OperationID: EditOperation] = [:]
        for operation in operations {
            operationsByID[operation.operationID] = operation
        }

        var remaining = Set(operationsByID.keys)
        var applied = Set<OperationID>()
        var ordered: [EditOperation] = []

        while !remaining.isEmpty {
            let ready = remaining.compactMap { operationID -> EditOperation? in
                guard let operation = operationsByID[operationID] else { return nil }
                let dependenciesSatisfied = operation.dependencies.allSatisfy { dependency in
                    operationsByID[dependency] == nil || applied.contains(dependency)
                }
                return dependenciesSatisfied ? operation : nil
            }.sorted(by: operationSort)

            if let next = ready.first {
                ordered.append(next)
                remaining.remove(next.operationID)
                applied.insert(next.operationID)
            } else {
                let cycleBreak = remaining.compactMap { operationsByID[$0] }.sorted(by: operationSort).first!
                EditSpaceInstrumentation.log(
                    "order.cycleBreak",
                    keywords: ["merge", "dependency"],
                    "space=\(cycleBreak.spaceID.rawValue) op=\(cycleBreak.operationID.rawValue) deps=\(cycleBreak.dependencies.map(\.rawValue).joined(separator: ","))",
                    level: .warning
                )
                ordered.append(cycleBreak)
                remaining.remove(cycleBreak.operationID)
                applied.insert(cycleBreak.operationID)
            }
        }

        return ordered
    }

    private static func operationSort(_ lhs: EditOperation, _ rhs: EditOperation) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        if lhs.actorID != rhs.actorID { return lhs.actorID < rhs.actorID }
        return lhs.operationID < rhs.operationID
    }

    private func apply(_ operation: EditOperation,
                       to state: inout SpaceState,
                       expectedSpaceID: SpaceID) {
        guard !state.appliedOperationIDs.contains(operation.operationID),
              !state.skippedOperationIDs.contains(operation.operationID) else {
            return
        }

        let problems = compatibilityPolicy.problems(for: operation, expectedSpaceID: expectedSpaceID)
        if !problems.isEmpty {
            state.markSkipped(operation)
            state.addConflict(Conflict(
                kind: .compatibility,
                operationID: operation.operationID,
                reference: operation.targetReference,
                message: "Operation has compatibility problems",
                compatibilityProblems: problems
            ))
            EditSpaceInstrumentation.log(
                "apply.compatibilitySkip",
                keywords: ["merge", "compat", "schema"],
                "space=\(operation.spaceID.rawValue) op=\(operation.operationID.rawValue) action=\(operation.action.rawValue) entity=\(operation.entity.rawValue) problems=\(problems.map(\.description).joined(separator: " | "))",
                level: .warning
            )
            return
        }

        switch operation.action {
        case .create:
            applyCreate(operation, to: &state)
        case .update:
            applyUpdate(operation, to: &state)
        case .delete:
            applyDelete(operation, to: &state)
        case .duplicate:
            applyDuplicate(operation, to: &state)
        case .link:
            applyLink(operation, to: &state, shouldLink: true)
        case .unlink:
            applyLink(operation, to: &state, shouldLink: false)
        default:
            state.markSkipped(operation)
            state.addConflict(Conflict(
                kind: .invalidOperation,
                operationID: operation.operationID,
                reference: operation.targetReference,
                message: "Unsupported action reached materializer: \(operation.action.rawValue)"
            ))
        }
    }

    private func applyCreate(_ operation: EditOperation, to state: inout SpaceState) {
        let reference: EntityReference
        if operation.entity == .space || operation.entity == .document {
            reference = EntityReference(kind: .space, id: EntityID(rawValue: operation.spaceID.rawValue))
        } else if let targetReference = operation.targetReference {
            reference = targetReference
        } else {
            addInvalidTargetConflict(operation, to: &state, message: "Create operation has no target")
            return
        }

        if state.isTombstoned(reference) {
            state.markSkipped(operation)
            state.addConflict(Conflict(
                kind: .tombstonedTarget,
                operationID: operation.operationID,
                reference: reference,
                message: "Create targets a tombstoned entity"
            ))
            EditSpaceInstrumentation.log(
                "create.tombstonedTarget",
                keywords: ["merge", "tombstone"],
                "space=\(operation.spaceID.rawValue) op=\(operation.operationID.rawValue) entity=\(reference.description)",
                level: .warning
            )
            return
        }

        if var existing = state.entities[reference] {
            existing.updateFields(operation.fields, with: operation)
            existing.updateArguments(operation.arguments, with: operation)
            state.upsertEntity(existing)
        } else {
            state.upsertEntity(EntityState(
                reference: reference,
                sourceID: operation.sourceID,
                fields: operation.fields,
                arguments: operation.arguments,
                createdBy: operation
            ))
        }

        state.markApplied(operation)
        EditSpaceInstrumentation.log(
            "create.apply",
            keywords: ["merge", "crud"],
            "space=\(operation.spaceID.rawValue) op=\(operation.operationID.rawValue) entity=\(reference.description) fields=\(operation.fields.count)"
        )
    }

    private func applyUpdate(_ operation: EditOperation, to state: inout SpaceState) {
        guard let reference = operation.targetReference else {
            addInvalidTargetConflict(operation, to: &state, message: "Update operation has no target")
            return
        }

        guard !state.isTombstoned(reference) else {
            state.markSkipped(operation)
            state.addConflict(Conflict(
                kind: .tombstonedTarget,
                operationID: operation.operationID,
                reference: reference,
                message: "Update targets a tombstoned entity"
            ))
            EditSpaceInstrumentation.log(
                "update.tombstonedTarget",
                keywords: ["merge", "tombstone"],
                "space=\(operation.spaceID.rawValue) op=\(operation.operationID.rawValue) entity=\(reference.description)",
                level: .warning
            )
            return
        }

        guard var entity = state.entities[reference] else {
            state.markSkipped(operation)
            state.addConflict(Conflict(
                kind: .missingTarget,
                operationID: operation.operationID,
                reference: reference,
                message: "Update target does not exist"
            ))
            EditSpaceInstrumentation.log(
                "update.missingTarget",
                keywords: ["merge"],
                "space=\(operation.spaceID.rawValue) op=\(operation.operationID.rawValue) entity=\(reference.description)",
                level: .warning
            )
            return
        }

        entity.updateFields(operation.fields, with: operation)
        entity.updateArguments(operation.arguments, with: operation)
        state.upsertEntity(entity)
        state.markApplied(operation)
    }

    private func applyDelete(_ operation: EditOperation, to state: inout SpaceState) {
        guard let reference = operation.targetReference else {
            addInvalidTargetConflict(operation, to: &state, message: "Delete operation has no target")
            return
        }

        state.tombstone(reference, with: operation)
        state.markApplied(operation)
        EditSpaceInstrumentation.log(
            "delete.tombstone",
            keywords: ["merge", "tombstone", "crud"],
            "space=\(operation.spaceID.rawValue) op=\(operation.operationID.rawValue) entity=\(reference.description)"
        )
    }

    private func applyDuplicate(_ operation: EditOperation, to state: inout SpaceState) {
        guard let targetReference = operation.targetReference else {
            addInvalidTargetConflict(operation, to: &state, message: "Duplicate operation has no target")
            return
        }
        guard let sourceID = operation.sourceID else {
            addInvalidTargetConflict(operation, to: &state, message: "Duplicate operation has no source")
            return
        }

        let sourceReference = EntityReference(kind: operation.entity, id: sourceID)
        guard !state.isTombstoned(sourceReference) else {
            state.markSkipped(operation)
            state.addConflict(Conflict(
                kind: .tombstonedTarget,
                operationID: operation.operationID,
                reference: sourceReference,
                message: "Duplicate source is tombstoned"
            ))
            EditSpaceInstrumentation.log(
                "duplicate.tombstonedSource",
                keywords: ["merge", "tombstone"],
                "space=\(operation.spaceID.rawValue) op=\(operation.operationID.rawValue) source=\(sourceReference.description) target=\(targetReference.description)",
                level: .warning
            )
            return
        }

        guard let source = state.entities[sourceReference] else {
            state.markSkipped(operation)
            state.addConflict(Conflict(
                kind: .missingSource,
                operationID: operation.operationID,
                reference: sourceReference,
                message: "Duplicate source does not exist"
            ))
            return
        }

        if state.entities[targetReference] != nil, !state.isTombstoned(targetReference) {
            state.markSkipped(operation)
            state.addConflict(Conflict(
                kind: .duplicateTargetAlreadyExists,
                operationID: operation.operationID,
                reference: targetReference,
                message: "Duplicate target already exists"
            ))
            return
        }

        var duplicatedFields = source.fields
        for (key, value) in operation.fields {
            duplicatedFields[key] = value
        }

        var duplicatedArguments = operation.arguments
        if operation.arguments["mode"]?.stringValue == "linked" {
            duplicatedArguments["linkedSource"] = .string(sourceID.rawValue)
        }

        state.upsertEntity(EntityState(
            reference: targetReference,
            sourceID: sourceID,
            fields: duplicatedFields,
            arguments: duplicatedArguments,
            createdBy: operation
        ))
        state.markApplied(operation)
        EditSpaceInstrumentation.log(
            "duplicate.apply",
            keywords: ["merge", "duplicate", "crud"],
            "space=\(operation.spaceID.rawValue) op=\(operation.operationID.rawValue) source=\(sourceReference.description) target=\(targetReference.description) mode=\(operation.arguments["mode"]?.stringValue ?? "copy")"
        )
    }

    private func applyLink(_ operation: EditOperation,
                           to state: inout SpaceState,
                           shouldLink: Bool) {
        guard let targetReference = operation.targetReference else {
            addInvalidTargetConflict(operation, to: &state, message: "Link operation has no target")
            return
        }
        guard let sourceID = operation.sourceID else {
            addInvalidTargetConflict(operation, to: &state, message: "Link operation has no source")
            return
        }

        let sourceKind = operation.arguments["sourceEntity"]?.stringValue.map { EntityKind(rawValue: $0) } ?? operation.entity
        let sourceReference = EntityReference(kind: sourceKind, id: sourceID)

        guard var target = state.entities[targetReference] else {
            state.markSkipped(operation)
            state.addConflict(Conflict(
                kind: .missingTarget,
                operationID: operation.operationID,
                reference: targetReference,
                message: "Link target does not exist"
            ))
            return
        }

        if shouldLink {
            target.addLink(sourceReference, with: operation)
        } else {
            target.removeLink(sourceReference, with: operation)
        }

        state.upsertEntity(target)
        state.markApplied(operation)
        EditSpaceInstrumentation.log(
            shouldLink ? "link.apply" : "unlink.apply",
            keywords: ["merge", "dependency"],
            "space=\(operation.spaceID.rawValue) op=\(operation.operationID.rawValue) target=\(targetReference.description) source=\(sourceReference.description)"
        )
    }

    private func addInvalidTargetConflict(_ operation: EditOperation,
                                          to state: inout SpaceState,
                                          message: String) {
        state.markSkipped(operation)
        state.addConflict(Conflict(
            kind: .invalidOperation,
            operationID: operation.operationID,
            reference: operation.targetReference,
            message: message
        ))
        EditSpaceInstrumentation.log(
            "apply.invalidOperation",
            keywords: ["merge", "compat"],
            "space=\(operation.spaceID.rawValue) op=\(operation.operationID.rawValue) action=\(operation.action.rawValue) entity=\(operation.entity.rawValue) problem=\(message)",
            level: .warning
        )
    }
}
