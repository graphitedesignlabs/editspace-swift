# ``EditSpace``

A transport-neutral collaborative editing protocol and its Swift reference implementation.

## Overview

EditSpace represents structured document changes as immutable JSON-safe operations. The operation log is authoritative; snapshots and rendered scenes are caches. The reference materializer deterministically orders causal edits, resolves concurrent field writes, retains tombstones, and preserves unsupported future data.

Peer identity and presence are deliberately part of the protocol. They connect collaborators to authored operations and carry expiring selections or focus data, while leaving every endpoint free to choose its own collaborator UI.

```swift
let documentID = DocumentID(rawValue: "scene")
let operation = EditOperation(
    documentID: documentID,
    actorID: ActorID(rawValue: "ada"),
    sequence: 1,
    action: .create,
    entity: .object,
    targetID: EntityID(rawValue: "cube"),
    fields: ["name": .string("Cube")]
)

var engine = SyncEngine(documentID: documentID)
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
- ``DocumentState``

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

- ``DocumentID``
- ``ActorID``
- ``EntityID``
- ``OperationID``
- ``SessionID``
- ``Value``
- ``ProtocolToken``
