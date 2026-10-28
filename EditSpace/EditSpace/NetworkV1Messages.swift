import Foundation

public struct NetworkPeerID: RawRepresentable, Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init() {
        rawValue = UUID().uuidString.lowercased()
    }

    public var description: String { rawValue }

    public var isCanonical: Bool {
        guard let uuid = UUID(uuidString: rawValue) else { return false }
        return uuid.uuidString.lowercased() == rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public extension NetworkPeerID {
    /// Loads a stable v1 identity or creates and stores one on first use.
    static func loadOrCreate(
        in defaults: UserDefaults = .standard,
        key: String = "org.editspace.network.v1.peer-id"
    ) -> NetworkPeerID {
        if let value = defaults.string(forKey: key) {
            let peerID = NetworkPeerID(rawValue: value)
            if peerID.isCanonical { return peerID }
        }
        let peerID = NetworkPeerID()
        defaults.set(peerID.rawValue, forKey: key)
        return peerID
    }
}

public struct NetworkV1ConnectionCandidate: Equatable, Sendable {
    public let initiatorPeerID: NetworkPeerID
    public let initiatorPort: UInt16

    public init(initiatorPeerID: NetworkPeerID, initiatorPort: UInt16) {
        self.initiatorPeerID = initiatorPeerID
        self.initiatorPort = initiatorPort
    }
}

public enum NetworkV1ConnectionSelection {
    public static func preferred(
        between lhs: NetworkV1ConnectionCandidate,
        and rhs: NetworkV1ConnectionCandidate
    ) -> NetworkV1ConnectionCandidate {
        if lhs.initiatorPeerID != rhs.initiatorPeerID {
            return lhs.initiatorPeerID < rhs.initiatorPeerID ? lhs : rhs
        }
        return lhs.initiatorPort <= rhs.initiatorPort ? lhs : rhs
    }
}

public struct NetworkV1SequenceRange: Codable, Equatable, Hashable, Sendable {
    public let first: Int64
    public let last: Int64

    public init(first: Int64, last: Int64) {
        self.first = first
        self.last = last
    }

    public func contains(_ sequence: Int64) -> Bool {
        first...last ~= sequence
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        first = try container.decode(Int64.self)
        last = try container.decode(Int64.self)
        guard container.isAtEnd else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "A sequence range has exactly two values")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(first)
        try container.encode(last)
    }
}

public struct NetworkV1ActorRanges: Codable, Equatable, Sendable {
    public let actor: ActorID
    public let ranges: [NetworkV1SequenceRange]

    public init(actor: ActorID, ranges: [NetworkV1SequenceRange]) {
        self.actor = actor
        self.ranges = ranges
    }
}

public struct NetworkV1Hello: Codable, Equatable, Sendable {
    public static let kind = "editspace.network.hello"

    public let kind: String
    public let schemaVersion: Int
    public let networkVersions: [Int]
    public let operationVersions: [Int]
    public let peerID: NetworkPeerID
    /// Identifies this particular app process while `peerID` remains stable across launches.
    public let instanceID: String?
    public let capabilities: [String]
    public let spaces: [SpaceID]

    public init(
        networkVersions: [Int] = [1],
        operationVersions: [Int] = [1],
        peerID: NetworkPeerID,
        instanceID: String? = nil,
        capabilities: [String] = ["application-messages", "dns-sd", "history-ranges", "tcp"],
        spaces: [SpaceID]
    ) {
        kind = Self.kind
        schemaVersion = 1
        self.networkVersions = networkVersions
        self.operationVersions = operationVersions
        self.peerID = peerID
        self.instanceID = instanceID
        self.capabilities = capabilities
        self.spaces = spaces
    }

    private enum CodingKeys: String, CodingKey {
        case kind, schemaVersion = "v", networkVersions, operationVersions, peerID, instanceID, capabilities, spaces
    }
}

public struct NetworkV1SpaceSelection: Codable, Equatable, Sendable {
    public static let kind = "editspace.network.space-selection"

    public let kind: String
    public let schemaVersion: Int
    public let spaces: [SpaceID]

    public init(spaces: [SpaceID]) {
        kind = Self.kind
        schemaVersion = 1
        self.spaces = spaces
    }

    private enum CodingKeys: String, CodingKey {
        case kind, schemaVersion = "v", spaces
    }
}

public struct NetworkV1HistorySummary: Codable, Equatable, Sendable {
    public static let kind = "editspace.network.history-summary"

    public let kind: String
    public let schemaVersion: Int
    public let summaryID: String
    public let spaceID: SpaceID
    public let actors: [NetworkV1ActorRanges]
    public let spaceMerges: SpaceMergeEnvelope

    public init(
        summaryID: String,
        spaceID: SpaceID,
        actors: [NetworkV1ActorRanges],
        spaceMerges: SpaceMergeEnvelope
    ) {
        kind = Self.kind
        schemaVersion = 1
        self.summaryID = summaryID
        self.spaceID = spaceID
        self.actors = actors
        self.spaceMerges = spaceMerges
    }

    private enum CodingKeys: String, CodingKey {
        case kind, schemaVersion = "v", summaryID, spaceID = "doc", actors, spaceMerges
    }
}

public struct NetworkV1OperationRequest: Codable, Equatable, Sendable {
    public static let kind = "editspace.network.request-operations"

    public let kind: String
    public let schemaVersion: Int
    public let requestID: String
    public let summaryID: String
    public let spaceID: SpaceID
    public let actors: [NetworkV1ActorRanges]

    public init(requestID: String, summaryID: String, spaceID: SpaceID, actors: [NetworkV1ActorRanges]) {
        kind = Self.kind
        schemaVersion = 1
        self.requestID = requestID
        self.summaryID = summaryID
        self.spaceID = spaceID
        self.actors = actors
    }

    private enum CodingKeys: String, CodingKey {
        case kind, schemaVersion = "v", requestID, summaryID, spaceID = "doc", actors
    }
}

public struct NetworkV1OperationBatch: Codable, Equatable, Sendable {
    public static let kind = "editspace.network.operation-batch"

    public let kind: String
    public let schemaVersion: Int
    public let requestID: String?
    public let final: Bool
    public let spaceID: SpaceID
    public let envelopes: [OperationEnvelope]

    public init(requestID: String?, final: Bool, spaceID: SpaceID, envelopes: [OperationEnvelope]) {
        kind = Self.kind
        schemaVersion = 1
        self.requestID = requestID
        self.final = final
        self.spaceID = spaceID
        self.envelopes = envelopes
    }

    private enum CodingKeys: String, CodingKey {
        case kind, schemaVersion = "v", requestID, final, spaceID = "doc", envelopes
    }
}

public struct NetworkV1SyncComplete: Codable, Equatable, Sendable {
    public static let kind = "editspace.network.sync-complete"

    public let kind: String
    public let schemaVersion: Int
    public let summaryID: String
    public let spaceID: SpaceID

    public init(summaryID: String, spaceID: SpaceID) {
        kind = Self.kind
        schemaVersion = 1
        self.summaryID = summaryID
        self.spaceID = spaceID
    }

    private enum CodingKeys: String, CodingKey {
        case kind, schemaVersion = "v", summaryID, spaceID = "doc"
    }
}

/// Ephemeral application data carried beside durable EditSpace operations.
/// These messages are never retained or replayed as document history.
public struct NetworkV1ApplicationMessage: Codable, Equatable, Sendable {
    public static let kind = "editspace.network.application"

    public let kind: String
    public let schemaVersion: Int
    public let messageID: String
    public let channel: String
    public let payload: Data

    public init(
        messageID: String = UUID().uuidString.lowercased(),
        channel: String,
        payload: Data
    ) {
        kind = Self.kind
        schemaVersion = 1
        self.messageID = messageID
        self.channel = channel
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case kind, schemaVersion = "v", messageID, channel, payload
    }
}

public struct NetworkV1ErrorMessage: Codable, Equatable, Sendable {
    public static let kind = "editspace.network.error"

    public let kind: String
    public let schemaVersion: Int
    public let code: NetworkV1ErrorCode
    public let fatal: Bool
    public let message: String?
    public let spaceID: SpaceID?
    public let requestID: String?

    public init(
        code: NetworkV1ErrorCode,
        message: String? = nil,
        spaceID: SpaceID? = nil,
        requestID: String? = nil
    ) {
        kind = Self.kind
        schemaVersion = 1
        self.code = code
        fatal = code.isFatal
        self.message = message
        self.spaceID = spaceID
        self.requestID = requestID
    }

    private enum CodingKeys: String, CodingKey {
        case kind, schemaVersion = "v", code, fatal, message, spaceID = "doc", requestID
    }
}

public enum NetworkV1ErrorCode: String, Codable, Equatable, Sendable {
    case unsupportedNetworkVersion
    case unsupportedOperationVersion
    case unsupportedMessage
    case unexpectedMessage
    case invalidFrame
    case invalidMessage
    case invalidSelection
    case peerIDMismatch
    case resourceLimit
    case historyUnavailable
    case invalidOperation
    case operationIDCollision
    case actorSequenceCollision

    public var isFatal: Bool {
        switch self {
        case .historyUnavailable, .invalidOperation, .operationIDCollision, .actorSequenceCollision:
            return false
        default:
            return true
        }
    }
}

public enum NetworkV1Message: Equatable, Sendable {
    case hello(NetworkV1Hello)
    case spaceSelection(NetworkV1SpaceSelection)
    case historySummary(NetworkV1HistorySummary)
    case operationRequest(NetworkV1OperationRequest)
    case operationBatch(NetworkV1OperationBatch)
    case syncComplete(NetworkV1SyncComplete)
    case application(NetworkV1ApplicationMessage)
    case error(NetworkV1ErrorMessage)
}

extension NetworkV1Message: Codable {
    private enum HeaderKeys: String, CodingKey { case kind }

    public init(from decoder: Decoder) throws {
        let header = try decoder.container(keyedBy: HeaderKeys.self)
        let kind = try header.decode(String.self, forKey: .kind)
        switch kind {
        case NetworkV1Hello.kind: self = .hello(try NetworkV1Hello(from: decoder))
        case NetworkV1SpaceSelection.kind: self = .spaceSelection(try NetworkV1SpaceSelection(from: decoder))
        case NetworkV1HistorySummary.kind: self = .historySummary(try NetworkV1HistorySummary(from: decoder))
        case NetworkV1OperationRequest.kind: self = .operationRequest(try NetworkV1OperationRequest(from: decoder))
        case NetworkV1OperationBatch.kind: self = .operationBatch(try NetworkV1OperationBatch(from: decoder))
        case NetworkV1SyncComplete.kind: self = .syncComplete(try NetworkV1SyncComplete(from: decoder))
        case NetworkV1ApplicationMessage.kind: self = .application(try NetworkV1ApplicationMessage(from: decoder))
        case NetworkV1ErrorMessage.kind: self = .error(try NetworkV1ErrorMessage(from: decoder))
        default:
            throw NetworkV1CodecError.unsupportedMessage(kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .hello(let value): try value.encode(to: encoder)
        case .spaceSelection(let value): try value.encode(to: encoder)
        case .historySummary(let value): try value.encode(to: encoder)
        case .operationRequest(let value): try value.encode(to: encoder)
        case .operationBatch(let value): try value.encode(to: encoder)
        case .syncComplete(let value): try value.encode(to: encoder)
        case .application(let value): try value.encode(to: encoder)
        case .error(let value): try value.encode(to: encoder)
        }
    }
}

public enum NetworkV1CodecError: Error, Equatable, Sendable {
    case unsupportedMessage(String)
    case invalidMessage(String)
}

public enum NetworkV1MessageCodec {
    public static func encode(_ message: NetworkV1Message) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(message)
    }

    public static func decode(_ data: Data) throws -> NetworkV1Message {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let message = try decoder.decode(NetworkV1Message.self, from: data)
        try NetworkV1Validator.validate(message)
        return message
    }
}

enum NetworkV1Validator {
    static let maximumSafeInteger: Int64 = 9_007_199_254_740_991

    static func validate(_ message: NetworkV1Message) throws {
        switch message {
        case .hello(let hello):
            guard hello.kind == NetworkV1Hello.kind, hello.schemaVersion == 1,
                  hello.peerID.isCanonical, hello.networkVersions == uniquePositive(hello.networkVersions),
                  hello.operationVersions == uniquePositive(hello.operationVersions),
                  !hello.networkVersions.isEmpty, !hello.operationVersions.isEmpty,
                  hello.networkVersions.count <= 32, hello.operationVersions.count <= 32,
                  Set(hello.capabilities).count == hello.capabilities.count,
                  hello.capabilities.count <= 128,
                  ["dns-sd", "tcp", "history-ranges"].allSatisfy(hello.capabilities.contains),
                  Set(hello.spaces).count == hello.spaces.count, hello.spaces.count <= 4_096 else {
                throw NetworkV1CodecError.invalidMessage("Invalid networkHello")
            }
        case .spaceSelection(let selection):
            guard selection.kind == NetworkV1SpaceSelection.kind, selection.schemaVersion == 1,
                  Set(selection.spaces).count == selection.spaces.count, selection.spaces.count <= 4_096 else {
                throw NetworkV1CodecError.invalidMessage("Invalid spaceSelection")
            }
        case .historySummary(let summary):
            guard summary.kind == NetworkV1HistorySummary.kind, summary.schemaVersion == 1,
                  !summary.summaryID.isEmpty else { throw NetworkV1CodecError.invalidMessage("Invalid historySummary") }
            try validate(summary.actors)
        case .operationRequest(let request):
            guard request.kind == NetworkV1OperationRequest.kind, request.schemaVersion == 1,
                  !request.requestID.isEmpty, !request.summaryID.isEmpty else {
                throw NetworkV1CodecError.invalidMessage("Invalid requestOperations")
            }
            try validate(request.actors)
        case .operationBatch(let batch):
            guard batch.kind == NetworkV1OperationBatch.kind, batch.schemaVersion == 1,
                  batch.envelopes.allSatisfy({ $0.kind == OperationEnvelope.kind && $0.schemaVersion == 1 }) else {
                throw NetworkV1CodecError.invalidMessage("Invalid operationBatch")
            }
        case .syncComplete(let complete):
            guard complete.kind == NetworkV1SyncComplete.kind, complete.schemaVersion == 1,
                  !complete.summaryID.isEmpty else { throw NetworkV1CodecError.invalidMessage("Invalid syncComplete") }
        case .application(let application):
            guard application.kind == NetworkV1ApplicationMessage.kind,
                  application.schemaVersion == 1,
                  !application.messageID.isEmpty,
                  !application.channel.isEmpty,
                  application.channel.count <= 128,
                  application.payload.count <= NetworkV1FrameCodec.maximumPayloadSize / 2 else {
                throw NetworkV1CodecError.invalidMessage("Invalid application message")
            }
        case .error(let error):
            guard error.kind == NetworkV1ErrorMessage.kind, error.schemaVersion == 1,
                  error.fatal == error.code.isFatal else { throw NetworkV1CodecError.invalidMessage("Invalid networkError") }
        }
    }

    private static func uniquePositive(_ values: [Int]) -> [Int] {
        Array(Set(values.filter { $0 > 0 })).sorted(by: >)
    }

    private static func validate(_ actors: [NetworkV1ActorRanges]) throws {
        guard actors.map(\.actor).sorted() == actors.map(\.actor),
              Set(actors.map(\.actor)).count == actors.count else {
            throw NetworkV1CodecError.invalidMessage("Actor ranges are not sorted and unique")
        }
        for actor in actors {
            guard !actor.ranges.isEmpty else { throw NetworkV1CodecError.invalidMessage("Empty actor ranges") }
            var previousLast: Int64?
            for range in actor.ranges {
                guard range.first >= 0, range.first <= range.last, range.last <= maximumSafeInteger,
                      previousLast.map({ range.first > $0 + 1 }) ?? true else {
                    throw NetworkV1CodecError.invalidMessage("Invalid sequence ranges")
                }
                previousLast = range.last
            }
        }
    }
}
