# ``EditSpace``

A Swift reference implementation of the shared 3D space collaboration protocol.

## Overview

EditSpace represents changes to a shared 3D scene as immutable JSON-safe operations. Operations address spaces, objects, transforms, meshes, vertices, faces, modifiers, materials, and assets. The operation log is authoritative; snapshots and rendered scenes are caches. The reference materializer deterministically orders causal edits, resolves concurrent field writes, retains tombstones, and preserves unsupported future data.

Peer identity and presence are deliberately part of the protocol. They connect collaborators to authored operations and carry expiring selections or focus data, while leaving every endpoint free to choose its own collaborator UI.

```swift
let spaceID = SpaceID(rawValue: "scene")
let operation = EditOperation(
    spaceID: spaceID,
    actorID: ActorID(rawValue: "ada"),
    sequence: 1,
    action: .create,
    entity: .object,
    targetID: EntityID(rawValue: "cube"),
    fields: ["name": .string("Cube")]
)

var engine = SyncEngine(spaceID: spaceID)
engine.append([operation], source: .local)
let state = engine.state
```

## Topics

### Durable operations

- ``EditOperation``
- ``OperationEnvelope``
- ``OperationCodec``
- ``OperationLog``
- ``Materializer``
- ``SpaceState``

### Synchronization and compatibility

- ``SyncEngine``
- ``OperationTransport``
- ``OperationStore``
- ``CompatibilityPolicy``
- ``CompatibilityProblem``

### Peer identity and presence

- ``PeerIdentity``
- ``PeerPresence``
- ``PresenceEnvelope``
- ``PresenceCodec``
- ``PresenceRoster``

### Identifiers and values

- ``SpaceID``
- ``SceneField``
- ``ActorID``
- ``EntityID``
- ``OperationID``
- ``SessionID``
- ``Value``
- ``ProtocolToken``
