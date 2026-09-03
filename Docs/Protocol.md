# EditSpace Protocol v1

Status: reference specification, September 2026.

## 1. Scope

EditSpace defines an immutable operation format, deterministic materialization rules, compatibility reporting, and ephemeral peer presence for collaborative structured editing. It does not prescribe a renderer, modelling kernel, network topology, authentication scheme, asset store, or user interface.

Normative terms MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are interpreted as requirements for interoperable implementations.

## 2. Encoding

Messages are UTF-8 JSON objects. JSON members not understood by a v1 reader MUST be ignored during interpretation and SHOULD be preserved when forwarding raw messages. JSON numbers MUST be finite. Dates are RFC 3339 strings in UTC. IDs and protocol tokens are case-sensitive Unicode strings; implementations SHOULD generate portable IDs from ASCII letters, digits, `-`, `_`, `.`, and `:`.

The Swift reference codec emits lexically sorted object keys. Canonical key order is useful for fixtures and diagnostics but MUST NOT affect message semantics.

## 3. Durable operation messages

An operation message has `kind = "editspace.operations"`, integer `v = 1`, a document ID in `doc`, and an `ops` array. Every contained operation MUST have the same `doc` value as its envelope.

Each operation contains:

- `v`: positive integer schema version, default 1;
- `doc`: document ID;
- `op`: globally unique immutable operation ID;
- `actor`: stable author ID;
- `seq`: signed 64-bit, actor-local monotonic sequence;
- `deps`: causal predecessor IDs, default empty;
- `action`: extensible action token;
- `entity`: extensible entity-kind token;
- `target`: target entity ID when the action addresses an entity;
- `source`: source entity ID for duplicate or link operations;
- `fields`: JSON object of independent field writes, default empty;
- `args`: action-specific JSON object, default empty;
- `features`: tokens required for correct interpretation, default empty;
- `producer`: optional diagnostic producer object;
- `createdAt`: optional informational timestamp.

`producer` and `createdAt` MUST NOT participate in ordering. Wall-clock time MUST NOT be used for last-writer selection.

## 4. Actions

- `create`: creates `target` with initial field registers.
- `update`: writes the supplied fields of `target`.
- `delete`: places a tombstone on `target`.
- `duplicate`: creates `target` from `source`, then overlays supplied fields.
- `link`: adds a reference between `source` and `target`.
- `unlink`: removes a reference between `source` and `target`.

Actions are open strings. An implementation MUST NOT treat an unknown action as a known action. It records an `unsupportedAction` problem and preserves the operation.

## 5. Ordering and convergence

An operation stamp is the tuple `(seq, actor, op)`. Tuple comparison first compares signed integer `seq`, then compares `actor` lexically by Unicode scalar value, then compares `op` the same way.

A materializer performs a deterministic topological sort using `deps`. Among operations whose known dependencies are satisfied, it applies ascending operation-stamp order. If dependencies are missing or cyclic, the reference implementation applies the unresolved subset in operation-stamp order and reports or retains operations that cannot safely apply.

Fields are independent last-writer-wins registers. A field write replaces its current value only when the incoming operation stamp is greater. Deletion is a tombstone. Durable operation history is append-only and MUST NOT be erased to represent model deletion.

Exact duplicates are idempotent. Reusing an operation ID with different decoded content is `operationIDCollision`; the incoming operation MUST NOT replace the existing one.

## 6. Compatibility and preservation

Before applying an operation, an endpoint checks document ID, schema version, action, entity kind, required feature tokens, and required IDs. An operation that cannot be safely interpreted MUST NOT modify materialized state. Its original data MUST be retained in the operation log, quarantine store, or forwarding layer so a newer implementation can interpret it later.

Compatibility problems are structured values with a problem kind, optional operation ID, required schema/features, producer information, and a human-readable message.

## 7. Peer identity and ephemeral presence

A presence message has `kind = "editspace.presence"`, integer `v = 1`, `doc`, and `presence`.

The `identity` object contains:

- `peerID`: presentation identity for a returning person/device;
- `actorID`: author ID connecting the peer to durable operations;
- optional `displayName`, `color`, and `avatarURL`;
- `attributes`: endpoint-defined JSON values.

The presence object additionally contains:

- `sessionID`: connection-scoped ID;
- `state`: `active`, `idle`, `away`, or `offline`;
- `sequence`: session-local monotonic signed 64-bit integer;
- `selectedEntities`: zero or more `{kind, id}` references;
- `focus`: endpoint-defined JSON values such as a ray, cursor, camera, or active tool;
- `updatedAt`: sender timestamp;
- `timeToLiveSeconds`: positive expiry interval.

A receiver retains only the record with greatest `sequence` for each `sessionID`. `offline` removes the session. Other records expire after their TTL. Presence is never appended to the operation log, never changes document state, never grants authority, and need not be displayed.

Identity data is untrusted. Authentication binds a transport connection to a peer or actor and is outside v1. Implementations SHOULD sanitize strings and URLs, limit metadata sizes, and avoid exposing private user information by default.

## 8. Synchronization

An author MUST append locally before sending to peers or stores. A peer import is appended idempotently and SHOULD be queued for durable storage. A durable-store import is appended idempotently and MAY be relayed to peers. Relay implementations MUST use operation-ID deduplication to prevent loops.

Transports may batch operation envelopes. Receivers MUST enforce practical limits for message bytes, operation counts, dependency counts, nesting depth, string length, and collection length.

Durable stores use append-only records keyed by deterministic operation identity. Snapshots MAY accelerate startup or relocalization, but a snapshot is a cache and MUST NOT supersede accepted operation history.

## 9. Assets and endpoint adapters

Binary geometry, images, and other large data SHOULD be addressed by stable asset ID plus an integrity hash and fetched outside the operation channel. An endpoint adapter converts native values into the JSON value domain and converts materialized state back to its native scene model. Native types such as `SCNVector3`, `simd_float4x4`, or Blender RNA objects MUST NOT appear in wire messages.

## 10. Versioning

Envelope and operation schema versions evolve independently. New optional members may be added within a version. A semantic addition that an old endpoint must understand requires a feature token. An incompatible representation requires a greater schema version and a documented migration.

The protocol's open action, entity, and feature strings allow vendor or application extensions. Extension tokens SHOULD use a reverse-DNS or similarly collision-resistant prefix.
