# SurrealDB.nim

Production-grade SurrealDB driver for Nim. Supports SurrealDB 2.x and 3.x.

Built with zero external dependencies — only `nim >= 2.0.0` required.

## Features

- **JSON-RPC 2.0 over WebSocket** — native WebSocket client with ping/pong keep-alive
- **28 RPC methods** — use, signin, signup, query, select, create, insert, update, upsert, merge, patch, delete, relate, live, kill, run, and more
- **Auto-reconnect with retry** — `ReconnectingDb` wraps `Db` with exponential backoff and session state restoration (inspired by `rews` from the Go driver)
- **Compile-time literals** — `rc"users:123"` for RecordId, `tb"users"` for tables, `surql"SELECT ..."` for queries
- **Typed results** — `SurrealResult[T]` with `isOk`/`ok`/`error` pattern
- **Live queries** — `live`/`kill` with notification support
- **Session persistence** — token, namespace, database, and variables survive reconnection

## Installation

```bash
nimble install surrealdb
```

Or add to your `.nimble` file:

```nim
requires "surrealdb >= 0.3.0"
```

## Quick Start

```nim
import std/[json, asyncdispatch]
import surrealdb

proc main() {.async.} =
  # Connect to SurrealDB
  let db = await connect("ws://localhost:8000/rpc")
  defer: db.disconnect()

  # Select namespace and database
  discard await db.use("test", "test")

  # Sign in as root
  discard await db.signin("root", "root")

  # Create a record
  let created = await db.create("user:alice", %*{
    "name": "Alice",
    "age": 30,
    "email": "alice@example.com"
  })
  assert created.isOk
  echo "Created: ", created.ok

  # Select a record by RecordId
  let user = await db.select(rc"user:alice")
  if user.isOk:
    echo "Name: ", user.ok["name"].getStr()

  # Query with SurrealQL
  let result = await db.query(surql"SELECT * FROM user WHERE age > 25 ORDER BY name")
  if result.isOk:
    for row in result.ok[0]["result"]:
      echo row["name"].getStr(), ": ", row["age"].getInt()

  # Delete
  discard await db.delete(rc"user:alice")

waitFor main()
```

## Reconnecting Connection

For production use, `ReconnectingDb` provides automatic reconnection with configurable retry strategy:

```nim
import std/[json, asyncdispatch]
import surrealdb

proc main() {.async.} =
  # Configure retry with exponential backoff
  let retryer = ExponentialBackoff(
    initialDelay: 1.0,   # Start at 1 second
    maxDelay: 30.0,      # Cap at 30 seconds
    multiplier: 2.0,     # Double each attempt
    maxRetries: 10,      # 0 = unlimited
    jitter: true         # ±30% jitter
  )

  # Create reconnecting connection
  let rdb = newReconnectingDb("ws://localhost:8000", retryer)
  await rdb.start()
  defer: rdb.disconnect()

  # Use + signin — tokens are captured for reconnection
  discard await rdb.use("test", "test")
  let signinResult = await rdb.signin("root", "root")
  echo "Token: ", signinResult.ok.getStr()

  # Perform operations — will auto-reconnect on failure
  discard await rdb.create("user:bob", %*{"name": "Bob"})
  let users = await rdb.select(tb"user")
  echo users.ok

waitFor main()
```

## API Reference

### Connection Management

| Method | Description |
|---|---|
| `connect(url)` → `Db` | Open a WebSocket connection |
| `db.disconnect()` | Close the connection |
| `db.isConnected()` → `bool` | Check connection state |
| `newReconnectingDb(url, retryer)` → `ReconnectingDb` | Create reconnecting connection |
| `rdb.start()` | Connect + start reconnection loop |
| `rdb.disconnect()` | Close and stop reconnecting |

### Authentication

| Method | Parameters |
|---|---|
| `db.signin(user, pass)` | Root credentials |
| `db.signinNs(ns, user, pass)` | Namespace credentials |
| `db.signinDb(ns, db, user, pass)` | Database credentials |
| `db.signinRecord(ns, db, access, params)` | Record access |
| `db.signup(ns, db, access, params)` | Sign up |
| `db.authenticate(token)` | JWT token |
| `db.invalidate()` | Invalidate session |
| `db.info()` | Current user info |

### CRUD Operations

| Method | Description |
|---|---|
| `db.create(thing, content = {})` | Create a record |
| `db.select(thing)` | Select records by table, RecordId, or DbTable |
| `db.insert(table, content)` | Insert one or more records |
| `db.insertRelation(table, content)` | Insert a relation |
| `db.update(thing, content)` | Full replace |
| `db.upsert(thing, content)` | Create or update |
| `db.merge(thing, content)` | Partial update (PATCH-like) |
| `db.patch(thing, patches)` | JSON Patch |
| `db.delete(thing)` | Delete records |

### Queries

| Method | Description |
|---|---|
| `db.query(sql, vars = {})` | Execute SurrealQL with optional variables |
| `db.query(surql"...", vars = {})` | Same with compile-time SurQL literal |

### Graph Relations

| Method | Description |
|---|---|
| `db.relate(source, relation, target, content = {})` | Create a graph relation |

### Live Queries

| Method | Description |
|---|---|
| `db.live(table, diff = false)` | Start a live query |
| `db.kill(liveId)` | Kill a live query |

### Variables & Functions

| Method | Description |
|---|---|
| `db.setVar(name, value)` | Set a query variable |
| `db.unsetVar(name)` | Unset a query variable |
| `db.run(fnName, args = [])` | Run a SurrealDB function |
| `db.version()` | Get server version |
| `db.use(ns, db)` | Select namespace and database |

### Literal Macros

| Macro | Produces | Example |
|---|---|---|
| `rc"table:id"` | `RecordId` | `rc"users:abc123"` |
| `tb"name"` | `DbTable` | `tb"users"` |
| `surql"..."` | `SurQL` | `surql"SELECT * FROM users"` |

### Result Types

**`SurrealResult[T]`** — returned by all RPC methods:

```nim
type SurrealResult[T] = object
  case isOk: bool
  of true:  ok: T
  of false: error: RpcError
```

**`RpcError`** — error from the server:

```nim
type RpcError = object
  code: int          # JSON-RPC error code
  message: string    # Error message
```

**Query result format** — SurrealDB 3.0 wraps query results:

```nim
# db.query() returns [{status: "OK", result: [...rows], time: "..."}]
let r = await db.query("SELECT * FROM user")
let rows = r.ok[0]["result"]  # The actual row array
```

### Retry Strategies

```nim
# Exponential backoff (default jitter: ±30%)
ExponentialBackoff(
  initialDelay: 1.0,    # seconds
  maxDelay: 30.0,        # seconds
  multiplier: 2.0,
  maxRetries: 10,        # 0 = unlimited
  jitter: true
)

# Fixed delay
FixedDelay(
  delay: 5.0,            # seconds
  maxRetries: 3          # 0 = unlimited
)

# No retry (fail immediately)
newReconnectingDb(url)   # retryer = nil
```

## Testing

Tests require a running SurrealDB instance:

```bash
# Start SurrealDB
docker run -d --name surrealdb -p 8080:8000 surrealdb/surrealdb:latest \
  start --user root --pass root --allow-all

# Run all tests
nimble test

# Or individually
nim c -r --hints:off --path:src tests/test_integration.nim
nim c -r --hints:off --path:src tests/test_reconnect.nim
```

## Architecture

```
src/surrealdb/
├── surrealdb.nim                    # Public API surface
└── private/
    ├── types.nim                    # All types: RecordId, Db, Result, Retryer, etc.
    ├── websocket.nim                # Zero-dependency WebSocket client (RFC 6455)
    ├── connection.nim               # Db type + all 28 RPC methods
    └── reconnect.nim               # ReconnectingDb with retry + session restore
```

**Design decisions:**
- **No external dependencies** — custom WebSocket implementation removes the need for `ws` or `websocket` libraries
- **JSON-RPC 2.0** — SurrealDB 3.0 uses JSON over WebSocket (not CBOR), simpler and more debuggable
- **Async native** — built on Nim's `asyncdispatch` (single-threaded event loop)
- **Method dispatch for Retryer** — allows extensible retry strategies via Nim's method system
- **Request/response correlation** — random 16-char base62 IDs map requests to `Future` completions

## License

MIT — see [LICENSE](LICENSE)
# sudbnim
