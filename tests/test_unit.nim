import std/[unittest, json, math]
import surrealdb

suite "Types & Macros":
  test "rc macro creates RecordId":
    let rid = rc"user:alice"
    check rid.table == "user"
    check rid.id == "alice"
    check $rid == "user:alice"

  test "record proc parses string":
    let rid = record("user:bob")
    check rid.table == "user"
    check rid.id == "bob"

  test "record proc rejects invalid":
    expect ValueError:
      discard record("invalid")

  test "tb macro creates DbTable":
    let t = tb"users"
    check $t == "users"

  test "surql macro creates SurQL":
    let q = surql"SELECT * FROM users"
    check $q == "SELECT * FROM users"

  test "RecordId JSON serialization":
    let rid = rc"person:john"
    let j = %%rid
    check j["tb"].getStr() == "person"
    check j["id"].getStr() == "john"

  test "RecordId equality":
    check rc"a:1" == rc"a:1"
    check rc"a:1" != rc"a:2"
    check rc"a:1" != rc"b:1"

  test "UUID generation":
    let u1 = newUuid()
    let u2 = newUuid()
    check $u1 != $u2
    check ($u1).len == 32

suite "SurrealResult":
  test "ok result":
    let r = ok(42)
    check r.isOk
    check r.ok == 42

  test "err result":
    let r = err[int](-32000, "something failed")
    check not r.isOk
    check r.error.code == -32000
    check r.error.message == "something failed"

  test "err result with server error":
    let se = ServerError(code: 403, message: "denied", kind: ekPermission)
    let r = err[int](-32000, "failed", se)
    check not r.isOk
    check r.error.serverError != nil
    check r.error.serverError.kind == ekPermission

suite "Retry Logic":
  test "FixedDelay basic":
    let r = FixedDelay(delay: 2.0, maxRetries: 3)
    check r.shouldRetry()
    check r.nextDelay() == 2.0
    check r.nextDelay() == 2.0
    check r.nextDelay() == 2.0
    check not r.shouldRetry()

  test "ExponentialBackoff no jitter":
    let r = ExponentialBackoff(
      initialDelay: 1.0, maxDelay: 10.0, multiplier: 2.0,
      maxRetries: 4, jitter: false
    )
    check r.shouldRetry()
    check r.nextDelay() == 1.0
    check r.nextDelay() == 2.0
    check r.nextDelay() == 4.0
    check r.nextDelay() == 8.0
    check not r.shouldRetry()

  test "ExponentialBackoff with jitter":
    let r = ExponentialBackoff(
      initialDelay: 1.0, maxDelay: 10.0, multiplier: 2.0,
      maxRetries: 10, jitter: true
    )
    let d1 = r.nextDelay()
    let d2 = r.nextDelay()
    check d1 > 0
    check d2 > 0
    # Jitter means delays may differ from exact exponential

  test "ExponentialBackoff maxDelay cap":
    let r = ExponentialBackoff(
      initialDelay: 5.0, maxDelay: 8.0, multiplier: 2.0,
      maxRetries: 10, jitter: false
    )
    check r.nextDelay() == 5.0
    check r.nextDelay() == 8.0
    check r.nextDelay() == 8.0

  test "unlimited retries":
    let r = FixedDelay(delay: 1.0, maxRetries: 0)
    for i in 1..100:
      check r.shouldRetry()
      discard r.nextDelay()

suite "Error Parsing":
  test "parse simple server error":
    let j = %*{ "code": 403, "message": "Access denied", "kind": "Permission" }
    let e = parseServerError(j)
    check e != nil
    check e.code == 403
    check e.message == "Access denied"
    check e.kind == ekPermission

  test "parse nested cause":
    let j = %*{
      "code": 500,
      "message": "Top",
      "kind": "Internal",
      "cause": {
        "code": 404,
        "message": "Not there",
        "kind": "NotFound"
      }
    }
    let e = parseServerError(j)
    check e != nil
    check e.cause != nil
    check e.cause.code == 404
    check e.cause.kind == ekNotFound

  test "parse RPC error with data":
    let j = %*{
      "code": -32000,
      "message": "db error",
      "data": { "code": 123, "message": "detail", "kind": "Auth" }
    }
    let e = parseRpcError(j)
    check e.code == -32000
    check e.message == "db error"
    check e.serverError != nil
    check e.serverError.kind == ekAuth

  test "parse RPC error with nested error":
    let j = %*{
      "code": -32000,
      "message": "db error",
      "error": { "code": 456, "message": "nested", "kind": "Timeout" }
    }
    let e = parseRpcError(j)
    check e.serverError != nil
    check e.serverError.kind == ekTimeout

  test "parse unknown kind":
    let j = %*{ "kind": "WeirdKind" }
    let e = parseServerError(j)
    check e.kind == ekUnknown

  test "parse nil":
    check parseServerError(newJNull()) == nil
    check parseServerError(newJObject()) != nil
