import std/[json, asyncdispatch, tables, strutils, random]
import ./websocket, ./types

export types

proc genRequestId(): string =
  const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  result = newString(16)
  for i in 0..<16: result[i] = chars[rand(chars.len - 1)]

type
  PendingFuture = Future[SurrealResult[JsonNode]]

  Db* = ref object
    ws*: WSClient
    ns*: string
    database*: string
    pending*: TableRef[string, PendingFuture]
    liveQueries*: TableRef[string, LiveQueryHandler]
    token*: string
    logger*: Logger

  Session* = ref object
    db*: Db
    id*: UUID
    closed*: bool

  Transaction* = ref object
    db*: Db
    id*: UUID
    sessionId*: UUID
    closed*: bool

proc isClosed*(s: Session): bool = s.closed
proc isClosed*(tx: Transaction): bool = tx.closed

proc requireOpen(s: Session) =
  if s.closed: raise newErrSessionClosed()

proc requireOpen(tx: Transaction) =
  if tx.closed: raise newErrTransactionClosed()

proc dispatchNotification(db: Db, msg: JsonNode) =
  if not msg.hasKey("result"): return
  let res = msg["result"]
  if res.kind != JObject: return
  if not res.hasKey("id") or not res.hasKey("action"): return
  let liveId = res["id"].getStr("")
  let actionStr = res["action"].getStr("")
  let action =
    case actionStr
    of "CREATE": naCreate
    of "UPDATE": naUpdate
    of "DELETE": naDelete
    of "KILLED": naKilled
    else: naUpdate
  let data = if res.hasKey("result"): res["result"] else: newJNull()
  if db.liveQueries.hasKey(liveId):
    try:
      db.liveQueries[liveId](action, data)
    except:
      discard

proc listenLoop*(db: Db) {.async.} =
  while db.ws.state == wsOpen:
    try:
      let (opcode, data) = await db.ws.receivePacket()
      case opcode
      of wsText:
        let msg = parseJson(data)
        if msg.hasKey("id") and msg["id"].kind == JString:
          let id = msg["id"].getStr()
          if db.pending.hasKey(id):
            let future = db.pending[id]
            db.pending.del(id)
            if msg.hasKey("error"):
              let rpcErr = parseRpcError(msg["error"])
              future.complete(err[JsonNode](rpcErr.code, rpcErr.message, rpcErr.serverError))
            elif msg.hasKey("result"):
              future.complete(ok(msg["result"]))
            else:
              future.complete(ok(msg))
          else:
            if msg.hasKey("error"):
              db.logger.warn("Unrouted error: " & $msg["error"])
        elif msg.hasKey("result") and msg["result"].kind == JObject and
             msg["result"].hasKey("action"):
          db.dispatchNotification(msg)
        elif msg.hasKey("error"):
          db.logger.warn("Unrouted error: " & $msg["error"])
      of wsClose: db.ws.state = wsClosed; break
      of wsPing: await db.ws.sendWs("", wsPong)
      else: discard
    except WSClosedError: db.ws.state = wsClosed; break
    except: db.ws.state = wsClosed; break

proc send*(db: Db, rpcMethod: string, params: JsonNode, sessionId: UUID = UUID(""), txnId: UUID = UUID("")): Future[SurrealResult[JsonNode]] {.async.} =
  let id = genRequestId()
  var reqParams = params.copy()
  var req = %*{"id": id, "method": rpcMethod, "params": reqParams}
  if string(sessionId).len > 0:
    req["session"] = %*string(sessionId)
  if string(txnId).len > 0:
    req["txn"] = %*string(txnId)
  var future = newFuture[SurrealResult[JsonNode]]("send")
  db.pending[id] = future
  await db.ws.sendWs($req, wsText)
  return await future

proc connect*(url: string, logger: Logger = nil): Future[Db] {.async.} =
  var address = url
  if not address.endsWith("/rpc"):
    address = address.strip(chars = {'/'}) & "/rpc"
  let client = await newWsClient(address)
  client.setupPings(15.0)
  result = Db(
    ws: client,
    pending: newTable[string, PendingFuture](),
    liveQueries: newTable[string, LiveQueryHandler](),
    logger: if logger != nil: logger else: newSilentLogger()
  )
  asyncCheck result.listenLoop()

proc disconnect*(db: Db) =
  db.ws.state = wsClosed
  db.ws.closeWs()

proc isConnected*(db: Db): bool = db.ws.state == wsOpen

proc use*(db: Db, namespace, database: string): Future[SurrealResult[JsonNode]] {.async.} =
  db.ns = namespace; db.database = database
  result = await db.send("use", %*[namespace, database])

proc signin*(db: Db, user, pass: string): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("signin", %*[{ "user": user, "pass": pass }])
  if result.isOk and result.ok.kind == JString:
    db.token = result.ok.getStr()

proc signinNs*(db: Db, ns, user, pass: string): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("signin", %*[{ "ns": ns, "user": user, "pass": pass }])

proc signinDb*(db: Db, ns, database, user, pass: string): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("signin", %*[{ "ns": ns, "db": database, "user": user, "pass": pass }])

proc signinRecord*(db: Db, ns, database, access: string, params: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("signin", %*[{ "ns": ns, "db": database, "ac": access, "params": params }])

proc signup*(db: Db, ns, database, access: string, params: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("signup", %*[{ "ns": ns, "db": database, "ac": access, "params": params }])
  if result.isOk and result.ok.kind == JString:
    db.token = result.ok.getStr()

proc authenticate*(db: Db, token: string): Future[SurrealResult[JsonNode]] {.async.} =
  db.token = token
  result = await db.send("authenticate", %*[token])

proc invalidate*(db: Db): Future[SurrealResult[JsonNode]] {.async.} =
  db.token = ""
  result = await db.send("invalidate", %[])

proc info*(db: Db): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("info", %[])

proc version*(db: Db): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("version", %[])

proc setVar*(db: Db, name: string, value: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("let", %*[name, value])

proc unsetVar*(db: Db, name: string): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("unset", %*[name])

proc query*(db: Db, sql: string, vars: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  if vars.len > 0:
    result = await db.send("query", %*[sql, vars])
  else:
    result = await db.send("query", %*[sql])

proc query*(db: Db, sql: SurQL, vars: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.query(string(sql), vars)

proc select*(db: Db, thing: string): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("select", %*[thing])

proc select*(db: Db, thing: RecordId): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("select", %*[$thing])

proc select*(db: Db, thing: DbTable): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("select", %*[string(thing)])

proc create*(db: Db, thing: string, content: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("create", %*[thing, content])

proc create*(db: Db, thing: RecordId, content: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("create", %*[$thing, content])

proc insert*(db: Db, table: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("insert", %*[table, content])

proc insert*(db: Db, tbl: DbTable, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.insert(string(tbl), content)

proc insertRelation*(db: Db, table: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("insert_relation", %*[table, content])

proc update*(db: Db, thing: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("update", %*[thing, content])

proc update*(db: Db, thing: RecordId, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("update", %*[$thing, content])

proc upsert*(db: Db, thing: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("upsert", %*[thing, content])

proc upsert*(db: Db, thing: RecordId, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("upsert", %*[$thing, content])

proc merge*(db: Db, thing: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("merge", %*[thing, content])

proc merge*(db: Db, thing: RecordId, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("merge", %*[$thing, content])

proc patch*(db: Db, thing: string, patches: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("patch", %*[thing, patches])

proc delete*(db: Db, thing: string): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("delete", %*[thing])

proc delete*(db: Db, thing: RecordId): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("delete", %*[$thing])

proc delete*(db: Db, thing: DbTable): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("delete", %*[string(thing)])

proc relate*(db: Db, source: string, relation: string, target: string,
             content: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("relate", %*[source, relation, target, content])

proc run*(db: Db, fnName: string, args: JsonNode = %[]): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("run", %*[fnName, args])

proc live*(db: Db, table: string, diff: bool = false): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("live", %*[table, diff])

proc onNotification*(db: Db, liveId: string, handler: LiveQueryHandler) =
  db.liveQueries[liveId] = handler

proc offNotification*(db: Db, liveId: string) =
  db.liveQueries.del(liveId)

proc kill*(db: Db, liveId: string): Future[SurrealResult[JsonNode]] {.async.} =
  db.liveQueries.del(liveId)
  result = await db.send("kill", %*[liveId])

proc kill*(db: Db, liveId: UUID): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.kill(string(liveId))

# Transactions (legacy, on Db directly)
proc begin*(db: Db): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("begin", %[])

proc commit*(db: Db): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("commit", %[])

proc cancel*(db: Db): Future[SurrealResult[JsonNode]] {.async.} =
  result = await db.send("cancel", %[])

# Session & Interactive Transactions (SurrealDB v3+)
proc attach*(db: Db): Future[SurrealResult[Session]] {.async.} =
  let res = await db.send("attach", %[])
  if res.isOk:
    var sessionId: UUID
    if res.ok.kind == JString:
      sessionId = UUID(res.ok.getStr())
    result = ok(Session(db: db, id: sessionId, closed: false))
  else:
    result = err[Session](res.error.code, res.error.message, res.error.serverError)

proc detach*(s: Session): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  s.closed = true
  result = await s.db.send("detach", %[], sessionId = s.id)

proc ssend*(s: Session, rpcMethod: string, params: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send(rpcMethod, params, sessionId = s.id)

proc begin*(s: Session): Future[SurrealResult[Transaction]] {.async.} =
  s.requireOpen()
  let res = await s.db.send("begin", %[], sessionId = s.id)
  if res.isOk:
    var txnId: UUID
    if res.ok.kind == JString:
      txnId = UUID(res.ok.getStr())
    result = ok(Transaction(db: s.db, id: txnId, sessionId: s.id, closed: false))
  else:
    result = err[Transaction](res.error.code, res.error.message, res.error.serverError)

proc commit*(tx: Transaction): Future[SurrealResult[JsonNode]] {.async.} =
  tx.requireOpen()
  tx.closed = true
  result = await tx.db.send("commit", %[], sessionId = tx.sessionId, txnId = tx.id)

proc cancel*(tx: Transaction): Future[SurrealResult[JsonNode]] {.async.} =
  tx.requireOpen()
  tx.closed = true
  result = await tx.db.send("cancel", %[], sessionId = tx.sessionId, txnId = tx.id)

# Transaction delegates
proc query*(tx: Transaction, sql: string, vars: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  tx.requireOpen()
  result = await tx.db.send("query", if vars.len > 0: %*[sql, vars] else: %*[sql],
                            sessionId = tx.sessionId, txnId = tx.id)

proc select*(tx: Transaction, thing: string): Future[SurrealResult[JsonNode]] {.async.} =
  tx.requireOpen()
  result = await tx.db.send("select", %*[thing], sessionId = tx.sessionId, txnId = tx.id)

proc create*(tx: Transaction, thing: string, content: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  tx.requireOpen()
  result = await tx.db.send("create", %*[thing, content], sessionId = tx.sessionId, txnId = tx.id)

proc update*(tx: Transaction, thing: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  tx.requireOpen()
  result = await tx.db.send("update", %*[thing, content], sessionId = tx.sessionId, txnId = tx.id)

proc merge*(tx: Transaction, thing: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  tx.requireOpen()
  result = await tx.db.send("merge", %*[thing, content], sessionId = tx.sessionId, txnId = tx.id)

proc patch*(tx: Transaction, thing: string, patches: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  tx.requireOpen()
  result = await tx.db.send("patch", %*[thing, patches], sessionId = tx.sessionId, txnId = tx.id)

proc upsert*(tx: Transaction, thing: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  tx.requireOpen()
  result = await tx.db.send("upsert", %*[thing, content], sessionId = tx.sessionId, txnId = tx.id)

proc delete*(tx: Transaction, thing: string): Future[SurrealResult[JsonNode]] {.async.} =
  tx.requireOpen()
  result = await tx.db.send("delete", %*[thing], sessionId = tx.sessionId, txnId = tx.id)

proc insert*(tx: Transaction, table: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  tx.requireOpen()
  result = await tx.db.send("insert", %*[table, content], sessionId = tx.sessionId, txnId = tx.id)

# Session delegates
proc query*(s: Session, sql: string, vars: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("query", if vars.len > 0: %*[sql, vars] else: %*[sql], sessionId = s.id)

proc select*(s: Session, thing: string): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("select", %*[thing], sessionId = s.id)

proc create*(s: Session, thing: string, content: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("create", %*[thing, content], sessionId = s.id)

proc update*(s: Session, thing: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("update", %*[thing, content], sessionId = s.id)

proc merge*(s: Session, thing: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("merge", %*[thing, content], sessionId = s.id)

proc delete*(s: Session, thing: string): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("delete", %*[thing], sessionId = s.id)

proc insert*(s: Session, table: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("insert", %*[table, content], sessionId = s.id)

proc upsert*(s: Session, thing: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("upsert", %*[thing, content], sessionId = s.id)

proc patch*(s: Session, thing: string, patches: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("patch", %*[thing, patches], sessionId = s.id)

proc run*(s: Session, fnName: string, args: JsonNode = %[]): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("run", %*[fnName, args], sessionId = s.id)

# Signin / Signup with Refresh (SurrealDB v3+)
proc signinWithRefresh*(db: Db, authData: JsonNode): Future[SurrealResult[Tokens]] {.async.} =
  result = err[Tokens](-1, "not yet called")
  # Build params with refresh marker
  if authData.kind == JObject:
    var p = authData.copy()
    p["refresh"] = %*true
    let res = await db.send("signin", %*[p])
    if res.isOk:
      result = ok(Tokens(
        access: if res.ok.hasKey("access"): res.ok["access"].getStr() else: "",
        refresh: if res.ok.hasKey("refresh"): res.ok["refresh"].getStr() else: ""
      ))
    else:
      result = err[Tokens](res.error.code, res.error.message, res.error.serverError)

proc signupWithRefresh*(db: Db, authData: JsonNode): Future[SurrealResult[Tokens]] {.async.} =
  if authData.kind == JObject:
    var p = authData.copy()
    p["refresh"] = %*true
    let res = await db.send("signup", %*[p])
    if res.isOk:
      result = ok(Tokens(
        access: if res.ok.hasKey("access"): res.ok["access"].getStr() else: "",
        refresh: if res.ok.hasKey("refresh"): res.ok["refresh"].getStr() else: ""
      ))
    else:
      result = err[Tokens](res.error.code, res.error.message, res.error.serverError)
