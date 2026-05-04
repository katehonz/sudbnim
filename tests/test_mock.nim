import std/[unittest, json, asyncdispatch, asyncnet, strutils, tables, hashes]
import surrealdb

type
  MockClient = ref object
    socket: AsyncSocket
    closed: bool
    requests: seq[JsonNode]

proc sendWsFrame(sock: AsyncSocket; data: string; opcode: uint8 = 1) {.async.} =
  var frame = newString(2)
  frame[0] = char(opcode or 0x80)
  if data.len <= 125:
    frame[1] = char(data.len)
  elif data.len <= 0xffff:
    frame[1] = char(126)
    frame.add char((data.len shr 8) and 0xFF)
    frame.add char(data.len and 0xFF)
  else:
    raise newException(IOError, "payload too large")
  frame.add data
  await sock.send(frame)

proc recvWsFrame(sock: AsyncSocket): Future[(uint8, string)] {.async.} =
  var hdr = await sock.recv(2)
  if hdr.len != 2: raise newException(IOError, "short header")
  let b0 = hdr[0].uint8
  let b1 = hdr[1].uint8
  let opcode = b0 and 0x0F
  var len = (b1 and 0x7F).int
  if len == 126:
    var e = await sock.recv(2)
    len = (e[0].uint8.int shl 8) or e[1].uint8.int
  elif len == 127:
    raise newException(IOError, "64-bit len not supported")
  var mk = ""
  if (b1 and 0x80) != 0:
    mk = await sock.recv(4)
    if mk.len != 4: raise newException(IOError, "short mask")
  var data = await sock.recv(len)
  if data.len != len: raise newException(IOError, "short data")
  if mk.len == 4:
    for i in 0..<data.len: data[i] = (data[i].uint8 xor mk[i mod 4].uint8).char
  result = (opcode, data)

proc handleMockClient(client: MockClient) {.async.} =
  var req = ""
  var gotUpgrade = false
  while true:
    let line = await client.socket.recvLine()
    if line.len == 0:
      if not gotUpgrade: return
      break
    if line == "\r\n": break
    req.add line & "\n"
    if line.toLowerAscii.startsWith("sec-websocket-key:"):
      gotUpgrade = true

  if not gotUpgrade:
    await client.socket.send("HTTP/1.1 400 Bad Request\r\n\r\n")
    return

  let resp = "HTTP/1.1 101 Switching Protocols\r\n" &
             "Upgrade: websocket\r\n" &
             "Connection: Upgrade\r\n" &
             "Sec-WebSocket-Accept: dummyaccept\r\n\r\n"
  await client.socket.send(resp)

  while not client.closed:
    try:
      let (opcode, data) = await recvWsFrame(client.socket)
      case opcode
      of 0x1: # text
        let j = parseJson(data)
        client.requests.add j
        if j.hasKey("id") and j.hasKey("method"):
          let id = j["id"].getStr("")
          let meth = j["method"].getStr("")
          var response: JsonNode
          case meth
          of "use":
            response = %*{"id": id, "result": newJNull()}
          of "signin":
            response = %*{"id": id, "result": "mock-token-12345"}
          of "version":
            response = %*{"id": id, "result": "surrealdb-2.1.0"}
          of "query":
            response = %*{"id": id, "result": [{"status": "OK", "time": "1ms", "result": [{"name": "Alice"}]}]}
          of "select":
            response = %*{"id": id, "result": {"id": "user:alice", "name": "Alice"}}
          of "create":
            response = %*{"id": id, "result": {"id": "user:alice", "name": "Alice", "age": 30}}
          of "update":
            response = %*{"id": id, "result": {"id": "user:alice", "name": "Updated"}}
          of "delete":
            response = %*{"id": id, "result": newJNull()}
          of "live":
            response = %*{"id": id, "result": "live-query-uuid-1"}
          of "kill":
            response = %*{"id": id, "result": newJNull()}
          of "begin":
            response = %*{"id": id, "result": true}
          of "commit":
            response = %*{"id": id, "result": true}
          of "cancel":
            response = %*{"id": id, "result": true}
          of "info":
            response = %*{"id": id, "result": {"user": "root"}}
          of "let":
            response = %*{"id": id, "result": newJNull()}
          of "unset":
            response = %*{"id": id, "result": newJNull()}
          of "merge":
            response = %*{"id": id, "result": {"id": "user:alice", "email": "a@b.com"}}
          of "upsert":
            response = %*{"id": id, "result": {"id": "user:ups1", "val": 2}}
          of "patch":
            response = %*{"id": id, "result": {"id": "user:alice", "name": "Patched"}}
          of "relate":
            response = %*{"id": id, "result": {"id": "likes:1", "in": "user:alice", "out": "user:bob"}}
          of "insert":
            response = %*{"id": id, "result": [{"id": "user:charlie"}, {"id": "user:diana"}]}
          of "insert_relation":
            response = %*{"id": id, "result": {"id": "rel:1"}}
          of "run":
            response = %*{"id": id, "result": 42}
          of "authenticate", "invalidate", "signup":
            response = %*{"id": id, "result": newJNull()}
          of "attach":
            response = %*{"id": id, "result": "session-uuid-001"}
          of "detach":
            response = %*{"id": id, "result": newJNull()}
          else:
            response = %*{"id": id, "error": {"code": -32601, "message": "Method not found: " & meth}}
          await sendWsFrame(client.socket, $response)
      of 0x9: # ping
        await sendWsFrame(client.socket, "", 0xA)
      of 0x8: # close
        break
      else:
        discard
    except:
      break

type
  MockSurrealDB = ref object
    server: AsyncSocket
    port: int
    clients: seq[MockClient]

proc newMockSurrealDB(): MockSurrealDB =
  result = MockSurrealDB(clients: @[])
  result.server = newAsyncSocket()
  result.server.setSockOpt(OptReuseAddr, true)
  result.server.bindAddr(Port(0), "127.0.0.1")
  result.port = result.server.getLocalAddr()[1].int
  result.server.listen()

  proc acceptLoop(ms: MockSurrealDB) {.async.} =
    while true:
      try:
        let sock = await ms.server.accept()
        let client = MockClient(socket: sock, closed: false, requests: @[])
        ms.clients.add client
        asyncCheck handleMockClient(client)
      except:
        break
  asyncCheck acceptLoop(result)

proc stop(ms: MockSurrealDB) =
  for c in ms.clients:
    c.closed = true
    try: c.socket.close() except: discard
  try: ms.server.close() except: discard

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "Mock Server Connection":
  test "connect and version":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    check db.isConnected()
    let r = waitFor db.version()
    check r.isOk
    check r.ok.getStr() == "surrealdb-2.1.0"
    db.disconnect()

  test "signin captures token":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let r = waitFor db.signin("root", "root")
    check r.isOk
    check r.ok.getStr() == "mock-token-12345"
    check db.token == "mock-token-12345"
    db.disconnect()

  test "use namespace and database":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let r = waitFor db.use("test", "db")
    check r.isOk
    check db.ns == "test"
    check db.database == "db"
    db.disconnect()

  test "select by string":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let r = waitFor db.select("user:alice")
    check r.isOk
    check r.ok["name"].getStr() == "Alice"
    db.disconnect()

  test "select by RecordId":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let r = waitFor db.select(rc"user:alice")
    check r.isOk
    db.disconnect()

  test "select by DbTable":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let r = waitFor db.select(tb"user")
    check r.isOk
    db.disconnect()

  test "create":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let r = waitFor db.create("user:alice", %*{"name": "Alice", "age": 30})
    check r.isOk
    check r.ok["age"].getInt() == 30
    db.disconnect()

  test "update":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let r = waitFor db.update("user:alice", %*{"name": "Updated"})
    check r.isOk
    check r.ok["name"].getStr() == "Updated"
    db.disconnect()

  test "merge":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let r = waitFor db.merge("user:alice", %*{"email": "a@b.com"})
    check r.isOk
    check r.ok["email"].getStr() == "a@b.com"
    db.disconnect()

  test "upsert":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let r = waitFor db.upsert("user:ups1", %*{"val": 2})
    check r.isOk
    check r.ok["val"].getInt() == 2
    db.disconnect()

  test "delete":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let r = waitFor db.delete("user:alice")
    check r.isOk
    db.disconnect()

  test "query":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let r = waitFor db.query(surql"SELECT * FROM user")
    check r.isOk
    check r.ok[0]["result"][0]["name"].getStr() == "Alice"
    db.disconnect()

  test "query with vars":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let r = waitFor db.query("SELECT * FROM user WHERE age > $min", %*{"min": 20})
    check r.isOk
    db.disconnect()

  test "insert":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let r = waitFor db.insert("user", %[%*{"name": "Charlie"}, %*{"name": "Diana"}])
    check r.isOk
    check r.ok.len == 2
    db.disconnect()

  test "insertRelation":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let r = waitFor db.insertRelation("likes", %*{"in": "user:alice", "out": "user:bob"})
    check r.isOk
    db.disconnect()

  test "relate":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let r = waitFor db.relate("user:alice", "likes", "user:bob")
    check r.isOk
    db.disconnect()

  test "patch":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let r = waitFor db.patch("user:alice", %*[{"op": "replace", "path": "/name", "value": "Patched"}])
    check r.isOk
    db.disconnect()

  test "run":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let r = waitFor db.run("my_fn", %*{"a": 1})
    check r.isOk
    check r.ok.getInt() == 42
    db.disconnect()

  test "info":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let r = waitFor db.info()
    check r.isOk
    check r.ok["user"].getStr() == "root"
    db.disconnect()

  test "let/unset":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    check (waitFor db.setVar("x", %*42)).isOk
    check (waitFor db.unsetVar("x")).isOk
    db.disconnect()

  test "authenticate and invalidate":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    check (waitFor db.authenticate("tok")).isOk
    check db.token == "tok"
    check (waitFor db.invalidate()).isOk
    check db.token == ""
    db.disconnect()

  test "begin/commit/cancel":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    check (waitFor db.begin()).isOk
    check (waitFor db.commit()).isOk
    check (waitFor db.cancel()).isOk
    db.disconnect()

  test "live and kill with notifications":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let r = waitFor db.live("user")
    check r.isOk
    let liveId = r.ok.getStr()
    check liveId.len > 0
    check db.liveQueries.len == 0

    var gotNotif = false
    db.onNotification(liveId) do (action: NotificationAction, data: JsonNode):
      gotNotif = true
    check db.liveQueries.hasKey(liveId)

    check mock.clients.len > 0
    waitFor sendWsFrame(mock.clients[^1].socket, $ %*{"result": {"action": "CREATE", "id": liveId, "result": {"name": "Bob"}}}, 0x1)
    waitFor sleepAsync(200)
    check gotNotif

    let kr = waitFor db.kill(liveId)
    check kr.isOk
    check not db.liveQueries.hasKey(liveId)
    db.disconnect()

  test "rpc error parsing":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let r = waitFor db.send("nonexistent", %[])
    check not r.isOk
    check r.error.code == -32601
    db.disconnect()

suite "Mock ReconnectingDb":
  test "live query registration on ReconnectingDb":
    var mock = newMockSurrealDB()
    defer: mock.stop()

    let rdb = newReconnectingDb("ws://127.0.0.1:" & $mock.port)
    waitFor rdb.start()
    check rdb.isConnected()

    var gotNotif = false
    let r = waitFor rdb.live("user", handler = proc (action: NotificationAction, data: JsonNode) =
      gotNotif = true
    )
    check r.isOk
    let liveId = r.ok.getStr()
    check rdb.liveQueries.hasKey(liveId)

    check mock.clients.len > 0
    waitFor sendWsFrame(mock.clients[^1].socket, $ %*{"result": {"action": "UPDATE", "id": liveId, "result": {}}}, 0x1)
    waitFor sleepAsync(200)
    check gotNotif

    rdb.disconnect()

suite "Session Auth & Delegates":
  test "Session signin":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let sessRes = waitFor db.attach()
    check sessRes.isOk
    let s = sessRes.ok
    let r = waitFor s.signin("root", "root")
    check r.isOk
    check r.ok.getStr() == "mock-token-12345"
    check db.token == "mock-token-12345"
    discard waitFor s.detach()
    db.disconnect()

  test "Session authenticate and invalidate":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let sessRes = waitFor db.attach()
    check sessRes.isOk
    let s = sessRes.ok
    check (waitFor s.authenticate("tok")).isOk
    check db.token == "tok"
    check (waitFor s.invalidate()).isOk
    check db.token == ""
    discard waitFor s.detach()
    db.disconnect()

  test "Session relate":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let sessRes = waitFor db.attach()
    check sessRes.isOk
    let s = sessRes.ok
    let r = waitFor s.relate("user:alice", "likes", "user:bob")
    check r.isOk
    discard waitFor s.detach()
    db.disconnect()

  test "Session insertRelation":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let sessRes = waitFor db.attach()
    check sessRes.isOk
    let s = sessRes.ok
    let r = waitFor s.insertRelation("likes", %*{"in": "user:alice", "out": "user:bob"})
    check r.isOk
    discard waitFor s.detach()
    db.disconnect()

  test "Session select RecordId and DbTable":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let sessRes = waitFor db.attach()
    check sessRes.isOk
    let s = sessRes.ok
    let r1 = waitFor s.select(rc"user:alice")
    check r1.isOk
    let r2 = waitFor s.select(tb"user")
    check r2.isOk
    discard waitFor s.detach()
    db.disconnect()

  test "Session create RecordId":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let sessRes = waitFor db.attach()
    check sessRes.isOk
    let s = sessRes.ok
    let r = waitFor s.create(rc"user:alice", %*{"name": "Alice"})
    check r.isOk
    discard waitFor s.detach()
    db.disconnect()

  test "Transaction relate":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let sessRes = waitFor db.attach()
    check sessRes.isOk
    let s = sessRes.ok
    let txRes = waitFor s.begin()
    check txRes.isOk
    let tx = txRes.ok
    let r = waitFor tx.relate("user:alice", "likes", "user:bob")
    check r.isOk
    discard waitFor tx.commit()
    discard waitFor s.detach()
    db.disconnect()

  test "Transaction insertRelation":
    var mock = newMockSurrealDB()
    defer: mock.stop()
    let db = waitFor connect("ws://127.0.0.1:" & $mock.port)
    let sessRes = waitFor db.attach()
    check sessRes.isOk
    let s = sessRes.ok
    let txRes = waitFor s.begin()
    check txRes.isOk
    let tx = txRes.ok
    let r = waitFor tx.insertRelation("likes", %*{"in": "user:alice", "out": "user:bob"})
    check r.isOk
    discard waitFor tx.commit()
    discard waitFor s.detach()
    db.disconnect()
