import Foundation

/// Stable, user-facing peer information. Endpoints decide whether and how to display it.
public struct PeerIdentity: Codable, Equatable, Sendable {
    public let peerID: String
    public let actorID: ActorID
    public let displayName: String?
    public let color: String?
    public let avatarURL: String?
    public let attributes: [String: Value]

    public init(
        peerID: String,
        actorID: ActorID,
        displayName: String? = nil,
        color: String? = nil,
        avatarURL: String? = nil,
        attributes: [String: Value] = [:]
    ) {
        self.peerID = peerID
        self.actorID = actorID
        self.displayName = displayName
        self.color = color
        self.avatarURL = avatarURL
        self.attributes = attributes
    }
}

public enum PresenceState: String, Codable, Sendable {
    case active
    case idle
    case away
    case offline
}

/// Ephemeral collaboration state. Presence is never part of the durable operation log.
public struct PeerPresence: Codable, Equatable, Sendable {
    public let identity: PeerIdentity
    public let sessionID: SessionID
    public let state: PresenceState
    public let sequence: Int64
    public let selectedEntities: [EntityReference]
    public let focus: [String: Value]
    public let updatedAt: Date
    public let timeToLiveSeconds: Int

    public init(
        identity: PeerIdentity,
        sessionID: SessionID,
        state: PresenceState = .active,
        sequence: Int64,
        selectedEntities: [EntityReference] = [],
        focus: [String: Value] = [:],
        updatedAt: Date = Date(),
        timeToLiveSeconds: Int = 15
    ) {
        self.identity = identity
        self.sessionID = sessionID
        self.state = state
        self.sequence = sequence
        self.selectedEntities = selectedEntities
        self.focus = focus
        self.updatedAt = updatedAt
        self.timeToLiveSeconds = timeToLiveSeconds
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        updatedAt.addingTimeInterval(TimeInterval(timeToLiveSeconds)) < date
    }
}

/// A language-neutral presence message sent beside operation batches.
public struct PresenceEnvelope: Codable, Equatable, Sendable {
    public static let kind = "editspace.presence"
    public static let currentSchemaVersion = 1

    public let kind: String
    public let schemaVersion: Int
    public let spaceID: SpaceID
    public let presence: PeerPresence

    public init(
        kind: String = PresenceEnvelope.kind,
        schemaVersion: Int = PresenceEnvelope.currentSchemaVersion,
        spaceID: SpaceID,
        presence: PeerPresence
    ) {
        self.kind = kind
        self.schemaVersion = schemaVersion
        self.spaceID = spaceID
        self.presence = presence
    }

    private enum CodingKeys: String, CodingKey {
        case kind, schemaVersion = "v", spaceID = "doc", presence
    }
}

/// Canonical JSON codec for ephemeral presence messages.
public enum PresenceCodec {
    public static func encode(_ envelope: PresenceEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    public static func decode(_ data: Data, expectedSpaceID: SpaceID? = nil) throws -> PresenceEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(PresenceEnvelope.self, from: data)
        guard envelope.kind == PresenceEnvelope.kind else { throw CodecError.wrongMessageKind(envelope.kind) }
        guard envelope.schemaVersion <= PresenceEnvelope.currentSchemaVersion else {
            throw CodecError.unsupportedEnvelopeSchema(envelope.schemaVersion)
        }
        if let expectedSpaceID, expectedSpaceID != envelope.spaceID {
            throw CodecError.spaceMismatch(expected: expectedSpaceID, actual: envelope.spaceID)
        }
        return envelope
    }
}

/// Maintains the newest non-expired presence record for every connected peer session.
public struct PresenceRoster: Sendable {
    public private(set) var presences: [SessionID: PeerPresence] = [:]

    public init() {}

    @discardableResult
    public mutating func merge(_ presence: PeerPresence, now: Date = Date()) -> Bool {
        guard !presence.isExpired(at: now) else { return false }
        if let current = presences[presence.sessionID], current.sequence >= presence.sequence { return false }
        if presence.state == .offline { presences.removeValue(forKey: presence.sessionID) }
        else { presences[presence.sessionID] = presence }
        return true
    }

    public mutating func removeExpired(at date: Date = Date()) {
        presences = presences.filter { !$0.value.isExpired(at: date) }
    }
}
