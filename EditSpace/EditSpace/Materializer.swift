import Foundation

/// Deterministically reduces an operation log into a renderable shared 3D space.
public enum Materializer {
    public static func materialize(_ log: OperationLog) -> SpaceState {
        var state = SpaceState(spaceID: log.spaceID)
        for operation in log.operations { apply(operation, to: &state) }
        return state
    }

    private static func apply(_ operation: EditOperation, to state: inout SpaceState) {
        guard let targetID = operation.targetID else {
            state.deferOperation(operation)
            return
        }
        let reference = EntityReference(kind: operation.entity, id: targetID)

        switch operation.action {
        case .create:
            if var entity = state.entities[reference] {
                entity.apply(fields: operation.fields, arguments: operation.arguments, stamp: operation.stamp)
                state.set(entity)
            } else {
                state.set(EntityState(reference: reference, sourceID: operation.sourceID, fields: operation.fields, arguments: operation.arguments, createdBy: operation.operationID, stamp: operation.stamp))
            }
        case .update:
            guard var entity = state.entities[reference], !entity.isDeleted else {
                state.deferOperation(operation)
                return
            }
            entity.apply(fields: operation.fields, arguments: operation.arguments, stamp: operation.stamp)
            state.set(entity)
        case .delete:
            guard var entity = state.entities[reference] else {
                state.deferOperation(operation)
                return
            }
            entity.delete(stamp: operation.stamp)
            state.set(entity)
        case .duplicate:
            let sourceReference = EntityReference(kind: operation.entity, id: operation.sourceID!)
            guard let source = state.entities[sourceReference], !source.isDeleted else {
                state.deferOperation(operation)
                return
            }
            var fields = source.fields
            fields.merge(operation.fields) { _, new in new }
            state.set(EntityState(reference: reference, sourceID: operation.sourceID, fields: fields, arguments: operation.arguments, createdBy: operation.operationID, stamp: operation.stamp))
        case .link, .unlink:
            guard let sourceID = operation.sourceID else {
                state.deferOperation(operation)
                return
            }
            let sourceReference = EntityReference(kind: operation.entity, id: sourceID)
            guard var source = state.entities[sourceReference] else {
                state.deferOperation(operation)
                return
            }
            if operation.action == .link { source.link(reference) } else { source.unlink(reference) }
            state.set(source)
        default:
            state.deferOperation(operation)
        }
    }
}
