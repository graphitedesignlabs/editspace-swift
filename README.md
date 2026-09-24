# EditSpace Swift

<a href="https://github.com/graphitedesignlabs/EditSpace">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/graphitedesignlabs/EditSpace/main/editspacecompatible-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/graphitedesignlabs/EditSpace/main/editspacecompatible-light.png">
    <img alt="EditSpace-compatible SDK" src="https://raw.githubusercontent.com/graphitedesignlabs/EditSpace/main/editspacecompatible-light.png">
  </picture>
</a>

`editspace-swift` is a compatible SDK. Applications should use the separate EditSpace Tool badge only when they implement EditTool; see the [badge guidance](https://github.com/graphitedesignlabs/EditSpace#badges).

This repository is the Swift reference implementation and maintained source of truth for protocol evolution. Language-neutral changes are periodically back-applied to the [EditSpace protocol repository](https://github.com/graphitedesignlabs/EditSpace), which is pinned here in the `Protocol` submodule.

## Repository layout

```text
editspace-swift/
├── Package.swift                         Swift Package Manager entry point
├── EditSpace/
│   ├── EditSpace.xcodeproj               Xcode framework and test project
│   ├── EditSpace/                         Canonical Swift sources and DocC catalog
│   └── EditSpaceTests/                    Convergence and wire-format tests
├── Protocol/                              Pinned language-neutral specification and conformance suite
└── Docs/
    └── EditSpace-System-and-API.pdf       Swift implementation handbook
```

Both the Xcode project and SwiftPM compile the same source and test directories.

## Edit operation packet example

The Swift types encode and decode the language-neutral `editspace.operations` packet:

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

For wire semantics, merge rules, presence, compatibility, schemas, and conformance vectors, see the [EditSpace protocol repository](https://github.com/graphitedesignlabs/EditSpace) or the pinned [protocol specification](Protocol/SPECIFICATION.md).

## Swift reference implementation

Add the local package in Xcode, or use a SwiftPM path dependency while developing:

```swift
.package(path: "../editspace-swift")
```

Create and materialize operations:

```swift
import EditSpace

let spaceID = SpaceID(rawValue: "scene-7")
let actorID = ActorID(rawValue: "ada")
let cubeID = EntityID(rawValue: "cube-1")

let create = EditOperation(
    spaceID: spaceID,
    actorID: actorID,
    sequence: 1,
    action: .create,
    entity: .object,
    targetID: cubeID,
    fields: ["name": .string("Cube")]
)

var engine = SyncEngine(spaceID: spaceID)
engine.append([create], source: .local)
let state = engine.state
```

The public API is organized around:

| Area | Swift types |
| --- | --- |
| Identifiers and extension tokens | `SpaceID`, `ActorID`, `EntityID`, `OperationID`, `SessionID`, `ProtocolToken` |
| Durable edits | `EditOperation`, `OperationEnvelope`, `OperationCodec`, `Value` |
| Compatibility | `CompatibilityPolicy`, `CompatibilityProblem`, `OperationLog` |
| Reduction | `OperationStamp`, `FieldRegister`, `EntityState`, `SpaceState`, `Materializer` |
| Synchronization | `SyncEngine`, `SyncResult`, `OperationTransport`, `OperationStore` |
| Collaboration UI data | `PeerIdentity`, `PeerPresence`, `PresenceEnvelope`, `PresenceCodec`, `PresenceRoster` |

GraphiteKit links this package as a local SwiftPM dependency. Existing Graphite-prefixed CRDT APIs can migrate incrementally; new interoperable protocol work should use the `EditSpace` module.

## Build and test

```sh
swift test
```

Or select the shared `EditSpace` scheme and **My Mac**, then run the test plan. The suite covers JSON round trips, convergence under reordered delivery, duplicate/collision behavior, presence expiry, and sync queue routing.

## Documentation

- [EditSpace protocol repository](https://github.com/graphitedesignlabs/EditSpace)
- [Pinned normative protocol specification](Protocol/SPECIFICATION.md)
- [System and API handbook (PDF)](Docs/EditSpace-System-and-API.pdf)
- Open `EditSpace.xcodeproj` and build documentation for symbol-level DocC output.

## License

MIT. See [LICENSE](LICENSE).
