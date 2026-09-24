import Foundation

public enum CompatibilityProblemKind: String, Codable, Sendable {
    case unsupportedSchema
    case unsupportedAction
    case unsupportedEntity
    case unsupportedFeature
    case spaceMismatch
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
        supportedActions: Set<OperationAction> = CompatibilityPolicy.defaultSupportedActions,
        supportedEntities: Set<EntityKind> = CompatibilityPolicy.defaultSupportedEntities,
        supportedFeatures: Set<Feature> = CompatibilityPolicy.defaultSupportedFeatures
    ) {
        self.supportedSchemaVersion = supportedSchemaVersion
        self.supportedActions = supportedActions
        self.supportedEntities = supportedEntities
        self.supportedFeatures = supportedFeatures
    }

    public static let defaultSupportedActions: Set<OperationAction> = [
        .create, .update, .delete, .duplicate, .link, .unlink
    ]

    public static let defaultSupportedEntities: Set<EntityKind> = [
        .space, .document, .object, .mesh, .vertex, .face, .modifier,
        .material, .asset, .constraint, .parameter, .dependency, .legacySnapshot
    ]

    public static let defaultSupportedFeatures: Set<Feature> = [
        .coreV1, .scene3DV1, .meshV1, .modifiersV1, .pbrMaterialV1,
        .crudV1, .duplicateV1, .linkedDuplicateV1, .dependencyGraphV1,
        .presenceV1, .legacySnapshotV1
    ]

    public func problems(for operation: EditOperation, expectedSpaceID: SpaceID? = nil) -> [CompatibilityProblem] {
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

        if let expectedSpaceID, expectedSpaceID != operation.spaceID {
            problem(.spaceMismatch, "Space \(operation.spaceID) does not match \(expectedSpaceID)")
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
        if operation.entity != .space && operation.entity != .document && operation.targetID == nil && operation.action != .link && operation.action != .unlink {
            problem(.invalidOperation, "A non-space operation requires target")
        }
        if operation.action == .duplicate && operation.sourceID == nil {
            problem(.invalidOperation, "Duplicate requires source")
        }
        for message in SceneFieldValidator.errors(for: operation) {
            problem(.invalidOperation, message)
        }
        return result
    }
}

/// Validates the standardized EditSpace v1 3D field shapes that JSON typing alone cannot express.
public enum SceneFieldValidator {
    public static func errors(for operation: EditOperation) -> [String] {
        let fields = operation.fields
        var errors: [String] = []
        func requireVector(_ key: String, count: Int) {
            guard let value = fields[key] else { return }
            if !isNumberArray(value, count: count) { errors.append("Field \(key) must contain exactly \(count) finite numbers") }
        }
        func requireUnitInterval(_ key: String) {
            guard let number = fields[key]?.numberValue else {
                if fields[key] != nil { errors.append("Field \(key) must be a number") }
                return
            }
            if !number.isFinite || !(0...1).contains(number) { errors.append("Field \(key) must be in 0...1") }
        }

        switch operation.entity {
        case .object:
            requireVector(SceneField.transform.rawValue, count: 16)
            requireVector(SceneField.pivot.rawValue, count: 16)
            requireVector(SceneField.position.rawValue, count: 3)
            requireVector(SceneField.orientation.rawValue, count: 4)
            requireVector(SceneField.quaternion.rawValue, count: 4)
            requireVector(SceneField.scale.rawValue, count: 3)
            requireUnitInterval(SceneField.opacity.rawValue)
        case .mesh:
            errors.append(contentsOf: meshErrors(fields))
        case .vertex:
            requireVector(SceneField.position.rawValue, count: 3)
        case .material:
            for key in [SceneField.baseColor.rawValue, "emissiveColor"] {
                guard let value = fields[key] else { continue }
                if !isColor(value) { errors.append("Field \(key) must be an sRGB RGBA color") }
            }
            requireUnitInterval(SceneField.metallic.rawValue)
            requireUnitInterval(SceneField.roughness.rawValue)
            requireUnitInterval(SceneField.opacity.rawValue)
        default:
            break
        }
        return errors
    }

    private static func meshErrors(_ fields: [String: Value]) -> [String] {
        guard let positionValues = fields[SceneField.positions.rawValue]?.arrayValue else {
            return fields[SceneField.positions.rawValue] == nil ? [] : ["Mesh positions must be an array of vec3 values"]
        }
        guard positionValues.allSatisfy({ isNumberArray($0, count: 3) }) else {
            return ["Mesh positions must be an array of vec3 values"]
        }
        var errors: [String] = []
        for key in [SceneField.normals.rawValue] {
            guard let values = fields[key]?.arrayValue else {
                if fields[key] != nil { errors.append("Mesh \(key) must be an array") }
                continue
            }
            if values.count != positionValues.count || !values.allSatisfy({ isNumberArray($0, count: 3) }) {
                errors.append("Mesh \(key) must contain one vec3 per position")
            }
        }
        if let faces = fields[SceneField.faces.rawValue]?.arrayValue {
            for face in faces {
                guard let indices = face.arrayValue, indices.count >= 3 else {
                    errors.append("Every mesh face must contain at least three indices")
                    continue
                }
                if indices.contains(where: { value in
                    guard let number = value.numberValue else { return true }
                    return !number.isFinite || number.rounded() != number || number < 0 || number >= Double(positionValues.count)
                }) {
                    errors.append("Mesh face index is outside positions")
                }
            }
        } else if fields[SceneField.faces.rawValue] != nil {
            errors.append("Mesh faces must be an array")
        }
        return errors
    }

    private static func isNumberArray(_ value: Value, count: Int) -> Bool {
        guard let values = value.arrayValue, values.count == count else { return false }
        return values.allSatisfy { $0.numberValue?.isFinite == true }
    }

    private static func isColor(_ value: Value) -> Bool {
        guard let values = value.arrayValue, values.count == 4 else { return false }
        return values.allSatisfy { component in
            guard let number = component.numberValue else { return false }
            return number.isFinite && (0...1).contains(number)
        }
    }
}
