import Foundation

/// Standard lifecycle states for a `generative` modifier.
public enum GenerativeModifierStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case running
    case done
    case failed
}

/// Optional requested local-space bounds for generated geometry, in meters.
public struct GenerativeBounds: Equatable, Sendable {
    public let minimum: [Double]
    public let maximum: [Double]

    public init?(minimum: [Double], maximum: [Double]) {
        guard minimum.count == 3,
              maximum.count == 3,
              minimum.allSatisfy(\.isFinite),
              maximum.allSatisfy(\.isFinite),
              zip(minimum, maximum).allSatisfy({ $0 <= $1 }) else {
            return nil
        }
        self.minimum = minimum
        self.maximum = maximum
    }

    public var value: Value {
        .object([
            "min": .vector(minimum),
            "max": .vector(maximum)
        ])
    }
}

/// Creates standardized field patches for the generative modifier lifecycle.
public enum GenerativeModifierFields {
    /// Fields for a new `modifier` create. Returns nil for an empty prompt.
    public static func request(
        objectID: EntityID,
        prompt: String,
        bounds: GenerativeBounds? = nil,
        enabled: Bool = true,
        order: Int64 = 0
    ) -> [String: Value]? {
        guard !prompt.isEmpty, order >= 0 else { return nil }
        var fields: [String: Value] = [
            SceneField.objectID.rawValue: .string(objectID.rawValue),
            SceneField.modifierType.rawValue: .string(ModifierType.generative.rawValue),
            SceneField.enabled.rawValue: .bool(enabled),
            SceneField.order.rawValue: .number(Double(order)),
            SceneField.prompt.rawValue: .string(prompt),
            SceneField.units.rawValue: .string("meters"),
            SceneField.status.rawValue: .string(GenerativeModifierStatus.pending.rawValue)
        ]
        if let bounds {
            fields[SceneField.bounds.rawValue] = bounds.value
        }
        return fields
    }

    /// A complete claim patch. `claimID` must be the ID of the operation carrying this patch.
    public static func claim(actorID: ActorID, claimID: OperationID) -> [String: Value] {
        [
            SceneField.status.rawValue: .string(GenerativeModifierStatus.running.rawValue),
            SceneField.claimant.rawValue: .string(actorID.rawValue),
            SceneField.claimID.rawValue: .string(claimID.rawValue),
            SceneField.responseToClaimID.rawValue: .null,
            SceneField.resultMeshID.rawValue: .null,
            SceneField.error.rawValue: .null
        ]
    }

    /// A successful terminal response. The carrying operation must depend on the claim.
    public static func success(claimID: OperationID, resultMeshID: EntityID) -> [String: Value] {
        [
            SceneField.status.rawValue: .string(GenerativeModifierStatus.done.rawValue),
            SceneField.responseToClaimID.rawValue: .string(claimID.rawValue),
            SceneField.resultMeshID.rawValue: .string(resultMeshID.rawValue),
            SceneField.error.rawValue: .null
        ]
    }

    /// A failed terminal response. Returns nil for an empty diagnostic message.
    public static func failure(claimID: OperationID, error: String) -> [String: Value]? {
        guard !error.isEmpty else { return nil }
        return [
            SceneField.status.rawValue: .string(GenerativeModifierStatus.failed.rawValue),
            SceneField.responseToClaimID.rawValue: .string(claimID.rawValue),
            SceneField.resultMeshID.rawValue: .null,
            SceneField.error.rawValue: .string(error)
        ]
    }

    /// Clears claim and response bookkeeping before a retry or semantic-input change.
    public static var reset: [String: Value] {
        [
            SceneField.status.rawValue: .string(GenerativeModifierStatus.pending.rawValue),
            SceneField.claimant.rawValue: .null,
            SceneField.claimID.rawValue: .null,
            SceneField.responseToClaimID.rawValue: .null,
            SceneField.resultMeshID.rawValue: .null,
            SceneField.error.rawValue: .null
        ]
    }
}
