import Foundation

/// The resolved entity projection associated with an application mutation.
///
/// `operation` identifies the edit that caused an incremental mutation. It is
/// `nil` when a replica is replaying its current state into newly attached
/// bindings. `fields` and `arguments` always contain the complete winning
/// values for the entity, so applications never need to retain `SpaceState`.
public struct ReplicaMutationContext: Sendable {
    public let operation: EditOperation?
    public let reference: EntityReference
    public let sourceID: EntityID?
    public let fields: [String: Value]
    public let arguments: [String: Value]

    public init(
        operation: EditOperation?,
        reference: EntityReference,
        sourceID: EntityID?,
        fields: [String: Value],
        arguments: [String: Value]
    ) {
        self.operation = operation
        self.reference = reference
        self.sourceID = sourceID
        self.fields = fields
        self.arguments = arguments
    }

    public var operationID: OperationID? { operation?.operationID }
}

/// Application-owned construction and mutation functions used to project a
/// resolved EditSpace replica directly into an app model or renderer.
///
/// The merge engine retains only the bookkeeping required for convergence.
/// It does not require the application to consume or copy a ``SpaceState``.
public struct ReplicaBindings {
    public var create: (_ context: ReplicaMutationContext) throws -> Void
    public var update: (
        _ context: ReplicaMutationContext,
        _ changedFields: [String: Value],
        _ changedArguments: [String: Value]
    ) throws -> Void
    public var delete: (_ context: ReplicaMutationContext) throws -> Void
    public var setLink: (
        _ context: ReplicaMutationContext,
        _ linkedReference: EntityReference,
        _ isLinked: Bool
    ) throws -> Void

    public init(
        create: @escaping (_ context: ReplicaMutationContext) throws -> Void,
        update: @escaping (
            _ context: ReplicaMutationContext,
            _ changedFields: [String: Value],
            _ changedArguments: [String: Value]
        ) throws -> Void,
        delete: @escaping (_ context: ReplicaMutationContext) throws -> Void,
        setLink: @escaping (
            _ context: ReplicaMutationContext,
            _ linkedReference: EntityReference,
            _ isLinked: Bool
        ) throws -> Void
    ) {
        self.create = create
        self.update = update
        self.delete = delete
        self.setLink = setLink
    }

    /// Source-compatible convenience for applications that do not need the
    /// originating operation or complete resolved entity projection.
    public init(
        create: @escaping (
            _ reference: EntityReference,
            _ sourceID: EntityID?,
            _ fields: [String: Value],
            _ arguments: [String: Value]
        ) throws -> Void,
        update: @escaping (
            _ reference: EntityReference,
            _ changedFields: [String: Value],
            _ changedArguments: [String: Value]
        ) throws -> Void,
        delete: @escaping (_ reference: EntityReference) throws -> Void,
        setLink: @escaping (
            _ reference: EntityReference,
            _ linkedReference: EntityReference,
            _ isLinked: Bool
        ) throws -> Void
    ) {
        self.init(
            create: { context in
                try create(context.reference, context.sourceID, context.fields, context.arguments)
            },
            update: { context, changedFields, changedArguments in
                try update(context.reference, changedFields, changedArguments)
            },
            delete: { context in
                try delete(context.reference)
            },
            setLink: { context, linkedReference, isLinked in
                try setLink(context.reference, linkedReference, isLinked)
            }
        )
    }
}

public struct ReplicaApplicationFailure: Equatable, Sendable {
    public let operationID: OperationID?
    public let reference: EntityReference
    public let message: String

    public init(operationID: OperationID?, reference: EntityReference, message: String) {
        self.operationID = operationID
        self.reference = reference
        self.message = message
    }
}

public struct ReplicaApplicationReport: Equatable, Sendable {
    public let appliedOperationIDs: [OperationID]
    public let failures: [ReplicaApplicationFailure]

    public init(
        appliedOperationIDs: [OperationID] = [],
        failures: [ReplicaApplicationFailure] = []
    ) {
        self.appliedOperationIDs = appliedOperationIDs
        self.failures = failures
    }
}

/// Owns EditSpace's convergence bookkeeping while projecting resolved changes
/// directly into an application through attached construction and mutation functions.
public final class Replica {
    public let spaceID: SpaceID

    private let materializer: Materializer
    private var state: SpaceState
    private var bindings: ReplicaBindings

    public init(
        spaceID: SpaceID,
        compatibilityPolicy: CompatibilityPolicy = CompatibilityPolicy(),
        bindings: ReplicaBindings
    ) {
        self.spaceID = spaceID
        self.materializer = Materializer(compatibilityPolicy: compatibilityPolicy)
        self.state = SpaceState(spaceID: spaceID)
        self.bindings = bindings
    }

    /// Diagnostic merge results. Applications do not need these to update their model.
    public var conflicts: [Conflict] { state.conflicts }
    public var unappliedOperations: [EditOperation] { state.unappliedOperations }

    /// Resolves a batch and invokes the attached functions only for visible changes.
    @discardableResult
    public func apply(_ operations: [EditOperation]) -> ReplicaApplicationReport {
        materializer.apply(operations: operations, onto: &state, using: bindings)
    }

    /// Replaces the application projection and optionally reconstructs it immediately.
    @discardableResult
    public func attach(
        _ bindings: ReplicaBindings,
        replay: Bool = true
    ) -> ReplicaApplicationReport {
        self.bindings = bindings
        return replay ? materializer.replay(state, using: bindings) : ReplicaApplicationReport()
    }

    /// Reconstructs the attached application projection after attachment or failure.
    @discardableResult
    public func replay() -> ReplicaApplicationReport {
        materializer.replay(state, using: bindings)
    }
}

public extension Materializer {
    /// Resolves operations and immediately projects only winning changes through
    /// application-supplied functions. Binding failures do not roll back the
    /// canonical merge index; call ``replay(_:using:)`` to rebuild the projection.
    func apply(
        operations: [EditOperation],
        onto state: inout SpaceState,
        using bindings: ReplicaBindings
    ) -> ReplicaApplicationReport {
        var appliedOperationIDs: [OperationID] = []
        var failures: [ReplicaApplicationFailure] = []

        for operation in Self.orderedOperations(operations) {
            let before = state.visibleEntities
            materialize(operations: [operation], onto: &state)
            let after = state.visibleEntities

            guard state.appliedOperationIDs.contains(operation.operationID) else {
                continue
            }
            appliedOperationIDs.append(operation.operationID)
            emitChanges(
                from: before,
                to: after,
                operation: operation,
                using: bindings,
                failures: &failures
            )
        }

        return ReplicaApplicationReport(
            appliedOperationIDs: appliedOperationIDs,
            failures: failures
        )
    }

    /// Reconstructs an application projection from the current resolved replica.
    /// Call this after attaching new bindings or recovering from a binding failure.
    func replay(
        _ state: SpaceState,
        using bindings: ReplicaBindings
    ) -> ReplicaApplicationReport {
        var failures: [ReplicaApplicationFailure] = []
        for reference in state.visibleEntities.keys.sorted() {
            guard let entity = state.visibleEntities[reference] else { continue }
            let context = ReplicaMutationContext(
                operation: nil,
                reference: reference,
                sourceID: entity.sourceID,
                fields: entity.fields,
                arguments: entity.arguments
            )
            perform(reference: reference, operationID: nil, failures: &failures) {
                try bindings.create(context)
            }
            for linkedReference in entity.links.sorted() {
                perform(reference: reference, operationID: nil, failures: &failures) {
                    try bindings.setLink(context, linkedReference, true)
                }
            }
        }
        return ReplicaApplicationReport(failures: failures)
    }

    private func emitChanges(
        from before: [EntityReference: EntityState],
        to after: [EntityReference: EntityState],
        operation: EditOperation,
        using bindings: ReplicaBindings,
        failures: inout [ReplicaApplicationFailure]
    ) {
        let references = Set(before.keys).union(after.keys).sorted()
        for reference in references {
            switch (before[reference], after[reference]) {
            case (nil, let entity?):
                let context = mutationContext(operation: operation, entity: entity)
                perform(reference: reference, operationID: operation.operationID, failures: &failures) {
                    try bindings.create(context)
                }
                for linkedReference in entity.links.sorted() {
                    perform(reference: reference, operationID: operation.operationID, failures: &failures) {
                        try bindings.setLink(context, linkedReference, true)
                    }
                }

            case (let previous?, nil):
                let context = mutationContext(operation: operation, entity: previous)
                perform(reference: reference, operationID: operation.operationID, failures: &failures) {
                    try bindings.delete(context)
                }

            case (let previous?, let current?):
                let context = mutationContext(operation: operation, entity: current)
                let changedFields = current.fields.filter { previous.fields[$0.key] != $0.value }
                let changedArguments = current.arguments.filter {
                    previous.arguments[$0.key] != $0.value
                }
                if !changedFields.isEmpty || !changedArguments.isEmpty {
                    perform(reference: reference, operationID: operation.operationID, failures: &failures) {
                        try bindings.update(context, changedFields, changedArguments)
                    }
                }

                for linkedReference in current.links.subtracting(previous.links).sorted() {
                    perform(reference: reference, operationID: operation.operationID, failures: &failures) {
                        try bindings.setLink(context, linkedReference, true)
                    }
                }
                for linkedReference in previous.links.subtracting(current.links).sorted() {
                    perform(reference: reference, operationID: operation.operationID, failures: &failures) {
                        try bindings.setLink(context, linkedReference, false)
                    }
                }

            case (nil, nil):
                break
            }
        }
    }

    private func mutationContext(
        operation: EditOperation,
        entity: EntityState
    ) -> ReplicaMutationContext {
        ReplicaMutationContext(
            operation: operation,
            reference: entity.reference,
            sourceID: entity.sourceID,
            fields: entity.fields,
            arguments: entity.arguments
        )
    }

    private func perform(
        reference: EntityReference,
        operationID: OperationID?,
        failures: inout [ReplicaApplicationFailure],
        action: () throws -> Void
    ) {
        do {
            try action()
        } catch {
            failures.append(
                ReplicaApplicationFailure(
                    operationID: operationID,
                    reference: reference,
                    message: String(describing: error)
                )
            )
        }
    }
}
