import std/[json, asyncdispatch, tables, strutils, random, jsonutils]
import ./websocket, ./types, ./codec

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
    codec*: Codec

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
      var msg: JsonNode
      case opcode
      of wsText:
        msg = parseJson(data)
      of wsBinary:
        if not db.codec.isCbor:
          db.logger.warn("Received binary frame but codec is not CBOR, ignoring")
          continue
        msg = db.codec.unmarshalResponse(data)
      of wsClose: db.ws.state = wsClosed; break
      of wsPing: await db.ws.sendWs("", wsPong); continue
      else: continue
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
    except WSClosedError: db.ws.state = wsClosed; break
    except: db.ws.state = wsClosed; break

proc send*(db: Db, rpcMethod: string, params: JsonNode, sessionId: UUID = UUID(""), txnId: UUID = UUID("")): Future[SurrealResult[JsonNode]] {.async.} =
  let id = genRequestId()
  var sid = string(sessionId)
  var tid = string(txnId)
  let wireData = db.codec.marshalRequest(id, rpcMethod, params, sid, tid)
  let opcode = if db.codec.isCbor: wsBinary else: wsText
  var future = newFuture[SurrealResult[JsonNode]]("send")
  db.pending[id] = future
  await db.ws.sendWs(wireData, opcode)
  return await future

proc connect*(url: string, logger: Logger = nil, codec: Codec = nil): Future[Db] {.async.} =
  var address = url
  if not address.endsWith("/rpc"):
    address = address.strip(chars = {'/'}) & "/rpc"
  let client = await newWsClient(address)
  client.setupPings(15.0)
  let c = if codec != nil: codec else: newJsonCodec()
  result = Db(
    ws: client,
    pending: newTable[string, PendingFuture](),
    liveQueries: newTable[string, LiveQueryHandler](),
    logger: if logger != nil: logger else: newSilentLogger(),
    codec: c
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

proc queryRaw*(db: Db, queries: var seq[QueryStmt]): Future[SurrealResult[JsonNode]] {.async.} =
  var sql = ""
  var vars = newJObject()
  for q in queries.mitems:
    if sql.len > 0: sql.add(" ")
    sql.add(q.sql)
    sql.add(";")
    for k, v in q.vars:
      vars[k] = v
  if sql.len == 0:
    return err[JsonNode](-1, "no query to run")
  let res = await db.query(sql, vars)
  if not res.isOk:
    return res
  if res.ok.kind == JArray:
    for i in 0..<min(queries.len, res.ok.len):
      queries[i].result = jsonTo(res.ok[i], QueryResult[JsonNode])
      if queries[i].result.status == "ERR" and queries[i].result.error == nil:
        let raw = queries[i].result.result
        if raw != nil and raw.kind == JObject:
          queries[i].result.error = parseServerError(raw)
        elif raw != nil and raw.kind == JString:
          queries[i].result.error = ServerError(code: 0, message: raw.getStr(), kind: ekUnknown)
  result = res

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
  let sessionId = newUuid()
  let res = await db.send("attach", %[], sessionId = sessionId)
  if res.isOk:
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
  result = await tx.db.send("commit", %*[string(tx.id)], sessionId = tx.sessionId)

proc cancel*(tx: Transaction): Future[SurrealResult[JsonNode]] {.async.} =
  tx.requireOpen()
  tx.closed = true
  result = await tx.db.send("cancel", %*[string(tx.id)], sessionId = tx.sessionId)

# Transaction delegates
proc query*(tx: Transaction, sql: string, vars: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  tx.requireOpen()
  result = await tx.db.send("query", if vars.len > 0: %*[sql, vars] else: %*[sql],
                            sessionId = tx.sessionId, txnId = tx.id)

proc query*(tx: Transaction, sql: SurQL, vars: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  result = await tx.query(string(sql), vars)

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

proc relate*(tx: Transaction, source: string, relation: string, target: string,
             content: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  tx.requireOpen()
  result = await tx.db.send("relate", %*[source, relation, target, content], sessionId = tx.sessionId, txnId = tx.id)

proc insertRelation*(tx: Transaction, table: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  tx.requireOpen()
  result = await tx.db.send("insert_relation", %*[table, content], sessionId = tx.sessionId, txnId = tx.id)

# Session delegates
proc query*(s: Session, sql: string, vars: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("query", if vars.len > 0: %*[sql, vars] else: %*[sql], sessionId = s.id)

proc query*(s: Session, sql: SurQL, vars: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  result = await s.query(string(sql), vars)

proc select*(s: Session, thing: string): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("select", %*[thing], sessionId = s.id)

proc select*(s: Session, thing: RecordId): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("select", %*[$thing], sessionId = s.id)

proc select*(s: Session, thing: DbTable): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("select", %*[string(thing)], sessionId = s.id)

proc create*(s: Session, thing: string, content: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("create", %*[thing, content], sessionId = s.id)

proc create*(s: Session, thing: RecordId, content: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("create", %*[$thing, content], sessionId = s.id)

proc update*(s: Session, thing: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("update", %*[thing, content], sessionId = s.id)

proc update*(s: Session, thing: RecordId, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("update", %*[$thing, content], sessionId = s.id)

proc merge*(s: Session, thing: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("merge", %*[thing, content], sessionId = s.id)

proc merge*(s: Session, thing: RecordId, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("merge", %*[$thing, content], sessionId = s.id)

proc delete*(s: Session, thing: string): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("delete", %*[thing], sessionId = s.id)

proc delete*(s: Session, thing: RecordId): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("delete", %*[$thing], sessionId = s.id)

proc delete*(s: Session, thing: DbTable): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("delete", %*[string(thing)], sessionId = s.id)

proc insert*(s: Session, table: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("insert", %*[table, content], sessionId = s.id)

proc insert*(s: Session, tbl: DbTable, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  result = await s.insert(string(tbl), content)

proc upsert*(s: Session, thing: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("upsert", %*[thing, content], sessionId = s.id)

proc upsert*(s: Session, thing: RecordId, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("upsert", %*[$thing, content], sessionId = s.id)

proc patch*(s: Session, thing: string, patches: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("patch", %*[thing, patches], sessionId = s.id)

proc patch*(s: Session, thing: RecordId, patches: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("patch", %*[$thing, patches], sessionId = s.id)

proc run*(s: Session, fnName: string, args: JsonNode = %[]): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("run", %*[fnName, args], sessionId = s.id)

proc use*(s: Session, ns, database: string): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("use", %*[ns, database], sessionId = s.id)

proc setVar*(s: Session, name: string, value: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("let", %*[name, value], sessionId = s.id)

proc unsetVar*(s: Session, name: string): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("unset", %*[name], sessionId = s.id)

proc info*(s: Session): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("info", %[], sessionId = s.id)

proc version*(s: Session): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.version()

proc live*(s: Session, table: string, diff: bool = false): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("live", %*[table, diff], sessionId = s.id)

proc kill*(s: Session, liveId: string): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("kill", %*[liveId], sessionId = s.id)

proc kill*(s: Session, liveId: UUID): Future[SurrealResult[JsonNode]] {.async.} =
  result = await s.kill(string(liveId))

proc onNotification*(s: Session, liveId: string, handler: LiveQueryHandler) =
  ## Register a notification handler for a live query on this session.
  s.db.liveQueries[liveId] = handler

proc offNotification*(s: Session, liveId: string) =
  ## Unregister a notification handler for a live query on this session.
  s.db.liveQueries.del(liveId)

proc signin*(s: Session, user, pass: string): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("signin", %*[{ "user": user, "pass": pass }], sessionId = s.id)
  if result.isOk and result.ok.kind == JString:
    s.db.token = result.ok.getStr()

proc signinNs*(s: Session, ns, user, pass: string): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("signin", %*[{ "ns": ns, "user": user, "pass": pass }], sessionId = s.id)

proc signinDb*(s: Session, ns, database, user, pass: string): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("signin", %*[{ "ns": ns, "db": database, "user": user, "pass": pass }], sessionId = s.id)

proc signinRecord*(s: Session, ns, database, access: string, params: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("signin", %*[{ "ns": ns, "db": database, "ac": access, "params": params }], sessionId = s.id)

proc signup*(s: Session, ns, database, access: string, params: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("signup", %*[{ "ns": ns, "db": database, "ac": access, "params": params }], sessionId = s.id)
  if result.isOk and result.ok.kind == JString:
    s.db.token = result.ok.getStr()

proc authenticate*(s: Session, token: string): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  s.db.token = token
  result = await s.db.send("authenticate", %*[token], sessionId = s.id)

proc invalidate*(s: Session): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  s.db.token = ""
  result = await s.db.send("invalidate", %[], sessionId = s.id)

proc signinWithRefresh*(s: Session, authData: JsonNode): Future[SurrealResult[Tokens]] {.async.} =
  s.requireOpen()
  if authData.kind == JObject:
    var p = authData.copy()
    p["refresh"] = %*true
    let res = await s.db.send("signin", %*[p], sessionId = s.id)
    if res.isOk:
      result = ok(Tokens(
        access: if res.ok.hasKey("access"): res.ok["access"].getStr() else: "",
        refresh: if res.ok.hasKey("refresh"): res.ok["refresh"].getStr() else: ""
      ))
    else:
      result = err[Tokens](res.error.code, res.error.message, res.error.serverError)
  else:
    result = err[Tokens](-1, "authData must be a JObject")

proc signupWithRefresh*(s: Session, authData: JsonNode): Future[SurrealResult[Tokens]] {.async.} =
  s.requireOpen()
  if authData.kind == JObject:
    var p = authData.copy()
    p["refresh"] = %*true
    let res = await s.db.send("signup", %*[p], sessionId = s.id)
    if res.isOk:
      result = ok(Tokens(
        access: if res.ok.hasKey("access"): res.ok["access"].getStr() else: "",
        refresh: if res.ok.hasKey("refresh"): res.ok["refresh"].getStr() else: ""
      ))
    else:
      result = err[Tokens](res.error.code, res.error.message, res.error.serverError)
  else:
    result = err[Tokens](-1, "authData must be a JObject")

proc relate*(s: Session, source: string, relation: string, target: string,
             content: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("relate", %*[source, relation, target, content], sessionId = s.id)

proc insertRelation*(s: Session, table: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  s.requireOpen()
  result = await s.db.send("insert_relation", %*[table, content], sessionId = s.id)

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
