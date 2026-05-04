import std/[unittest, json, math, strutils, options]
import surrealdb

suite "Types & Macros":
  test "rc macro creates RecordId":
    let rid = rc"user:alice"
    check rid.table == "user"
    check rid.id == %*"alice"
    check $rid == "user:alice"

  test "record proc parses string":
    let rid = record("user:bob")
    check rid.table == "user"
    check rid.id == %*"bob"

  test "record proc with complex id":
    let rid = record("user", %*[1, 2, 3])
    check rid.table == "user"
    check rid.id == %*[1, 2, 3]
    check $rid == "user:[1,2,3]"

  test "record proc rejects invalid":
    expect ValueError:
      discard record("invalid")

  test "RecordId escaping with special characters":
    let rid = record("user", %*"hello world")
    check $rid == "user:⟨hello world⟩"

  test "RecordId escaping with numeric-only id":
    let rid = record("user", %*"12345")
    check $rid == "user:⟨12345⟩"

  test "RecordId no escaping for simple ids":
    let rid = rc"user:alice"
    check $rid == "user:alice"

  test "RecordId complex id (array)":
    let rid = record("user", %*["a", "b", 3])
    check $rid == "user:[\"a\",\"b\",3]"

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

  test "RecordId surrealString":
    check surrealString(rc"user:alice") == "r'user:alice'"

  test "UUID generation":
    let u1 = newUuid()
    let u2 = newUuid()
    check $u1 != $u2
    check ($u1).len == 32

  test "CustomNil / None":
    check %%None == newJNull()

  test "QueryError":
    let qe = QueryError(message: "syntax error")
    check $qe == "syntax error"

  test "Range types":
    let r = Range[int](
      beginBound: %%BoundIncluded[int](value: 1),
      endBound: %%BoundExcluded[int](value: 10)
    )
    let j = %%r
    check j["begin"]["incl"].getInt() == 1
    check j["end"]["excl"].getInt() == 10

  test "BoundIncluded serialization":
    let b = BoundIncluded[string](value: "start")
    check %%b == %*{"incl": "start"}

  test "BoundExcluded serialization":
    let b = BoundExcluded[float](value: 3.14)
    check %%b == %*{"excl": 3.14}

  test "RecordRangeID":
    let rr = RecordRangeID[int](
      table: tb"items",
      rangeVal: Range[int](
        beginBound: %%BoundIncluded[int](value: 0),
        endBound: %%BoundExcluded[int](value: 100)
      )
    )
    let j = %%rr
    check j["table"].getStr() == "items"

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

  test "isRetriable":
    let retriable = RpcError(code: -1, message: "timeout")
    check isRetriable(retriable)
    let nonRetriable = RpcError(code: -1, message: "parse", serverError: ServerError(kind: ekParse))
    check not isRetriable(nonRetriable)
    let invalidData = RpcError(code: -1, message: "bad data", serverError: ServerError(kind: ekInvalidData))
    check not isRetriable(invalidData)

  test "isQueryError":
    let parseErr = RpcError(code: -1, message: "parse", serverError: ServerError(kind: ekParse))
    check isQueryError(parseErr)
    let authErr = RpcError(code: -1, message: "auth", serverError: ServerError(kind: ekAuth))
    check not isQueryError(authErr)

suite "SurrealString Methods":
  test "UUID surrealString":
    let u = UUID("550e8400-e29b-41d4-a716-446655440000")
    check surrealString(u) == "550e8400-e29b-41d4-a716-446655440000"

  test "Duration surrealString":
    check surrealString(Duration("1w2d")) == "1w2d"

  test "Decimal surrealString":
    check surrealString(Decimal("3.14159")) == "3.14159"

  test "SurNone surrealString":
    check surrealString(SurNone("")) == "NONE"

  test "SurTable surrealString":
    check surrealString(SurTable("users")) == "<table> users"

  test "GeometryPoint surrealString":
    let gp = GeometryPoint(longitude: 1.0, latitude: 2.0)
    check surrealString(gp).contains("Point")
    check surrealString(gp).contains("1.0")

  test "GeometryLine surrealString":
    let gl = @[GeometryPoint(longitude: 1.0, latitude: 2.0), GeometryPoint(longitude: 3.0, latitude: 4.0)]
    check surrealString(gl).contains("LineString")

  test "GeometryPolygon surrealString":
    let gp = @[@[GeometryPoint(longitude: 0.0, latitude: 0.0), GeometryPoint(longitude: 1.0, latitude: 0.0),
                GeometryPoint(longitude: 1.0, latitude: 1.0), GeometryPoint(longitude: 0.0, latitude: 0.0)]]
    check surrealString(gp).contains("Polygon")

  test "BoundIncluded surrealString":
    check surrealString(BoundIncluded[int](value: 5)) == "5..="

  test "BoundExcluded surrealString":
    check surrealString(BoundExcluded[int](value: 10)) == "10..<"

  test "Range surrealString":
    let r = Range[int](
      beginBound: %%BoundIncluded[int](value: 1),
      endBound: %%BoundExcluded[int](value: 10)
    )
    check surrealString(r).contains("..")

  test "RecordRangeID surrealString":
    let rr = RecordRangeID[int](
      table: tb"items",
      rangeVal: Range[int](
        beginBound: %%BoundIncluded[int](value: 0),
        endBound: %%BoundExcluded[int](value: 100)
      )
    )
    check surrealString(rr).contains("items:")

  test "PatchData surrealString":
    let pd = PatchData(op: "replace", path: "/name", value: %"new")
    check surrealString(pd) == "replace /name \"new\""

  test "Auth surrealString":
    let a = Auth(namespace: some("ns"), database: some("db"), username: some("root"))
    let s = surrealString(a)
    check s.contains("ns: ns")
    check s.contains("db: db")
    check s.contains("user: root")

  test "Relationship surrealString":
    let rel = Relationship(
      inRec: rc"user:alice",
      outRec: rc"user:bob",
      relation: dbTable("knows"),
      data: newJObject()
    )
    let s = surrealString(rel)
    check s.contains("user:alice")
    check s.contains("knows")
    check s.contains("user:bob")

  test "Tokens surrealString":
    let t = Tokens(access: "abc123def", refresh: "xyz789ghi")
    let s = surrealString(t)
    check s.contains("Tokens")
    check s.contains("abc123")

  test "GeometryMultiPoint JSON serialization":
    let gm = GeometryMultiPoint(@[GeometryPoint(longitude: 1.0, latitude: 2.0)])
    let j = %%gm
    check j["type"].getStr() == "MultiPoint"

  test "GeometryMultiLine JSON serialization":
    let gm = GeometryMultiLine(@[@[GeometryPoint(longitude: 1.0, latitude: 2.0)]])
    let j = %%gm
    check j["type"].getStr() == "MultiLineString"

  test "GeometryMultiPolygon JSON serialization":
    let gm = GeometryMultiPolygon(@[@[@[GeometryPoint(longitude: 0.0, latitude: 0.0)]]])
    let j = %%gm
    check j["type"].getStr() == "MultiPolygon"

  test "GeometryCollection JSON serialization":
    let gc = GeometryCollection(geometries: %*[{"type": "Point"}])
    let j = %%gc
    check j["type"].getStr() == "GeometryCollection"

suite "Version Parsing":
  test "parseVersionData from map":
    let j = %*{"version": "3.0.0", "build": "20240101", "timestamp": "2024-01-01T00:00:00Z"}
    let v = parseVersionData(j)
    check v.version == "3.0.0"
    check v.build == "20240101"
    check v.timestamp == "2024-01-01T00:00:00Z"

  test "parseVersionData from string":
    let j = %"surrealdb-2.1.0"
    let v = parseVersionData(j)
    check v.version == "2.1.0"
    check v.build == ""
    check v.timestamp == ""

  test "parseVersionData from plain string":
    let j = %"3.0.0-alpha"
    let v = parseVersionData(j)
    check v.version == "3.0.0-alpha"

  test "parseVersionData from nil":
    let v = parseVersionData(newJNull())
    check v.version == "unknown"

suite "QueryStmt":
  test "getResult ok":
    var qs = QueryStmt(
      sql: "SELECT * FROM user",
      vars: newJObject(),
      result: QueryResult[JsonNode](status: "OK", time: "1ms", result: %*[{"name": "Alice"}])
    )
    let rows = qs.getResult(seq[JsonNode])
    check rows.len == 1
    check rows[0]["name"].getStr() == "Alice"

  test "getResult err":
    var qs = QueryStmt(
      sql: "INVALID SQL",
      vars: newJObject(),
      result: QueryResult[JsonNode](
        status: "ERR",
        time: "0ms",
        result: %"Parse error",
        error: ServerError(code: 0, message: "Parse error", kind: ekParse)
      )
    )
    expect CatchableError:
      discard qs.getResult(seq[JsonNode])

  test "hasResult":
    let ok = QueryStmt(result: QueryResult[JsonNode](status: "OK"))
    check ok.hasResult()
    let err = QueryStmt(result: QueryResult[JsonNode](status: "ERR"))
    check not err.hasResult()

  test "getError":
    let se = ServerError(code: 0, message: "bad query", kind: ekParse)
    let qs = QueryStmt(result: QueryResult[JsonNode](status: "ERR", error: se))
    check qs.getError() != nil
    check qs.getError().message == "bad query"
    check qs.getError().kind == ekParse
