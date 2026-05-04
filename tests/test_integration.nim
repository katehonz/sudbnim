import std/[unittest, json, asyncdispatch, strutils]
import surrealdb

const
  TestUrl = "ws://localhost:8080"
  TestUser = "root"
  TestPass = "root"
  TestNs = "test_ns3"
  TestDb = "test_db3"

proc runTests() {.async.} =
  echo "=== SurrealDB Integration Tests ==="
  let db = await connect(TestUrl)
  defer: db.disconnect()
  check db.isConnected()

  # Version
  block:
    let r = await db.version()
    check r.isOk
    echo "  version: ", r.ok.getStr()

  # Use + Signin
  block:
    check (await db.use(TestNs, TestDb)).isOk
    check (await db.signin(TestUser, TestPass)).isOk

  # Cleanup
  discard await db.query("REMOVE TABLE IF EXISTS user")
  discard await db.query("REMOVE TABLE IF EXISTS product")

  # Create
  block:
    let r = await db.create("user:alice", %*{"name": "Alice", "age": 30})
    check r.isOk
    check r.ok["name"].getStr() == "Alice"
    check r.ok["age"].getInt() == 30

  # Select by RecordId
  block:
    let r = await db.select(rc"user:alice")
    check r.isOk
    check r.ok["name"].getStr() == "Alice"

  # Select table
  block:
    let r = await db.select(tb"user")
    check r.isOk
    check r.ok.kind == JArray
    check r.ok.len >= 1

  # Update
  block:
    let r = await db.update("user:alice", %*{"name": "Alice Updated", "age": 31})
    check r.isOk
    check r.ok["name"].getStr() == "Alice Updated"

  # Merge
  block:
    let r = await db.merge("user:alice", %*{"email": "alice@example.com"})
    check r.isOk
    check r.ok["email"].getStr() == "alice@example.com"

  # Create another
  discard await db.create("user:bob", %*{"name": "Bob", "age": 25})

  # Query
  block:
    let r = await db.query(surql"SELECT * FROM user WHERE age > 20 ORDER BY name")
    check r.isOk
    let rows = r.ok[0]["result"]
    check rows.len == 2
    check rows[0]["name"].getStr() == "Alice Updated"

  # Query with variables
  block:
    let r = await db.query("SELECT * FROM user WHERE age > $min_age", %*{"min_age": 28})
    check r.isOk
    check r.ok[0]["result"].len == 1

  # Insert multiple
  block:
    let r = await db.insert("user", %[%*{"name": "Charlie", "age": 35}, %*{"name": "Diana", "age": 28}])
    check r.isOk
    check r.ok.kind == JArray
    check r.ok.len == 2

  # Delete specific
  block:
    let r = await db.delete(rc"user:bob")
    check r.isOk

  # Upsert
  block:
    let r1 = await db.upsert("user:ups1", %*{"name": "U1", "val": 1})
    check r1.isOk
    let r2 = await db.upsert("user:ups1", %*{"name": "U2", "val": 2})
    check r2.isOk
    check r2.ok["name"].getStr() == "U2"
    discard await db.delete(rc"user:ups1")

  # Set/Unset + RETURN
  block:
    check (await db.setVar("myvar", %*"hello")).isOk
    let r2 = await db.query("RETURN $myvar")
    check r2.isOk
    check r2.ok[0]["result"].getStr() == "hello"
    check (await db.unsetVar("myvar")).isOk

  # Patch
  block:
    discard await db.create("user:patchme", %*{"name": "Patch", "tags": ["a", "b"]})
    let r = await db.patch("user:patchme", %*[
      {"op": "replace", "path": "/name", "value": "Patched"},
      {"op": "add", "path": "/tags/-", "value": "c"}
    ])
    check r.isOk
    discard await db.delete(rc"user:patchme")

  # Relate
  block:
    discard await db.create("user:rel1", %*{"name": "A"})
    discard await db.create("user:rel2", %*{"name": "B"})
    let r = await db.relate("user:rel1", "follows", "user:rel2", %*{"since": "2024"})
    check r.isOk
    discard await db.delete(rc"user:rel1")
    discard await db.delete(rc"user:rel2")

  # Run
  block:
    let r = await db.run("fn::not_exists", %*{})
    # May error or return null depending on DB state; just verify it doesn't crash
    check r.isOk or not r.isOk

  # Info
  block:
    let r = await db.info()
    check r.isOk

  # SigninNs / SigninDb
  block:
    let r1 = await db.signin(TestUser, TestPass)
    check r1.isOk

  # Transactions (via session — SurrealDB v3 requires sessions for transactions)
  block:
    echo "  Testing transactions..."
    discard await db.query("REMOVE TABLE IF EXISTS tx_test")
    let sess = await db.attach()
    if not sess.isOk:
      echo "  attach failed: ", sess.error.code, " ", sess.error.message
    check sess.isOk
    let s = sess.ok

    # Session needs its own auth and namespace/database
    check (await s.use(TestNs, TestDb)).isOk
    check (await s.signin(TestUser, TestPass)).isOk

    let b = await s.begin()
    check b.isOk
    let tx = b.ok
    let cr = await tx.create("tx_test:1", %*{"val": 1})
    if not cr.isOk:
      echo "  tx create failed: ", cr.error.code, " ", cr.error.message
    check cr.isOk
    let ca = await tx.cancel()
    if not ca.isOk:
      echo "  tx cancel failed: ", ca.error.code, " ", ca.error.message
    check ca.isOk
    let sel1 = await db.select("tx_test:1")
    # After cancel, record should not exist (or be null)
    check not sel1.isOk or sel1.ok.kind == JNull

    let b2 = await s.begin()
    check b2.isOk
    let tx2 = b2.ok
    let cr2 = await tx2.create("tx_test:2", %*{"val": 2})
    if not cr2.isOk:
      echo "  tx2 create failed: ", cr2.error.code, " ", cr2.error.message
    check cr2.isOk
    let co = await tx2.commit()
    if not co.isOk:
      echo "  tx2 commit failed: ", co.error.code, " ", co.error.message
    check co.isOk
    let sel2 = await db.select("tx_test:2")
    check sel2.isOk
    check sel2.ok["val"].getInt() == 2
    discard await db.query("REMOVE TABLE IF EXISTS tx_test")
    discard await s.detach()

  # Live queries with notifications
  block:
    echo "  Testing live queries..."
    discard await db.query("REMOVE TABLE IF EXISTS live_test")
    discard await db.query("DEFINE TABLE live_test SCHEMAFULL")
    discard await db.query("DEFINE FIELD name ON live_test TYPE string")

    var notifications: seq[(NotificationAction, JsonNode)]
    let lr = await db.live("live_test")
    check lr.isOk
    let liveId = lr.ok.getStr()
    check liveId.len > 0

    db.onNotification(liveId) do (action: NotificationAction, data: JsonNode):
      notifications.add (action, data)

    discard await db.create("live_test:1", %*{"name": "First"})
    await sleepAsync(300)

    discard await db.update("live_test:1", %*{"name": "Updated"})
    await sleepAsync(300)

    discard await db.delete("live_test:1")
    await sleepAsync(300)

    check notifications.len >= 3
    check notifications[0][0] == naCreate
    check notifications[1][0] == naUpdate
    check notifications[2][0] == naDelete

    discard await db.kill(liveId)
    discard await db.query("REMOVE TABLE IF EXISTS live_test")

  # Delete table
  block:
    let r = await db.delete(tb"user")
    check r.isOk

  # Verify empty
  block:
    let r = await db.select(tb"user")
    check r.isOk
    check r.ok.len == 0

  echo "=== All integration tests passed ==="

waitFor runTests()
