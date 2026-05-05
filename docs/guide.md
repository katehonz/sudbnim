# Getting Started

## Prerequisites

- Nim 2.0.0 or later
- SurrealDB instance (local or remote)

## Installation

```bash
nimble install surrealdb
```

## Basic Connection

```nim
import std/[json, asyncdispatch]
import surrealdb

proc main() {.async.} =
  let db = await connect("ws://localhost:8000")
  defer: db.disconnect()

  discard await db.use("myns", "mydb")
  discard await db.signin("root", "root")

  # ... perform operations ...

waitFor main()
```

The driver automatically appends `/rpc` to the URL if missing.

## Connection Lifecycle

1. **`connect(url)`** — establishes WebSocket connection, starts listen loop
2. **`db.use(ns, db)`** — selects namespace and database
3. **`db.signin(user, pass)`** — authenticates (or one of the other signin variants)
4. **Operations** — CRUD, queries, live queries
5. **`db.disconnect()`** — closes WebSocket, stops listen loop

Always call `disconnect()` to clean up resources. The `defer:` pattern is recommended.

## Authentication Methods

```nim
# Root user
discard await db.signin("root", "rootpass")

# Namespace-scoped user
discard await db.signinNs("myns", "user", "pass")

# Database-scoped user
discard await db.signinDb("myns", "mydb", "user", "pass")

# Record access (e.g., table-based auth)
discard await db.signinRecord("myns", "mydb", "user", %*{
  "email": "alice@example.com",
  "pass": "secret"
})

# JWT token
discard await db.authenticate("eyJhbG...")

# Invalidate current session
discard await db.invalidate()
```

## Creating and Reading Data

```nim
# Create with auto-generated ID
let r = await db.create("user", %*{
  "name": "Alice",
  "age": 30
})
echo r.ok["id"].getStr()  # e.g., "user:abc123"

# Create with explicit ID
discard await db.create("user:bob", %*{"name": "Bob", "age": 25})

# Select a single record by RecordId
let alice = await db.select(rc"user:abc123")
echo alice.ok["name"].getStr()

# Select all records from a table
let allUsers = await db.select(tb"user")
for user in allUsers.ok:
  echo user["id"].getStr()

# Select by string
let bob = await db.select("user:bob")
```

## Querying

```nim
# Simple query
let result = await db.query("SELECT * FROM user WHERE age > 21")
let rows = result.ok[0]["result"]  # SurrealDB 3.0 wraps results
echo rows.len

# With variables (parameterized)
let result2 = await db.query(
  "SELECT * FROM user WHERE age > $min_age AND age < $max_age",
  %*{"min_age": 20, "max_age": 40}
)

# Using SurQL literal
let result3 = await db.query(surql"SELECT name, age FROM user ORDER BY age DESC")
```

## Updating and Deleting

```nim
# Full update (replace)
discard await db.update("user:bob", %*{"name": "Robert", "age": 26})

# Partial update (merge)
discard await db.merge("user:bob", %*{"email": "bob@example.com"})

# JSON Patch (RFC 6902)
discard await db.patch("user:bob", %*[
  {"op": "replace", "path": "/name", "value": "Bobby"},
  {"op": "add", "path": "/phone", "value": "555-1234"}
])

# Delete a specific record
discard await db.delete(rc"user:bob")

# Delete all records from a table
discard await db.delete(tb"user")
```

## Batch Operations

```nim
# Insert multiple records at once
let result = await db.insert("user", %*[
  {"name": "Charlie", "age": 35},
  {"name": "Diana", "age": 28},
  {"name": "Eve", "age": 42}
])

# Insert relation records
discard await db.insertRelation("friendship", %*{
  "in": "user:charlie",
  "out": "user:diana",
  "since": "2024-01-01"
})
```

## Graph Relations

```nim
# Create a relation
discard await db.relate(
  "user:alice",      # source
  "knows",           # relation type
  "user:bob",        # target
  %*{"since": "2023"}  # optional data
)
```

## Working with Variables

```nim
# Set a variable
discard await db.setVar("company", %*"Acme Corp")

# Use in query
let r = await db.query("SELECT * FROM user WHERE company = $company")

# Unset
discard await db.unsetVar("company")
```

## Running Functions

```nim
let result = await db.run("fn::my_custom_function")
let result2 = await db.run("fn::calculate", %*[10, 20])
let result3 = await db.run("fn::greet", "v2", %*["world"])
```

## Live Query Notifications

```nim
let r = await db.live("user")
let liveId = r.ok.getStr()

db.onNotification(liveId) do (action: NotificationAction, data: JsonNode):
  case action
  of naCreate: echo "Created: ", data
  of naUpdate: echo "Updated: ", data
  of naDelete: echo "Deleted: ", data
  of naKilled: echo "Live query killed"

# Later, when done listening...
db.offNotification(liveId)
discard await db.kill(liveId)
```

## Transactions

```nim
discard await db.begin()
let r1 = await db.create("order:1", %*{"total": 100})
let r2 = await db.create("order:2", %*{"total": 200})
discard await db.commit()

# Or rollback:
discard await db.begin()
discard await db.create("temp:1", %*{})
discard await db.cancel()
```

## Error Handling

All RPC methods return `SurrealResult[T]`:

```nim
let r = await db.query("SELECT * FROM nonexistent_table")
if not r.isOk:
  echo "Error ", r.error.code, ": ", r.error.message
  if r.error.serverError != nil:
    echo "Kind: ", r.error.serverError.kind
    echo "Details: ", r.error.serverError.details
else:
  echo "Success: ", r.ok
```

Common error codes:
- `-32000` — Server error (syntax, missing table, etc.)
- `-32601` — Method not found

## Next Steps

- See [API Reference](api.md) for the complete method listing
- See [Reconnecting Connection](reconnect.md) for production-ready connection management
- See [Examples](examples.md) for more complex usage patterns

## Typed Wrappers

For automatic unmarshaling into Nim types, import `surrealdb/typed`:

```nim
import surrealdb/typed

type Person = object
  name: string
  age: int

let created = await db.create("person", %*{"name": "Alice", "age": 30}, Person)
if created.isOk:
  echo created.ok.name  # "Alice"

let all = await query[seq[QueryResult[Person]]](db, "SELECT * FROM person")
```

Note: typed wrappers require explicit type parameters. The `query[T]` wrapper lives in the `typed` module and may need the module prefix to disambiguate from the base `query` proc.

## Sessions (SurrealDB v3+)

Sessions provide independent authentication and scope on WebSocket connections:

```nim
let sres = await db.attach()
let s = sres.ok

discard await s.signin("root", "root")
discard await s.use("test", "test")

let r = await s.query("SELECT * FROM person")
discard await s.detach()
```

Sessions support all CRUD operations, variables, live queries, and transactions (`s.begin()` → `tx.commit()`).

## Query Composition

Batch multiple statements with `QueryStmt` and `queryRaw`:

```nim
var queries = @[
  QueryStmt(sql: "SELECT * FROM person WHERE age > $min", vars: %*{"min": 18}),
  QueryStmt(sql: "SELECT count() FROM person GROUP ALL", vars: newJObject()),
]
let res = await db.queryRaw(queries)
for q in queries:
  echo q.result.status, " ", q.result.time
```

## HTTP Transport

For environments where WebSocket is not available:

```nim
let http = newHttpClient("http://localhost:8000")
defer: http.close()

http.use("test", "test")
discard await http.signin("root", "root")
discard await http.create("user:alice", %*{"name": "Alice"})
```

**Limitations:** Live queries, sessions, transactions, and `run()` are not supported over HTTP.

## Complex RecordIds

RecordIds can have array or object identifiers:

```nim
let arrId = record("item", %*[1, 2, 3])
let objId = record("doc", %*{"org": "acme", "dept": "eng"})

echo $arrId              # "item:[1,2,3]"
echo surrealString(arrId) # "r'item:[1,2,3]'"
```

## Error Helpers

Use `isRetriable` and `isQueryError` to decide whether to retry:

```nim
let r = await db.query("SELECT * FROM missing_table")
if not r.isOk:
  if r.error.isQueryError:
    echo "Fix your query — do not retry."
  elif r.error.isRetriable:
    echo "Network issue — retry is safe."
```
