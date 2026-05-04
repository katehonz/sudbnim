# API Reference

## Types

### RecordId

```nim
type RecordId* = object
  table*: string
  id*: string

# Constructors
let rid1 = record("users", "123")     # From table + id
let rid2 = record("users:abc:def")    # From string (parsed on first ':')
let rid3 = rc"users:123"              # Compile-time literal macro

# Methods
echo $rid1                            # "users:123"
echo %%rid1                           # JsonNode {"tb":"users","id":"123"}
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

## RPC Methods

All methods are available on both `Db` and `ReconnectingDb`.

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
