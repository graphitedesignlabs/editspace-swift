import Foundation

/// Describes the software that authored an operation without affecting merge semantics.
public struct Producer: Codable, Equatable, Sendable {
    public let app: String
    public let appVersion: String?
    public let library: String
    public let libraryVersion: String?

    public init(app: String, appVersion: String? = nil, library: String = "EditSpace", libraryVersion: String? = nil) {
        self.app = app
        self.appVersion = appVersion
        self.library = library
        self.libraryVersion = libraryVersion
    }
}

/// An immutable, JSON-serializable edit in an EditSpace document.
public struct EditOperation: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public var id: OperationID { operationID }
    public let schemaVersion: Int
    public let documentID: DocumentID
    public let operationID: OperationID
    public let actorID: ActorID
    public let sequence: Int64
    public let dependencies: [OperationID]
    public let action: OperationAction
    public let entity: EntityKind
    public let targetID: EntityID?
    public let sourceID: EntityID?
    public let fields: [String: Value]
    public let arguments: [String: Value]
    public let requiredFeatures: [Feature]
    public let producer: Producer?
    public let createdAt: Date?

    public init(
        schemaVersion: Int = EditOperation.currentSchemaVersion,
        documentID: DocumentID,
        operationID: OperationID? = nil,
        actorID: ActorID,
        sequence: Int64,
        dependencies: [OperationID] = [],
        action: OperationAction,
        entity: EntityKind,
        targetID: EntityID? = nil,
        sourceID: EntityID? = nil,
        fields: [String: Value] = [:],
        arguments: [String: Value] = [:],
        requiredFeatures: [Feature] = [],
        producer: Producer? = nil,
        createdAt: Date? = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.documentID = documentID
        self.operationID = operationID ?? OperationID(actorID: actorID, sequence: sequence)
        self.actorID = actorID
        self.sequence = sequence
        self.dependencies = dependencies
        self.action = action
        self.entity = entity
        self.targetID = targetID
        self.sourceID = sourceID
        self.fields = fields
        self.arguments = arguments
        self.requiredFeatures = requiredFeatures
        self.producer = producer
        self.createdAt = createdAt
    }

    public var stamp: OperationStamp {
        OperationStamp(sequence: sequence, actorID: actorID, operationID: operationID)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "v", documentID = "doc", operationID = "op", actorID = "actor"
        case sequence = "seq", dependencies = "deps", action, entity, targetID = "target"
        case sourceID = "source", fields, arguments = "args", requiredFeatures = "features"
        case producer, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        documentID = try container.decode(DocumentID.self, forKey: .documentID)
        operationID = try container.decode(OperationID.self, forKey: .operationID)
        actorID = try container.decode(ActorID.self, forKey: .actorID)
        sequence = try container.decode(Int64.self, forKey: .sequence)
        dependencies = try container.decodeIfPresent([OperationID].self, forKey: .dependencies) ?? []
        action = try container.decode(OperationAction.self, forKey: .action)
        entity = try container.decode(EntityKind.self, forKey: .entity)
        targetID = try container.decodeIfPresent(EntityID.self, forKey: .targetID)
        sourceID = try container.decodeIfPresent(EntityID.self, forKey: .sourceID)
        fields = try container.decodeIfPresent([String: Value].self, forKey: .fields) ?? [:]
        arguments = try container.decodeIfPresent([String: Value].self, forKey: .arguments) ?? [:]
        requiredFeatures = try container.decodeIfPresent([Feature].self, forKey: .requiredFeatures) ?? []
        producer = try container.decodeIfPresent(Producer.self, forKey: .producer)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

/// A transport-neutral batch of immutable operations.
public struct OperationEnvelope: Codable, Equatable, Sendable {
    public static let kind = "editspace.operations"
    public static let currentSchemaVersion = 1

    public let kind: String
    public let schemaVersion: Int
    public let documentID: DocumentID
    public let operations: [EditOperation]

    public init(
        kind: String = OperationEnvelope.kind,
        schemaVersion: Int = OperationEnvelope.currentSchemaVersion,
        documentID: DocumentID,
        operations: [EditOperation]
    ) {
        self.kind = kind
        self.schemaVersion = schemaVersion
        self.documentID = documentID
        self.operations = operations
    }

    private enum CodingKeys: String, CodingKey {
        case kind, schemaVersion = "v", documentID = "doc", operations = "ops"
    }
}

public enum CodecError: Error, Equatable, Sendable {
    case wrongMessageKind(String)
    case unsupportedEnvelopeSchema(Int)
    case documentMismatch(expected: DocumentID, actual: DocumentID)
}

/// Canonical JSON codec. Object key order is stable to support hashing and fixtures.
public enum OperationCodec {
    public static func encode(_ envelope: OperationEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    public static func decode(_ data: Data, expectedDocumentID: DocumentID? = nil) throws -> OperationEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(OperationEnvelope.self, from: data)
        guard envelope.kind == OperationEnvelope.kind else { throw CodecError.wrongMessageKind(envelope.kind) }
        guard envelope.schemaVersion <= OperationEnvelope.currentSchemaVersion else {
            throw CodecError.unsupportedEnvelopeSchema(envelope.schemaVersion)
        }
        if let expectedDocumentID, expectedDocumentID != envelope.documentID {
            throw CodecError.documentMismatch(expected: expectedDocumentID, actual: envelope.documentID)
        }
        return envelope
    }
}
