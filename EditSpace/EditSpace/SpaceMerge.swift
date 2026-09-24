import Foundation

/// An immutable, idempotent declaration that two EditSpace identifiers refer
/// to one logical collaboration space.
public struct SpaceMergeDeclaration: Codable, Hashable, Sendable {
    public let firstSpaceID: SpaceID
    public let secondSpaceID: SpaceID

    public init(_ lhs: SpaceID, _ rhs: SpaceID) {
        if lhs <= rhs {
            firstSpaceID = lhs
            secondSpaceID = rhs
        } else {
            firstSpaceID = rhs
            secondSpaceID = lhs
        }
    }

    private enum CodingKeys: String, CodingKey {
        case firstSpaceID = "first"
        case secondSpaceID = "second"
    }
}

/// A transport-neutral collection of merge declarations. Replaying envelopes
/// in any order produces the same alias components.
public struct SpaceMergeEnvelope: Codable, Equatable, Sendable {
    public static let kind = "editspace.space-merges"
    public static let currentSchemaVersion = 1

    public let kind: String
    public let schemaVersion: Int
    public let declarations: [SpaceMergeDeclaration]

    public init(
        kind: String = SpaceMergeEnvelope.kind,
        schemaVersion: Int = SpaceMergeEnvelope.currentSchemaVersion,
        declarations: [SpaceMergeDeclaration]
    ) {
        self.kind = kind
        self.schemaVersion = schemaVersion
        self.declarations = declarations
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case schemaVersion = "v"
        case declarations
    }
}

public enum SpaceMergeCodecError: Error, Equatable, Sendable {
    case wrongMessageKind(String)
    case unsupportedEnvelopeSchema(Int)
}

public enum SpaceMergeCodec {
    public static func encode(_ envelope: SpaceMergeEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    public static func decode(_ data: Data) throws -> SpaceMergeEnvelope {
        let envelope = try JSONDecoder().decode(SpaceMergeEnvelope.self, from: data)
        guard envelope.kind == SpaceMergeEnvelope.kind else {
            throw SpaceMergeCodecError.wrongMessageKind(envelope.kind)
        }
        guard envelope.schemaVersion <= SpaceMergeEnvelope.currentSchemaVersion else {
            throw SpaceMergeCodecError.unsupportedEnvelopeSchema(envelope.schemaVersion)
        }
        return envelope
    }
}

/// A convergent union of EditSpace identifiers. The lexicographically smallest
/// identifier in a connected component is its canonical representative.
/// Applying declarations is associative, commutative, and idempotent.
public struct SpaceMergeRegistry: Equatable, Sendable {
    public private(set) var declarations: Set<SpaceMergeDeclaration>

    public init(declarations: Set<SpaceMergeDeclaration> = []) {
        self.declarations = declarations
    }

    @discardableResult
    public mutating func merge(_ lhs: SpaceID, _ rhs: SpaceID) -> SpaceMergeDeclaration {
        let declaration = SpaceMergeDeclaration(lhs, rhs)
        declarations.insert(declaration)
        return declaration
    }

    public mutating func apply(_ declaration: SpaceMergeDeclaration) {
        declarations.insert(declaration)
    }

    public mutating func apply<S: Sequence>(_ incoming: S) where S.Element == SpaceMergeDeclaration {
        declarations.formUnion(incoming)
    }

    public func canonicalSpaceID(for spaceID: SpaceID) -> SpaceID {
        equivalentSpaceIDs(to: spaceID).min() ?? spaceID
    }

    public func equivalentSpaceIDs(to spaceID: SpaceID) -> Set<SpaceID> {
        var component: Set<SpaceID> = [spaceID]
        var changed = true
        while changed {
            changed = false
            for declaration in declarations {
                let touchesComponent = component.contains(declaration.firstSpaceID)
                    || component.contains(declaration.secondSpaceID)
                guard touchesComponent else { continue }
                let oldCount = component.count
                component.insert(declaration.firstSpaceID)
                component.insert(declaration.secondSpaceID)
                changed = changed || component.count != oldCount
            }
        }
        return component
    }

    public func areEquivalent(_ lhs: SpaceID, _ rhs: SpaceID) -> Bool {
        canonicalSpaceID(for: lhs) == canonicalSpaceID(for: rhs)
    }
}

public extension EditOperation {
    /// Returns the same immutable edit addressed to a resolved space. Operation
    /// identity, causal dependencies, author, and Lamport stamp are preserved.
    func resolvingSpace(to spaceID: SpaceID) -> EditOperation {
        guard self.spaceID != spaceID else { return self }
        return EditOperation(
            schemaVersion: schemaVersion,
            spaceID: spaceID,
            operationID: operationID,
            actorID: actorID,
            sequence: sequence,
            dependencies: dependencies,
            action: action,
            entity: entity,
            targetID: targetID,
            sourceID: sourceID,
            fields: fields,
            arguments: arguments,
            requiredFeatures: requiredFeatures,
            producer: producer,
            createdAt: createdAt
        )
    }
}
