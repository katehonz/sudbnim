# Examples

## Complete CRUD Example

```nim
import std/[json, asyncdispatch]
import surrealdb

proc main() {.async.} =
  let db = await connect("ws://localhost:8000")
  defer: db.disconnect()

  discard await db.use("test", "test")
  discard await db.signin("root", "root")

  # Clean slate
  discard await db.query("REMOVE TABLE IF EXISTS person")

  # Create records
  discard await db.create("person:alice", %*{
    "name": "Alice", "email": "alice@example.com", "age": 30,
    "tags": ["dev", "nim"]
  })
  discard await db.create("person:bob", %*{
    "name": "Bob", "email": "bob@example.com", "age": 25,
    "tags": ["dev", "rust"]
  })
  discard await db.create("person:charlie", %*{
    "name": "Charlie", "email": "charlie@example.com", "age": 35,
    "tags": ["dev", "go"]
  })

  # Select all
  let all = await db.select(tb"person")
  echo "Total: ", all.ok.len

  # Select one
  let alice = await db.select(rc"person:alice")
  echo "Alice: ", alice.ok

  # Query with filtering
  let youngDevs = await db.query(surql"""
    SELECT * FROM person
    WHERE age < 35 AND tags CONTAINS "dev"
    ORDER BY age ASC
    LIMIT 5
  """)
  for row in youngDevs.ok[0]["result"]:
    echo row["name"].getStr(), " (", row["age"].getInt(), ")"

  # Update
  discard await db.merge("person:alice", %*{"age": 31})

  # Delete
  discard await db.delete(rc"person:charlie")

  # Verify
  let remaining = await db.select(tb"person")
  echo "Remaining: ", remaining.ok.len

waitFor main()
```

## Graph Relations Example

```nim
import std/[json, asyncdispatch]
import surrealdb

proc main() {.async.} =
  let db = await connect("ws://localhost:8000")
  defer: db.disconnect()

  discard await db.use("test", "test")
  discard await db.signin("root", "root")
  discard await db.query("REMOVE TABLE IF EXISTS person, follows")

  # Create people
  discard await db.create("person:alice", %*{"name": "Alice"})
  discard await db.create("person:bob", %*{"name": "Bob"})
  discard await db.create("person:charlie", %*{"name": "Charlie"})

  # Create graph relations
  discard await db.relate("person:alice", "follows", "person:bob")
  discard await db.relate("person:alice", "follows", "person:charlie")
  discard await db.relate("person:bob", "follows", "person:charlie", %*{
    "since": "2024-01-01"
  })

  # Query the graph
  let followers = await db.query(surql"""
    SELECT * FROM follows WHERE out = person:charlie
  """)
  echo "Charlie's followers: ", followers.ok[0]["result"]

  # Traverse: who does Alice follow?
  let aliceFollows = await db.query(surql"""
    SELECT ->follows->person.name AS following
    FROM person:alice
  """)
  echo "Alice follows: ", aliceFollows.ok[0]["result"]

waitFor main()
```

## Reconnecting Connection with Graceful Shutdown

```nim
import std/[json, asyncdispatch, os]
import surrealdb

proc main() {.async.} =
  let retryer = ExponentialBackoff(
    initialDelay: 1.0, maxDelay: 30.0, multiplier: 2.0,
    maxRetries: 0, jitter: true
  )

  let rdb = newReconnectingDb(
    getEnv("SURREALDB_URL", "ws://localhost:8000"),
    retryer
  )

  await rdb.start()
  defer: rdb.disconnect()

  discard await rdb.use("prod", "app")
  discard await rdb.signin(
    getEnv("SURREALDB_USER", "root"),
    getEnv("SURREALDB_PASS", "root")
  )

  echo "Connected. Press Ctrl+C to stop."

  # Main loop — will survive connection drops
  var i = 0
  while true:
    try:
      let r = await rdb.query("SELECT count() FROM user GROUP ALL")
      echo "[", i, "] Users: ", r.ok[0]["result"][0]["count"].getInt()

      # Simulate periodic operations
      discard await rdb.create("log", %*{
        "timestamp": int(epochTime()),
        "message": "Heartbeat #" & $i
      })
    except:
      echo "Request failed, will retry on next poll..."

    inc i
    await sleepAsync(5000)

waitFor main()
```

## Batch Insert with Transactions

```nim
import std/[json, asyncdispatch]
import surrealdb

proc main() {.async.} =
  let db = await connect("ws://localhost:8000")
  defer: db.disconnect()

  discard await db.use("test", "test")
  discard await db.signin("root", "root")
  discard await db.query("REMOVE TABLE IF EXISTS sensor_data")

  # Bulk insert
  var records: seq[JsonNode] = @[]
  for i in 1..1000:
    records.add(%*{
      "sensor_id": "sensor_" & $i,
      "reading": rand(100.0),
      "unit": "celsius"
    })

  let r = await db.insert("sensor_data", %records)
  echo "Inserted: ", r.ok.len, " records"

  # Query aggregations
  let stats = await db.query(surql"""
    SELECT
      count() AS total,
      math::mean(reading) AS avg_temp,
      math::max(reading) AS max_temp
    FROM sensor_data GROUP ALL
  """)
  echo stats.ok[0]["result"][0]

waitFor main()
```

## JSON Patch Operations

```nim
import std/[json, asyncdispatch]
import surrealdb

proc main() {.async.} =
  let db = await connect("ws://localhost:8000")
  defer: db.disconnect()

  discard await db.use("test", "test")
  discard await db.signin("root", "root")
  discard await db.query("REMOVE TABLE IF EXISTS config")

  # Create config document
  discard await db.create("config:app", %*{
    "name": "MyApp",
    "version": "1.0.0",
    "settings": {
      "theme": "dark",
      "notifications": true
    }
  })

  # Apply JSON Patch (RFC 6902)
  discard await db.patch("config:app", %*[
    {"op": "replace", "path": "/version", "value": "2.0.0"},
    {"op": "replace", "path": "/settings/theme", "value": "light"},
    {"op": "add", "path": "/settings/locale", "value": "bg-BG"},
    {"op": "remove", "path": "/settings/notifications"}
  ])

  let updated = await db.select(rc"config:app")
  echo updated.ok

waitFor main()
```

## Parameterized Queries with Variables

```nim
import std/[json, asyncdispatch]
import surrealdb

proc main() {.async.} =
  let db = await connect("ws://localhost:8000")
  defer: db.disconnect()

  discard await db.use("test", "test")
  discard await db.signin("root", "root")
  discard await db.query("REMOVE TABLE IF EXISTS product")

  # Insert products
  discard await db.insert("product", %*[
    {"name": "Widget A", "price": 9.99, "category": "widgets"},
    {"name": "Widget B", "price": 14.99, "category": "widgets"},
    {"name": "Gadget X", "price": 49.99, "category": "gadgets"},
    {"name": "Gadget Y", "price": 79.99, "category": "gadgets"}
  ])

  # Parameterized query
  let category = "widgets"
  let minPrice = 10.0

  let r = await db.query(surql"""
    SELECT name, price FROM product
    WHERE category = $category AND price > $min_price
    ORDER BY price ASC
  """, %*{"category": category, "min_price": minPrice})

  for row in r.ok[0]["result"]:
    echo row["name"].getStr(), " → $", row["price"].getFloat()

waitFor main()
```

## Live Queries

```nim
import std/[json, asyncdispatch]
import surrealdb

proc main() {.async.} =
  let db = await connect("ws://localhost:8000")
  defer: db.disconnect()

  discard await db.use("test", "test")
  discard await db.signin("root", "root")
  discard await db.query("REMOVE TABLE IF EXISTS alert")

  # Start live query
  let liveResult = await db.live("alert")
  let liveId = liveResult.ok.getStr()
  echo "Live query started: ", liveId

  # Register notification handler
  db.onNotification(liveId) do (action: NotificationAction, data: JsonNode):
    case action
    of naCreate: echo "[ALERT CREATE] ", data
    of naUpdate: echo "[ALERT UPDATE] ", data
    of naDelete: echo "[ALERT DELETE] ", data
    of naKilled: echo "[ALERT KILLED]"

  # Simulate: create records that trigger the live query
  discard await db.create("alert:1", %*{"level": "warning", "msg": "High CPU"})
  discard await db.create("alert:2", %*{"level": "critical", "msg": "Disk full"})

  await sleepAsync(500)  # let notifications arrive

  # Kill the live query
  discard await db.kill(liveId)
  echo "Live query killed"

waitFor main()
```

## Using SurQL and RecordId Literals

```nim
import std/[json, asyncdispatch]
import surrealdb

# Compile-time literals — validated at compile time
let users = tb"users"               # DbTable
let alice = rc"users:alice"         # RecordId
let query = surql"SELECT * FROM users WHERE name = $name"

# Runtime constructors
let bob = record("users", "bob")    # RecordId(table, id)
let posts = dbTable("posts")        # DbTable

# Invalid RecordId literals fail at compile time:
# let bad = rc"invalid"             # ERROR: Invalid RecordId literal

# Valid RecordId with colon in id field
let compound = rc"users:org:123:456"  # table="users", id="org:123:456"
```

## Transactions

```nim
import std/[json, asyncdispatch]
import surrealdb

proc main() {.async.} =
  let db = await connect("ws://localhost:8000")
  defer: db.disconnect()

  discard await db.use("test", "test")
  discard await db.signin("root", "root")

  # Successful transaction
  discard await db.begin()
  discard await db.create("account:1", %*{"balance": 100})
  discard await db.create("account:2", %*{"balance": 200})
  discard await db.commit()

  # Rolled back transaction
  discard await db.begin()
  discard await db.create("temp:1", %*{"data": "wip"})
  discard await db.cancel()  # temp:1 never persisted

waitFor main()
```

## Typed Wrappers

```nim
import std/[json, asyncdispatch]
import surrealdb
import surrealdb/typed

type Person = object
  name: string
  age: int

proc main() {.async.} =
  let db = await connect("ws://localhost:8000")
  defer: db.disconnect()
  discard await db.use("test", "test")
  discard await db.signin("root", "root")
  discard await db.query("REMOVE TABLE IF EXISTS person")

  # Create with typed result
  let created = await db.create("person", %*{"name": "Alice", "age": 30}, Person)
  if created.isOk:
    echo "Created: ", created.ok.name

  # Select with typed result
  let selected = await db.select("person:alice", Person)
  if selected.isOk:
    echo "Selected: ", selected.ok.name, " ", selected.ok.age

  # Query with typed results
  let all = await query[seq[QueryResult[Person]]](db, "SELECT * FROM person")
  if all.isOk:
    for qr in all.ok:
      if qr.status == "OK" and qr.result.len > 0:
        echo qr.result[0].name

waitFor main()
```

## Sessions (SurrealDB v3+)

```nim
import std/[json, asyncdispatch]
import surrealdb

proc main() {.async.} =
  let db = await connect("ws://localhost:8000")
  defer: db.disconnect()
  discard await db.use("test", "test")
  discard await db.signin("root", "root")

  # Create a new session
  let sres = await db.attach()
  if not sres.isOk:
    echo "Failed to attach: ", sres.error.message
    return
  let s = sres.ok

  # Session starts unauthenticated — sign in again
  discard await s.signin("root", "root")
  discard await s.use("test", "test")

  # Session-scoped variable
  discard await s.setVar("min_age", %*18)

  # Query using session
  let r = await s.query("SELECT * FROM person WHERE age > $min_age")
  echo r.ok[0]["result"].len

  # Session can have its own transactions
  let txres = await s.begin()
  if txres.isOk:
    let tx = txres.ok
    discard await tx.create("person:session_test", %*{"name": "Session"})
    discard await tx.commit()

  # Detach when done
  discard await s.detach()

waitFor main()
```

## Query Composition with QueryStmt

```nim
import std/[json, asyncdispatch]
import surrealdb

proc main() {.async.} =
  let db = await connect("ws://localhost:8000")
  defer: db.disconnect()
  discard await db.use("test", "test")
  discard await db.signin("root", "root")

  var queries = @[
    QueryStmt(sql: "SELECT * FROM person WHERE age > $min", vars: %*{"min": 21}),
    QueryStmt(sql: "SELECT count() FROM person GROUP ALL", vars: newJObject()),
  ]

  let res = await db.queryRaw(queries)
  if res.isOk:
    for q in queries:
      echo q.sql, " -> ", q.result.status, " ", q.result.time

waitFor main()
```

## HTTP Client (Alternative Transport)

```nim
import std/[json, asyncdispatch]
import surrealdb

proc main() {.async.} =
  # HTTP transport — no WebSocket needed
  let http = newHttpClient("http://localhost:8000")
  defer: http.close()

  # Note: use() is synchronous for HTTP
  http.use("test", "test")
  discard await http.signin("root", "root")

  # CRUD operations work the same
  discard await http.create("user:http_test", %*{"name": "HTTP User"})
  let r = await http.select("user:http_test")
  echo r.ok

  # Limitations: no live queries, sessions, transactions, or run()

waitFor main()
```

## Complex RecordId

```nim
import std/[json, asyncdispatch]
import surrealdb

proc main() {.async.} =
  let db = await connect("ws://localhost:8000")
  defer: db.disconnect()
  discard await db.use("test", "test")
  discard await db.signin("root", "root")

  # RecordId with array ID
  let arrId = record("item", %*[1, 2, 3])
  echo $arrId  # "item:[1,2,3]"
  discard await db.create(arrId, %*{"name": "Array ID Item"})

  # RecordId with object ID
  let objId = record("doc", %*{"org": "acme", "dept": "eng"})
  echo $objId  # 'doc:{"org":"acme","dept":"eng"}'

  # SurrealString for queries
  echo surrealString(arrId)  # "r'item:[1,2,3]'"

waitFor main()
```

## Error Handling with isRetriable

```nim
import std/[json, asyncdispatch]
import surrealdb

proc main() {.async.} =
  let db = await connect("ws://localhost:8000")
  defer: db.disconnect()
  discard await db.use("test", "test")
  discard await db.signin("root", "root")

  let r = await db.query("SELECT * FROM nonexistent_table")
  if not r.isOk:
    echo "Error: ", r.error.message
    if r.error.serverError != nil:
      echo "Kind: ", r.error.serverError.kind

    # Check if we should retry
    if r.error.isRetriable:
      echo "This error might be transient — you can retry."
    else:
      echo "This is a permanent error — do not retry."

waitFor main()
```
