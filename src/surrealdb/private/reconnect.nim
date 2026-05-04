import std/[json, asyncdispatch, tables, strutils]
import ./connection, ./types

type
  ConnectionState* = enum
    stateDisconnected
    stateConnecting
    stateConnected
    stateClosing
    stateClosed

  LiveQueryReg* = object
    table*: string
    diff*: bool
    handler*: LiveQueryHandler

  ReconnectingDb* = ref object
    url*: string
    ns*: string
    database*: string
    token*: string
    state*: ConnectionState
    db*: Db
    retryer*: Retryer
    vars*: TableRef[string, JsonNode]
    liveQueries*: TableRef[string, LiveQueryReg]
    onReconnect*: proc() {.gcsafe, closure.}

proc isConnected*(rdb: ReconnectingDb): bool =
  rdb.state == stateConnected and rdb.db != nil and rdb.db.isConnected()

proc reconnectLiveQueries(rdb: ReconnectingDb) {.async.} =
  if rdb.db == nil: return
  var newRegs = newTable[string, LiveQueryReg]()
  for oldId, reg in rdb.liveQueries:
    let res = await rdb.db.live(reg.table, reg.diff)
    if res.isOk:
      let newId = res.ok.getStr("")
      if newId.len > 0:
        newRegs[newId] = reg
        if reg.handler != nil:
          rdb.db.onNotification(newId, reg.handler)
    # Old IDs are now invalid
  rdb.liveQueries = newRegs

proc connectWithRetry(rdb: ReconnectingDb): Future[bool] {.async.} =
  rdb.state = stateConnecting
  var attempt = 0
  if rdb.retryer != nil:
    rdb.retryer.reset()

  while true:
    try:
      let db = await connect(rdb.url)
      if rdb.ns.len > 0 and rdb.database.len > 0:
        discard await db.use(rdb.ns, rdb.database)
      if rdb.token.len > 0:
        discard await db.authenticate(rdb.token)
      for key, value in rdb.vars:
        discard await db.setVar(key, value)

      rdb.db = db
      rdb.state = stateConnected
      if rdb.retryer != nil:
        rdb.retryer.reset()

      # Restore live queries
      await rdb.reconnectLiveQueries()

      if rdb.onReconnect != nil:
        try: rdb.onReconnect() except: discard

      return true
    except:
      inc attempt
      if rdb.retryer == nil or not rdb.retryer.shouldRetry():
        rdb.state = stateDisconnected
        return false
      let delay = rdb.retryer.nextDelay()
      await sleepAsync(int(delay * 1000))

proc connect*(rdb: ReconnectingDb): Future[bool] {.async.} =
  result = await rdb.connectWithRetry()

proc reconnectLoop(rdb: ReconnectingDb) {.async.} =
  while rdb.state == stateConnected:
    if rdb.db == nil or not rdb.db.isConnected():
      echo "[surrealdb] Connection lost, reconnecting..."
      discard await rdb.connectWithRetry()
    await sleepAsync(5000)

proc newReconnectingDb*(url: string, retryer: Retryer = nil): ReconnectingDb =
  result = ReconnectingDb(
    url: url,
    state: stateDisconnected,
    retryer: retryer,
    vars: newTable[string, JsonNode](),
    liveQueries: newTable[string, LiveQueryReg]()
  )

proc start*(rdb: ReconnectingDb) {.async.} =
  let ok = await rdb.connect()
  if ok:
    asyncCheck rdb.reconnectLoop()

proc disconnect*(rdb: ReconnectingDb) =
  rdb.state = stateClosed
  if rdb.db != nil:
    rdb.db.disconnect()

proc use*(rdb: ReconnectingDb, ns, database: string): Future[SurrealResult[JsonNode]] {.async.} =
  rdb.ns = ns; rdb.database = database
  if rdb.db != nil:
    result = await rdb.db.use(ns, database)

proc signin*(rdb: ReconnectingDb, user, pass: string): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil:
    result = await rdb.db.signin(user, pass)
    if result.isOk and result.ok.kind == JString:
      rdb.token = result.ok.getStr()

proc authenticate*(rdb: ReconnectingDb, token: string): Future[SurrealResult[JsonNode]] {.async.} =
  rdb.token = token
  if rdb.db != nil:
    result = await rdb.db.authenticate(token)

proc invalidate*(rdb: ReconnectingDb): Future[SurrealResult[JsonNode]] {.async.} =
  rdb.token = ""
  if rdb.db != nil:
    result = await rdb.db.invalidate()

proc setVar*(rdb: ReconnectingDb, name: string, value: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  rdb.vars[name] = value
  if rdb.db != nil:
    result = await rdb.db.setVar(name, value)

proc unsetVar*(rdb: ReconnectingDb, name: string): Future[SurrealResult[JsonNode]] {.async.} =
  rdb.vars.del(name)
  if rdb.db != nil:
    result = await rdb.db.unsetVar(name)

proc signinNs*(rdb: ReconnectingDb, ns, user, pass: string): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil:
    result = await rdb.db.signinNs(ns, user, pass)
    if result.isOk and result.ok.kind == JString:
      rdb.token = result.ok.getStr()

proc signinDb*(rdb: ReconnectingDb, ns, database, user, pass: string): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil:
    result = await rdb.db.signinDb(ns, database, user, pass)
    if result.isOk and result.ok.kind == JString:
      rdb.token = result.ok.getStr()

proc query*(rdb: ReconnectingDb, sql: string, vars: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await rdb.db.query(sql, vars)

proc query*(rdb: ReconnectingDb, sql: SurQL, vars: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await rdb.db.query(sql, vars)

proc select*(rdb: ReconnectingDb, thing: string): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await rdb.db.select(thing)

proc select*(rdb: ReconnectingDb, thing: RecordId): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await rdb.db.select(thing)

proc select*(rdb: ReconnectingDb, thing: DbTable): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await rdb.db.select(thing)

proc create*(rdb: ReconnectingDb, thing: string, content: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await rdb.db.create(thing, content)

proc create*(rdb: ReconnectingDb, thing: RecordId, content: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await rdb.db.create(thing, content)

proc insert*(rdb: ReconnectingDb, table: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await rdb.db.insert(table, content)

proc update*(rdb: ReconnectingDb, thing: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await rdb.db.update(thing, content)

proc update*(rdb: ReconnectingDb, thing: RecordId, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await rdb.db.update(thing, content)

proc upsert*(rdb: ReconnectingDb, thing: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await rdb.db.upsert(thing, content)

proc merge*(rdb: ReconnectingDb, thing: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await rdb.db.merge(thing, content)

proc merge*(rdb: ReconnectingDb, thing: RecordId, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await rdb.db.merge(thing, content)

proc delete*(rdb: ReconnectingDb, thing: string): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await rdb.db.delete(thing)

proc delete*(rdb: ReconnectingDb, thing: RecordId): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await rdb.db.delete(thing)

proc delete*(rdb: ReconnectingDb, thing: DbTable): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await rdb.db.delete(thing)

proc live*(rdb: ReconnectingDb, table: string, diff: bool = false, handler: LiveQueryHandler = nil): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil:
    result = await rdb.db.live(table, diff)
    if result.isOk:
      let liveId = result.ok.getStr("")
      if liveId.len > 0:
        rdb.liveQueries[liveId] = LiveQueryReg(table: table, diff: diff, handler: handler)
        if handler != nil:
          rdb.db.onNotification(liveId, handler)

proc kill*(rdb: ReconnectingDb, liveId: string): Future[SurrealResult[JsonNode]] {.async.} =
  rdb.liveQueries.del(liveId)
  if rdb.db != nil: result = await rdb.db.kill(liveId)

proc run*(rdb: ReconnectingDb, fnName: string, args: JsonNode = %[]): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await rdb.db.run(fnName, args)

proc version*(rdb: ReconnectingDb): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await rdb.db.version()

proc info*(rdb: ReconnectingDb): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await rdb.db.info()

proc signup*(rdb: ReconnectingDb, ns, database, access: string, params: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil:
    result = await rdb.db.signup(ns, database, access, params)
    if result.isOk and result.ok.kind == JString:
      rdb.token = result.ok.getStr()

proc relate*(rdb: ReconnectingDb, source: string, relation: string, target: string,
             content: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await rdb.db.relate(source, relation, target, content)

proc patch*(rdb: ReconnectingDb, thing: string, patches: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await rdb.db.patch(thing, patches)

proc insertRelation*(rdb: ReconnectingDb, table: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await rdb.db.insertRelation(table, content)

# Transactions
proc begin*(rdb: ReconnectingDb): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await rdb.db.begin()

proc commit*(rdb: ReconnectingDb): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await rdb.db.commit()

proc cancel*(rdb: ReconnectingDb): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await rdb.db.cancel()
