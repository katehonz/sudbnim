# API Reference

## Types

### RecordId

```nim
type RecordId* = object
  table*: string
  id*: JsonNode         # Supports string, int, array, object IDs

# Constructors
let rid1 = record("users", "123")         # From table + string id
let rid2 = record("users", %*[1, 2, 3])   # From table + complex id
let rid3 = record("users:abc:def")        # From string (parsed on first ':')
let rid4 = rc"users:123"                  # Compile-time literal macro

# Methods
echo $rid1                            # "users:123"
echo $rid2                            # "users:[1,2,3]"
echo %%rid1                           # JsonNode {"tb":"users","id":"123"}
echo surrealString(rid1)              # "r'users:123'"
assert rc"users:123" == rc"users:123"
```

### DbTable

```nim
type DbTable* = distinct string

# Constructors
let t1 = dbTable("users")             # Runtime constructor
let t2 = tb"users"                    # Compile-time literal

# Usage
let r = await db.select(tb"users")
```

### SurQL

```nim
type SurQL* = distinct string

let q = surql"SELECT * FROM users WHERE age > 21"
let r = await db.query(q)
```

### UUID

```nim
type UUID* = distinct string

let id = newUuid()                    # Generates random UUIDv4
echo string(id)                       # Convert to string
```

### SurrealResult[T]

```nim
type
  SurrealResult*[T] = object
    case isOk*: bool
    of true:  ok*: T
    of false: error*: RpcError

  RpcError* = object
    code*: int
    message*: string

# Helpers
ok(value)                             # Create success result
err[T](code, msg)                     # Create error result
```

### QueryResult[T]

Wraps a single statement result from `db.query()`.

```nim
type QueryResult*[T] = object
  status*: string                     # "OK" or "ERR"
  result*: T                          # The actual data
  time*: string                       # Execution time
  error*: ServerError                 # Query-level error, if any
```

### QueryError

Represents a query-level error (non-retriable).

```nim
type QueryError* = object
  message*: string

echo $qe   # "syntax error"
```

### Range Types

SurrealDB range types for record IDs and queries.

```nim
type
  BoundIncluded*[T] = object
    value*: T

  BoundExcluded*[T] = object
    value*: T

  Range*[T] = object
    beginBound*: JsonNode
    endBound*: JsonNode

  RecordRangeID*[T] = object
    table*: DbTable
    rangeVal*: Range[T]

# Usage
let r = Range[int](
  beginBound: %%BoundIncluded[int](value: 1),
  endBound: %%BoundExcluded[int](value: 10)
)
let rr = RecordRangeID[int](table: tb"items", rangeVal: r)
```

### CustomNil / None

Represents SurrealDB's `NONE` value.

```nim
type CustomNil* = object
let None* = CustomNil()

echo %%None   # null
```

### Retryer

```nim
type
  Retryer* = ref object of RootObj
    attempt*: int

  ExponentialBackoff* = ref object of Retryer
    initialDelay*: float              # Default: 1.0
    maxDelay*: float                  # Default: 30.0
    multiplier*: float                # Default: 2.0
    maxRetries*: int                  # Default: 10 (0 = unlimited)
    jitter*: bool                     # Default: true

  FixedDelay* = ref object of Retryer
    delay*: float                     # Fixed delay in seconds
    maxRetries*: int                  # 0 = unlimited
```

### ReconnectingDb

```nim
type
  ConnectionState* = enum
    stateDisconnected, stateConnecting,
    stateConnected, stateClosing, stateClosed

  ReconnectingDb* = ref object
    url*: string
    ns*: string
    database*: string
    token*: string
    state*: ConnectionState
    db*: Db
    retryer*: Retryer
    vars*: TableRef[string, JsonNode]
```

### Notification (Live Queries)

```nim
type
  NotificationAction* = enum
    naCreate = "CREATE"
    naUpdate = "UPDATE"
    naDelete = "DELETE"
    naKilled = "KILLED"

  Notification*[T] = object
    id*: UUID
    action*: NotificationAction
    result*: T
```

---

## Connection API

### `connect` — Base Connection

```nim
proc connect*(url: string): Future[Db]
```

Creates a WebSocket connection to SurrealDB.

- **Parameters:** `url` — WebSocket URL (e.g., `ws://localhost:8000`). `/rpc` appended automatically if missing.
- **Returns:** `Db` connection object.
- **Throws:** `WSError` if connection or WebSocket upgrade fails.

### `disconnect` — Base Connection

```nim
proc disconnect*(db: Db)
```

Closes the WebSocket connection and stops the listen loop.

### `isConnected` — Base Connection

```nim
proc isConnected*(db: Db): bool
```

Returns `true` if the WebSocket is open and the listen loop is running.

---

## Reconnecting Connection API

### `newReconnectingDb`

```nim
proc newReconnectingDb*(url: string, retryer: Retryer = nil): ReconnectingDb
```

Creates a reconnecting connection wrapper.

- **Parameters:**
  - `url` — WebSocket URL
  - `retryer` — Retry strategy (`nil` = no retry, fail immediately)
- **Returns:** `ReconnectingDb` in `stateDisconnected`.

### `start`

```nim
proc start*(rdb: ReconnectingDb): Future[void]
```

Connects and starts the reconnection poll loop (checks connection every 5 seconds).

### `disconnect` — Reconnecting

```nim
proc disconnect*(rdb: ReconnectingDb)
```

Closes the connection and stops the reconnection loop.

### `isConnected` — Reconnecting

```nim
proc isConnected*(rdb: ReconnectingDb): bool
```

Returns `true` if the underlying `Db` is connected.

---

## HTTP Connection API

HTTP transport provides an alternative to WebSocket. Use HTTP when you don't need live queries, sessions, or transactions.

### `newHttpClient`

```nim
proc newHttpClient*(url: string, codec: Codec = nil): HttpClient
```

Creates an HTTP connection to SurrealDB.

- **Parameters:**
  - `url` — HTTP URL (e.g., `http://localhost:8000`). `/` appended automatically if missing.
  - `codec` — Optional codec (`newJsonCodec()` or `newCborCodec()`). Defaults to JSON.
- **Returns:** `HttpClient` connection object.

### `health` — HTTP

```nim
proc health*(c: HttpClient): Future[bool]
```

Check if the SurrealDB server is healthy.

### `close` — HTTP

```nim
proc close*(c: HttpClient)
```

Closes the HTTP client.

**HTTP limitations:** Live queries, sessions, transactions, and `run()` are not supported via HTTP. Use WebSocket for these features.

---

## RPC Methods

All methods are available on `Db`, `ReconnectingDb`, and `HttpClient` (except where noted).

### Connection & Session

#### `use`
```nim
proc use*(db: Db, namespace, database: string): Future[SurrealResult[JsonNode]]
```
Select namespace and database. Required before any CRUD operations (unless using root-level queries).

#### `version`
```nim
proc version*(db: Db): Future[SurrealResult[JsonNode]]
```
Returns the SurrealDB server version string.

#### `info`
```nim
proc info*(db: Db): Future[SurrealResult[JsonNode]]
```
Returns information about the currently authenticated user.

### Authentication

#### `signin` (root)
```nim
proc signin*(db: Db, user, pass: string): Future[SurrealResult[JsonNode]]
```
Authenticate with root credentials. Returns a JWT token string.

#### `signinNs` (namespace)
```nim
proc signinNs*(db: Db, ns, user, pass: string): Future[SurrealResult[JsonNode]]
```
Authenticate within a namespace. Returns a JWT token.

#### `signinDb` (database)
```nim
proc signinDb*(db: Db, ns, database, user, pass: string): Future[SurrealResult[JsonNode]]
```
Authenticate within a database. Returns a JWT token.

#### `signinRecord` (record access)
```nim
proc signinRecord*(db: Db, ns, database, access: string,
                   params: JsonNode): Future[SurrealResult[JsonNode]]
```
Authenticate using a table-based access method (e.g., `DEFINE ACCESS ... ON NAMESPACE`).

`params` should contain fields matching the access definition (e.g., `{"email": "...", "pass": "..."}`).

#### `signup`
```nim
proc signup*(db: Db, ns, database, access: string,
             params: JsonNode): Future[SurrealResult[JsonNode]]
```
Register a new user through a record access method.

#### `authenticate`
```nim
proc authenticate*(db: Db, token: string): Future[SurrealResult[JsonNode]]
```
Authenticate using an existing JWT token.

#### `invalidate`
```nim
proc invalidate*(db: Db): Future[SurrealResult[JsonNode]]
```
Invalidate the current authentication session.

### CRUD Operations

#### `create`
```nim
proc create*(db: Db, thing: string, content: JsonNode = newJObject()): Future[SurrealResult[JsonNode]]
proc create*(db: Db, thing: RecordId, content: JsonNode = newJObject()): Future[SurrealResult[JsonNode]]
```
Create a new record.

- If `thing` is a table name (e.g., `"user"`), a random ID is generated.
- If `thing` is a RecordId (e.g., `rc"user:abc"`), that ID is used.

#### `select`
```nim
proc select*(db: Db, thing: string): Future[SurrealResult[JsonNode]]
proc select*(db: Db, thing: RecordId): Future[SurrealResult[JsonNode]]
proc select*(db: Db, thing: DbTable): Future[SurrealResult[JsonNode]]
```
Select one or more records.

- String: `"user:abc"` → single record, `"user"` → all records
- RecordId: `rc"user:abc"` → single record
- DbTable: `tb"user"` → all records (returns array, may be empty)

#### `insert`
```nim
proc insert*(db: Db, table: string, content: JsonNode): Future[SurrealResult[JsonNode]]
proc insert*(db: Db, tbl: DbTable, content: JsonNode): Future[SurrealResult[JsonNode]]
```
Insert one or more records. `content` can be a single object or an array of objects.

#### `insertRelation`
```nim
proc insertRelation*(db: Db, table: string, content: JsonNode): Future[SurrealResult[JsonNode]]
```
Insert a relation record using the graph edge table.

#### `update`
```nim
proc update*(db: Db, thing: string, content: JsonNode): Future[SurrealResult[JsonNode]]
proc update*(db: Db, thing: RecordId, content: JsonNode): Future[SurrealResult[JsonNode]]
```
Full replacement update of a record. All existing fields not in `content` are removed.

#### `upsert`
```nim
proc upsert*(db: Db, thing: string, content: JsonNode): Future[SurrealResult[JsonNode]]
proc upsert*(db: Db, thing: RecordId, content: JsonNode): Future[SurrealResult[JsonNode]]
```
Create a record if it doesn't exist, or update if it does.

#### `merge`
```nim
proc merge*(db: Db, thing: string, content: JsonNode): Future[SurrealResult[JsonNode]]
proc merge*(db: Db, thing: RecordId, content: JsonNode): Future[SurrealResult[JsonNode]]
```
Partial update — only fields in `content` are modified; existing fields are preserved.

#### `patch`
```nim
proc patch*(db: Db, thing: string, patches: JsonNode): Future[SurrealResult[JsonNode]]
```
Apply a JSON Patch (RFC 6902) to a record.

```nim
discard await db.patch("user:alice", %*[
  {"op": "replace", "path": "/name", "value": "Alice 2.0"},
  {"op": "remove", "path": "/temp_field"}
])
```

#### `delete`
```nim
proc delete*(db: Db, thing: string): Future[SurrealResult[JsonNode]]
proc delete*(db: Db, thing: RecordId): Future[SurrealResult[JsonNode]]
proc delete*(db: Db, thing: DbTable): Future[SurrealResult[JsonNode]]
```
Delete a specific record or all records in a table.

### Queries

#### `query`
```nim
proc query*(db: Db, sql: string, vars: JsonNode = newJObject()): Future[SurrealResult[JsonNode]]
proc query*(db: Db, sql: SurQL, vars: JsonNode = newJObject()): Future[SurrealResult[JsonNode]]
```
Execute arbitrary SurrealQL.

SurrealDB 3.0 wraps results: `r.ok` is an array of `[{status, result, time}]` objects (one per SQL statement).

```nim
let r = await db.query("SELECT * FROM user; SELECT * FROM post")
let userRows = r.ok[0]["result"]  # Array of user records
let postRows = r.ok[1]["result"]  # Array of post records
```

### Graph Relations

#### `relate`
```nim
proc relate*(db: Db, source: string, relation: string, target: string,
             content: JsonNode = newJObject()): Future[SurrealResult[JsonNode]]
```
Create a graph relation:

```nim
discard await db.relate("user:alice", "likes", "post:123", %*{"at": "2024-01-01"})
```

### Live Queries

#### `live`
```nim
proc live*(db: Db, table: string, diff: bool = false): Future[SurrealResult[JsonNode]]
```
Start a live query on a table. Returns a live query UUID.

```nim
let r = await db.live("user")
let liveId = r.ok.getStr()
```

#### `onNotification` / `offNotification`
```nim
proc onNotification*(db: Db, liveId: string, handler: LiveQueryHandler)
proc offNotification*(db: Db, liveId: string)
```
Register or unregister a callback to receive live query notifications.

```nim
let r = await db.live("user")
let liveId = r.ok.getStr()

db.onNotification(liveId) do (action: NotificationAction, data: JsonNode):
  case action
  of naCreate: echo "Created: ", data
  of naUpdate: echo "Updated: ", data
  of naDelete: echo "Deleted: ", data
  of naKilled: echo "Live query killed"

# Later...
db.offNotification(liveId)
discard await db.kill(liveId)
```

#### `kill`
```nim
proc kill*(db: Db, liveId: string): Future[SurrealResult[JsonNode]]
proc kill*(db: Db, liveId: UUID): Future[SurrealResult[JsonNode]]
```
Kill an active live query.

### Transactions

#### `begin`
```nim
proc begin*(db: Db): Future[SurrealResult[JsonNode]]
```
Start an interactive transaction.

```nim
discard await db.begin()
let r = await db.create("user:temp", %*{"name": "Temp"})
discard await db.commit()
```

#### `commit`
```nim
proc commit*(db: Db): Future[SurrealResult[JsonNode]]
```
Commit the current transaction.

#### `cancel`
```nim
proc cancel*(db: Db): Future[SurrealResult[JsonNode]]
```
Cancel (rollback) the current transaction.

### Variables & Functions

#### `setVar`
```nim
proc setVar*(db: Db, name: string, value: JsonNode): Future[SurrealResult[JsonNode]]
```
Define a query variable for use in parameterized queries (`$name`).

#### `unsetVar`
```nim
proc unsetVar*(db: Db, name: string): Future[SurrealResult[JsonNode]]
```
Remove a previously defined query variable.

#### `run`
```nim
proc run*(db: Db, fnName: string, args: JsonNode = %[]): Future[SurrealResult[JsonNode]]
```
Execute a SurrealDB function.

`args` should be a JSON array or a single value to pass as argument.

```nim
discard await db.run("fn::myfunc")
discard await db.run("fn::add", %*[10, 20])
```

---

## Session API (SurrealDB v3+)

Sessions allow independent authentication, namespace selection, and variable scope on WebSocket connections.

### Creating a Session

```nim
let s = (await db.attach()).ok
```

### Session Methods

All CRUD methods (`query`, `select`, `create`, `update`, `upsert`, `merge`, `delete`, `insert`, `patch`, `run`) are available on `Session`.

Additional session-scoped methods:

#### `use`
```nim
proc use*(s: Session, ns, database: string): Future[SurrealResult[JsonNode]]
```

#### `setVar` / `unsetVar`
```nim
proc setVar*(s: Session, name: string, value: JsonNode): Future[SurrealResult[JsonNode]]
proc unsetVar*(s: Session, name: string): Future[SurrealResult[JsonNode]]
```

#### `info`
```nim
proc info*(s: Session): Future[SurrealResult[JsonNode]]
```

#### `version`
```nim
proc version*(s: Session): Future[SurrealResult[JsonNode]]
```

#### `live` / `kill`
```nim
proc live*(s: Session, table: string, diff: bool = false): Future[SurrealResult[JsonNode]]
proc kill*(s: Session, liveId: string): Future[SurrealResult[JsonNode]]
```

#### `detach`
```nim
proc detach*(s: Session): Future[SurrealResult[JsonNode]]
```
Closes the session. After detaching, the session cannot be used anymore.

---

## Typed Wrappers

Import `surrealdb/typed` for generic wrappers that automatically unmarshal `JsonNode` results into Nim types.

```nim
import surrealdb
import surrealdb/typed

type Person = object
  name: string
  age: int

# Query with typed results
let res = await query[seq[Person]](db, "SELECT * FROM person")
if res.isOk:
  for qr in res.ok:
    if qr.status == "OK":
      echo qr.result[0].name

# Create with typed result
let created = await create[Person](db, "person", %*{"name": "Alice", "age": 30}, Person)
if created.isOk:
  echo created.ok.name

# Select one record
let person = await select[Person](db, rc"person:alice", Person)
```

Available typed wrappers for `Db`, `Session`, and `Transaction`:
- `query*[T](db, sql, vars)` → `SurrealResult[seq[QueryResult[T]]]`
- `create*[T](db, thing, content, typedesc[T])` → `SurrealResult[T]`
- `select*[T](db, thing, typedesc[T])` → `SurrealResult[T]`
- `update*[T](db, thing, content, typedesc[T])` → `SurrealResult[T]`
- `upsert*[T](db, thing, content, typedesc[T])` → `SurrealResult[T]`
- `merge*[T](db, thing, content, typedesc[T])` → `SurrealResult[T]`
- `insert*[T](db, table, content, typedesc[T])` → `SurrealResult[seq[T]]]`
- `delete*[T](db, thing, typedesc[T])` → `SurrealResult[T]`

---

## Query Composition

### QueryStmt

```nim
type QueryStmt* = object
  sql*: string
  vars*: JsonNode
  result*: QueryResult[JsonNode]
```

### `queryRaw`

Compose multiple statements and execute them in a single RPC call:

```nim
var stmts = @[
  QueryStmt(sql: "SELECT * FROM person WHERE age > $min", vars: %*{"min": 18}),
  QueryStmt(sql: "SELECT COUNT() FROM person", vars: newJObject()),
]
let res = await db.queryRaw(stmts)
if res.isOk:
  for stmt in stmts:
    echo stmt.result.status, " ", stmt.result.time
```

---

## Error Helpers

#### `isRetriable`
```nim
proc isRetriable*(err: RpcError): bool
```
Returns `true` if the error is potentially transient (network, timeout, server overload). Query-level errors (parse, invalid data) are non-retriable.

#### `isQueryError`
```nim
proc isQueryError*(err: RpcError): bool
```
Returns `true` if this is a query-level error (syntax, type, or logic bug). These should **not** be retried.

---

## CBOR Transport

CBOR provides binary encoding for more compact payloads. Use with WebSocket connections.

### Codec Types

```nim
type
  CodecKind* = enum
    ckJson = "json"
    ckCbor = "cbor"

  Codec* = ref object
    kind*: CodecKind

proc newJsonCodec*(): Codec
proc newCborCodec*(): Codec
```

### Using CBOR

```nim
import surrealdb

# WebSocket with CBOR
let db = await connect("ws://localhost:8000", codec = newCborCodec())

# HTTP with CBOR
let http = newHttpClient("http://localhost:8000", codec = newCborCodec())
```

### Type-Aware CBOR Encoding

For explicit type encoding in CBOR params, use marker helpers:

```nim
import surrealdb/private/surrealcbor

# RecordId with tag 8
let rid = recordidCbor("user", "alice")

# UUID with tag 9 (string) or tag 37 (binary)
let uuid = stringuuidCbor("0191d530-3af8-7000-8b57-9f6707ab6c05")
let uuidHex = binaryuuidCbor("0191d5303af870008b579f6707ab6c05")

# Table with tag 7
let tbl = tableCbor("users")

# DateTime with tag 12
let dt = datetimeCbor("2025-01-15T10:30:00Z")

# Duration with tag 14
let dur = durationCbor("1h30m")

# Decimal with tag 10
let dec = decimalCbor("3.14159")

# Range with tag 49
let rng = rangeCbor(beginMarker, endMarker)

# Bound with tag 50 (included) or 51 (excluded)
let bound = boundCbor("incl", innerValue)
```

These markers are used internally when encoding typed wrappers and can be used directly for explicit type encoding.
