# EditSpace Swift

EditSpace is a transport-neutral protocol for collaborative editing of structured 3D documents. This repository contains the canonical protocol documentation and the reference implementation in Swift. A Python implementation is planned for the Blender plug-in; it should implement the wire contract documented here rather than mirror Swift-specific types.

The protocol is intentionally model-agnostic:

- operations are truth;
- snapshots are disposable caches;
- renderers and modelling applications are adapters;
- conflicts and compatibility failures are data;
- unknown future operations are preserved instead of silently overwritten;
- identity and presence belong to EditSpace, while each endpoint chooses how collaborators appear.

## Repository layout

```text
editspace-swift/
├── Package.swift                         Swift Package Manager entry point
├── EditSpace/
│   ├── EditSpace.xcodeproj               Xcode framework and test project
│   ├── EditSpace/                         Canonical Swift sources and DocC catalog
│   └── EditSpaceTests/                    Convergence and wire-format tests
├── Schemas/                               Language-neutral JSON Schemas
└── Docs/
    ├── EditSpace-System-and-API.pdf       System overview and API handbook
    └── Protocol.md                        Normative protocol specification
```

Both the Xcode project and SwiftPM compile the same source and test directories.

## System overview

![EditSpace specification and implementation hierarchy](Docs/architecture.png)

The language-neutral specification is the source of truth. The Swift and Python libraries independently implement that specification; neither language implementation defines the other. GraphiteKit imports the Swift library, and Graphite 3D uses GraphiteKit to serve its users. The Blender plug-in imports the Python library, and Blender hosts that plug-in for Blender users. An endpoint translates native modelling actions into immutable EditSpace operations. Operations are appended locally before transmission. Peer and durable-store imports are idempotent. Materializers replay the causally ordered log into endpoint-specific state.

![EditSpace durable synchronization and ephemeral presence paths](Docs/sync-flow.png)

## Protocol definition

Version 1 uses UTF-8 JSON. Transports may frame, compress, encrypt, authenticate, or batch JSON messages, but those choices do not change their contents. Dates are RFC 3339/ISO 8601 strings. Values are JSON null, boolean, finite number, string, array, or object. Binary data is referenced as an asset; it is not embedded in an operation.

### Stable identifiers

| Identifier | Lifetime | Requirement |
| --- | --- | --- |
| `doc` | Document | Stable for the collaborative document |
| `actor` | Author installation/account | Stable across reconnects and app launches |
| `op` | Operation | Globally unique and immutable; `actor:seq` is recommended |
| `target` | Entity | Stable for the entity lifetime, including after deletion |
| `peerID` | Person/device presentation identity | Stable enough to recognize a returning collaborator |
| `sessionID` | Live connection | New for each collaboration session |

### Operation envelope

The `editspace.operations` message is durable and replayable:

```json
{
  "kind": "editspace.operations",
  "v": 1,
  "doc": "scene-7",
  "ops": [
    {
      "v": 1,
      "doc": "scene-7",
      "op": "ada:42",
      "actor": "ada",
      "seq": 42,
      "deps": ["ada:41"],
      "action": "update",
      "entity": "object",
      "target": "cube-1",
      "fields": {
        "transform.position": [0.0, 1.0, 0.0]
      },
      "args": {},
      "features": ["core.v1", "crud.v1"],
      "producer": {
        "app": "Graphite",
        "appVersion": "1.0",
        "library": "EditSpace",
        "libraryVersion": "0.1"
      },
      "createdAt": "2026-09-03T20:00:00Z"
    }
  ]
}
```

Operation members:

| Member | Required | Meaning |
| --- | --- | --- |
| `v` | No | Operation schema version; defaults to 1 |
| `doc` | Yes | Document ID; must match the envelope |
| `op` | Yes | Immutable operation ID |
| `actor` | Yes | Author ID |
| `seq` | Yes | Author-local monotonic sequence used in deterministic ordering |
| `deps` | No | Causal predecessor operation IDs; defaults to `[]` |
| `action` | Yes | Extensible action token |
| `entity` | Yes | Extensible entity-kind token |
| `target` | Usually | Entity receiving the operation |
| `source` | For duplicate/link | Source entity |
| `fields` | No | JSON-safe field writes; defaults to `{}` |
| `args` | No | Action-specific, JSON-safe arguments; defaults to `{}` |
| `features` | No | Features required to interpret the operation; defaults to `[]` |
| `producer` | No | Diagnostics and upgrade guidance; never affects merge order |
| `createdAt` | No | Informational wall-clock time; never affects merge order |

Core actions are `create`, `update`, `delete`, `duplicate`, `link`, and `unlink`. Core entity kinds are `document`, `object`, `modifier`, `material`, `asset`, `constraint`, `parameter`, `dependency`, and `legacySnapshot`. Tokens are strings so implementations can preserve extensions they do not understand.

### Deterministic merge

Implementations MUST:

1. treat an operation ID and its content as immutable;
2. ignore an exact duplicate operation;
3. report an operation-ID collision if the same ID has different content;
4. order known causal predecessors before dependants;
5. break concurrent ties by `(seq, actor, op)` in ascending lexical order;
6. resolve each field independently using the greatest operation stamp;
7. represent deletion with a tombstone operation, never by deleting history;
8. preserve unsupported operations and avoid applying them destructively.

Missing dependencies do not block synchronization indefinitely. The reference implementation orders the known subset causally and uses operation-stamp order for missing or cyclic dependency sets. A receiver may request missing history before materialization.

### Peer identity and presence

Identity is part of EditSpace because collaborator presentation must work consistently across Graphite, Blender, and future endpoints. Presence remains separate from durable model state: it expires, is never replayed into a document, and may be hidden entirely by an endpoint.

```json
{
  "kind": "editspace.presence",
  "v": 1,
  "doc": "scene-7",
  "presence": {
    "identity": {
      "peerID": "device-d761",
      "actorID": "ada",
      "displayName": "Ada",
      "color": "#8B5CF6",
      "avatarURL": null,
      "attributes": {
        "endpoint": "graphite-vision"
      }
    },
    "sessionID": "session-f02b",
    "state": "active",
    "sequence": 18,
    "selectedEntities": [
      { "kind": "object", "id": "cube-1" }
    ],
    "focus": {
      "rayOrigin": [0.0, 1.6, 0.0],
      "rayDirection": [0.0, 0.0, -1.0]
    },
    "updatedAt": "2026-09-03T20:00:02Z",
    "timeToLiveSeconds": 15
  }
}
```

Presence rules:

- `actorID` links presentation identity to authored operations.
- A receiver retains only the greatest `sequence` for each `sessionID`.
- A record expires at `updatedAt + timeToLiveSeconds`.
- `offline` removes the session immediately.
- `selectedEntities` and `focus` are hints. They grant no permissions and change no model state.
- `displayName`, `color`, `avatarURL`, and arbitrary attributes are untrusted presentation data.
- An endpoint chooses whether to show names, avatars, cursors, selections, cameras, or nothing.

### Compatibility

An implementation declares supported schema versions, actions, entity kinds, and feature tokens. Unsupported input is retained in the immutable log or quarantine store with a structured problem:

- `unsupportedSchema`
- `unsupportedAction`
- `unsupportedEntity`
- `unsupportedFeature`
- `documentMismatch`
- `invalidOperation`
- `operationIDCollision`

The full normative rules and field tables are in [Docs/Protocol.md](Docs/Protocol.md). Machine-readable envelope schemas are in [Schemas](Schemas).

## Swift reference implementation

Add the local package in Xcode, or use a SwiftPM path dependency while developing:

```swift
.package(path: "../editspace-swift")
```

Create and materialize operations:

```swift
import EditSpace

let documentID = DocumentID(rawValue: "scene-7")
let actorID = ActorID(rawValue: "ada")
let cubeID = EntityID(rawValue: "cube-1")

let create = EditOperation(
    documentID: documentID,
    actorID: actorID,
    sequence: 1,
    action: .create,
    entity: .object,
    targetID: cubeID,
    fields: ["name": .string("Cube")]
)

var engine = SyncEngine(documentID: documentID)
engine.append([create], source: .local)
let state = engine.state
```

The public API is organized around:

| Area | Swift types |
| --- | --- |
| Identifiers and extension tokens | `DocumentID`, `ActorID`, `EntityID`, `OperationID`, `SessionID`, `ProtocolToken` |
| Durable edits | `EditOperation`, `OperationEnvelope`, `OperationCodec`, `Value` |
| Compatibility | `CompatibilityPolicy`, `CompatibilityProblem`, `OperationLog` |
| Reduction | `OperationStamp`, `FieldRegister`, `EntityState`, `DocumentState`, `Materializer` |
| Synchronization | `SyncEngine`, `SyncResult`, `OperationTransport`, `OperationStore` |
| Collaboration UI data | `PeerIdentity`, `PeerPresence`, `PresenceEnvelope`, `PresenceCodec`, `PresenceRoster` |

GraphiteKit links this package as a local SwiftPM dependency. Existing Graphite-prefixed CRDT APIs can migrate incrementally; new interoperable protocol work should use the `EditSpace` module.

## Python and Blender implementation notes

A Python implementation should begin with the JSON Schemas and golden JSON fixtures. Python timestamps must be emitted in UTC RFC 3339 form, sequence values must remain signed 64-bit integers, dictionary order must never affect semantics, and operation equality must compare decoded semantic content. Blender object IDs should be stored in persistent custom properties instead of being derived from mutable object names.

The Blender adapter should map scene changes to operations, apply remote state on Blender's main thread, keep the operation log off the render graph, and treat presence updates as disposable UI data.

## Build and test

```sh
swift test
```

Or select the shared `EditSpace` scheme and **My Mac**, then run the test plan. The initial suite covers JSON round trips, convergence under reordered delivery, duplicate/collision behavior, presence expiry, and sync queue routing.

## Documentation

- [Normative protocol specification](Docs/Protocol.md)
- [System and API handbook (PDF)](Docs/EditSpace-System-and-API.pdf)
- Open `EditSpace.xcodeproj` and build documentation for symbol-level DocC output.

## License

MIT. See [LICENSE](LICENSE).
