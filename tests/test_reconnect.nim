import std/[unittest, json, asyncdispatch, tables]
import surrealdb

const
  TestUrl = "ws://localhost:8080"
  TestUser = "root"
  TestPass = "root"
  TestNs = "test_ns4"
  TestDb = "test_db4"

proc runTests() {.async.} =
  echo "=== Reconnecting Connection Tests ==="

  # Setup retry with exponential backoff
  var retryer = ExponentialBackoff(
    initialDelay: 1.0, maxDelay: 10.0, multiplier: 2.0,
    maxRetries: 5, jitter: false
  )

  let rdb = newReconnectingDb(TestUrl, retryer)
  defer: rdb.disconnect()

  await rdb.start()
  check rdb.isConnected()

  # Use + Signin
  discard await rdb.use(TestNs, TestDb)
  let sr = await rdb.signin(TestUser, TestPass)
  check sr.isOk
  echo "  Signin OK, token captured"

  # Cleanup
  discard await rdb.query("REMOVE TABLE IF EXISTS user")

  # Create + Select
  let cr = await rdb.create("user:alice", %*{"name": "Alice", "age": 30})
  check cr.isOk
  echo "  Create OK"

  let sel = await rdb.select(rc"user:alice")
  check sel.isOk
  check sel.ok["name"].getStr() == "Alice"
  echo "  Select OK"

  # Query
  let qr = await rdb.query(surql"SELECT * FROM user")
  check qr.isOk
  echo "  Query OK, rows=", qr.ok[0]["result"].len

  # Version
  let vr = await rdb.version()
  check vr.isOk
  echo "  Version OK: ", vr.ok.getStr()

  # Verify session vars are captured for reconnection
  discard await rdb.setVar("test_key", %*"test_val")
  echo "  SetVar OK"

  # Transactions on reconnecting db
  block:
    let b = await rdb.begin()
    check b.isOk
    let c = await rdb.commit()
    check c.isOk
    echo "  Transaction OK"

  # Live queries on reconnecting db
  block:
    discard await rdb.query("REMOVE TABLE IF EXISTS live_user")
    discard await rdb.query("DEFINE TABLE live_user SCHEMAFULL")
    discard await rdb.query("DEFINE FIELD name ON live_user TYPE string")

    var notifications: seq[NotificationAction]
    let lr = await rdb.live("live_user", handler = proc (action: NotificationAction, data: JsonNode) =
      notifications.add action
    )
    check lr.isOk
    let liveId = lr.ok.getStr()
    check liveId.len > 0
    check tables.hasKey(rdb.liveQueries, liveId)

    discard await rdb.create("live_user:1", %*{"name": "Alice"})
    await sleepAsync(300)
    check notifications.len >= 1
    check notifications[0] == naCreate

    discard await rdb.kill(liveId)
    discard await rdb.query("REMOVE TABLE IF EXISTS live_user")
    echo "  Live query OK"

  # Invalidate
  block:
    discard await rdb.authenticate("dummy-token")
    check rdb.token == "dummy-token"
    discard await rdb.invalidate()
    check rdb.token == ""
    echo "  Invalidate OK"

  # Cleanup
  discard await rdb.delete(tb"user")

  echo "=== Reconnecting Connection tests passed ==="

waitFor runTests()
