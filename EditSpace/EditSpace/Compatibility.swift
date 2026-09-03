import Foundation

public enum CompatibilityProblemKind: String, Codable, Sendable {
    case unsupportedSchema
    case unsupportedAction
    case unsupportedEntity
    case unsupportedFeature
    case documentMismatch
    case invalidOperation
    case operationIDCollision
}

/// A structured reason an operation could not be interpreted safely.
public struct CompatibilityProblem: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    public let kind: CompatibilityProblemKind
    public let operationID: OperationID?
    public let requiredSchema: Int?
    public let requiredFeatures: [Feature]
    public let producer: Producer?
    public let message: String

    public init(
        kind: CompatibilityProblemKind,
        operationID: OperationID? = nil,
        requiredSchema: Int? = nil,
        requiredFeatures: [Feature] = [],
        producer: Producer? = nil,
        message: String
    ) {
        self.kind = kind
        self.operationID = operationID
        self.requiredSchema = requiredSchema
        self.requiredFeatures = requiredFeatures
        self.producer = producer
        self.message = message
    }

    public var description: String { "\(kind.rawValue): \(message)" }
}

/// Declares exactly which extensible protocol tokens an endpoint can materialize.
public struct CompatibilityPolicy: Sendable {
    public let supportedSchemaVersion: Int
    public let supportedActions: Set<OperationAction>
    public let supportedEntities: Set<EntityKind>
    public let supportedFeatures: Set<Feature>

    public init(
        supportedSchemaVersion: Int = EditOperation.currentSchemaVersion,
        supportedActions: Set<OperationAction> = [.create, .update, .delete, .duplicate, .link, .unlink],
        supportedEntities: Set<EntityKind> = [.document, .object, .modifier, .material, .asset, .constraint, .parameter, .dependency, .legacySnapshot],
        supportedFeatures: Set<Feature> = [.coreV1, .crudV1, .duplicateV1, .linkedDuplicateV1, .dependencyGraphV1, .presenceV1]
    ) {
        self.supportedSchemaVersion = supportedSchemaVersion
        self.supportedActions = supportedActions
        self.supportedEntities = supportedEntities
        self.supportedFeatures = supportedFeatures
    }

    public func problems(for operation: EditOperation, expectedDocumentID: DocumentID? = nil) -> [CompatibilityProblem] {
        var result: [CompatibilityProblem] = []
        func problem(_ kind: CompatibilityProblemKind, _ message: String, features: [Feature] = []) {
            result.append(CompatibilityProblem(
                kind: kind,
                operationID: operation.operationID,
                requiredSchema: kind == .unsupportedSchema ? operation.schemaVersion : nil,
                requiredFeatures: features,
                producer: operation.producer,
                message: message
            ))
        }

        if let expectedDocumentID, expectedDocumentID != operation.documentID {
            problem(.documentMismatch, "Document \(operation.documentID) does not match \(expectedDocumentID)")
        }
        if operation.schemaVersion > supportedSchemaVersion {
            problem(.unsupportedSchema, "Schema \(operation.schemaVersion) is newer than \(supportedSchemaVersion)")
        }
        if !supportedActions.contains(operation.action) {
            problem(.unsupportedAction, "Unsupported action \(operation.action)")
        }
        if !supportedEntities.contains(operation.entity) {
            problem(.unsupportedEntity, "Unsupported entity \(operation.entity)")
        }
        let features = operation.requiredFeatures.filter { !supportedFeatures.contains($0) }
        if !features.isEmpty { problem(.unsupportedFeature, "Unsupported features", features: features) }
        if operation.entity != .document && operation.targetID == nil && operation.action != .link && operation.action != .unlink {
            problem(.invalidOperation, "A non-document operation requires target")
        }
        if operation.action == .duplicate && operation.sourceID == nil {
            problem(.invalidOperation, "Duplicate requires source")
        }
        return result
    }
}
