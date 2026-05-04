import std/[json, asyncdispatch, tables, strutils]
import ./connection as dbconn
import ./types

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

  NotificationRouter* = ref object
    db*: Db
    routes*: TableRef[string, seq[string]]
    regMap*: TableRef[string, LiveQueryReg]
    logger*: Logger

  ReconnectingDb* = ref object
    url*: string
    ns*: string
    database*: string
    token*: string
    state*: ConnectionState
    db*: Db
    retryer*: Retryer
    logger*: Logger
    vars*: TableRef[string, JsonNode]
    liveQueries*: TableRef[string, LiveQueryReg]
    onReconnect*: proc() {.gcsafe, closure.}

proc isConnected*(rdb: ReconnectingDb): bool =
  rdb.state == stateConnected and rdb.db != nil and rdb.db.isConnected()

proc reconnectLiveQueries(rdb: ReconnectingDb) {.async.} =
  if rdb.db == nil: return
  var newRegs = newTable[string, LiveQueryReg]()
  for oldId, reg in rdb.liveQueries:
    let res = await dbconn.live(rdb.db, reg.table, reg.diff)
    if res.isOk:
      let newId = res.ok.getStr("")
      if newId.len > 0:
        newRegs[newId] = reg
        if reg.handler != nil:
          dbconn.onNotification(rdb.db, newId, reg.handler)
  rdb.liveQueries = newRegs

proc connectWithRetry(rdb: ReconnectingDb): Future[bool] {.async.} =
  rdb.state = stateConnecting
  var attempt = 0
  if rdb.retryer != nil:
    rdb.retryer.reset()

  while true:
    try:
      let db = await dbconn.connect(rdb.url, rdb.logger)
      if rdb.ns.len > 0 and rdb.database.len > 0:
        discard await dbconn.use(db, rdb.ns, rdb.database)
      if rdb.token.len > 0:
        discard await dbconn.authenticate(db, rdb.token)
      for key, value in rdb.vars:
        discard await dbconn.setVar(db, key, value)

      rdb.db = db
      rdb.state = stateConnected
      if rdb.retryer != nil:
        rdb.retryer.reset()

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
      rdb.logger.warn("Connection lost, reconnecting...")
      discard await rdb.connectWithRetry()
    await sleepAsync(5000)

proc newReconnectingDb*(url: string, retryer: Retryer = nil, logger: Logger = nil): ReconnectingDb =
  result = ReconnectingDb(
    url: url,
    state: stateDisconnected,
    retryer: retryer,
    logger: if logger != nil: logger else: newSilentLogger(),
    vars: newTable[string, JsonNode](),
    liveQueries: newTable[string, LiveQueryReg]()
  )

proc newNotificationRouter*(db: Db, logger: Logger = nil): NotificationRouter =
  result = NotificationRouter(
    db: db,
    routes: newTable[string, seq[string]](),
    regMap: newTable[string, LiveQueryReg](),
    logger: if logger != nil: logger else: newSilentLogger()
  )

proc register*(nr: NotificationRouter, internalId: string, reg: LiveQueryReg) =
  nr.regMap[internalId] = reg

proc unregister*(nr: NotificationRouter, internalId: string) =
  nr.routes.del(internalId)
  nr.regMap.del(internalId)

proc reRegister*(nr: NotificationRouter) {.async.} =
  var newRoutes = newTable[string, seq[string]]()
  for internalId, reg in nr.regMap:
    let res = await dbconn.live(nr.db, reg.table, reg.diff)
    if res.isOk:
      let externalId = res.ok.getStr("")
      if externalId.len > 0:
        newRoutes[internalId] = @[externalId]
        if reg.handler != nil:
          dbconn.onNotification(nr.db, externalId, reg.handler)
    else:
      nr.logger.warn("Failed to re-register live query: " & internalId)
  nr.routes = newRoutes

proc externalIds*(nr: NotificationRouter, internalId: string): seq[string] =
  if nr.routes.hasKey(internalId):
    result = nr.routes[internalId]
  else:
    result = @[]

proc start*(rdb: ReconnectingDb) {.async.} =
  let ok = await rdb.connect()
  if ok:
    asyncCheck rdb.reconnectLoop()

proc disconnect*(rdb: ReconnectingDb) =
  rdb.state = stateClosed
  if rdb.db != nil:
    dbconn.disconnect(rdb.db)

proc use*(rdb: ReconnectingDb, ns, database: string): Future[SurrealResult[JsonNode]] {.async.} =
  rdb.ns = ns; rdb.database = database
  if rdb.db != nil:
    result = await dbconn.use(rdb.db, ns, database)

proc signin*(rdb: ReconnectingDb, user, pass: string): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil:
    result = await dbconn.signin(rdb.db, user, pass)
    if result.isOk and result.ok.kind == JString:
      rdb.token = result.ok.getStr()

proc authenticate*(rdb: ReconnectingDb, token: string): Future[SurrealResult[JsonNode]] {.async.} =
  rdb.token = token
  if rdb.db != nil:
    result = await dbconn.authenticate(rdb.db, token)

proc invalidate*(rdb: ReconnectingDb): Future[SurrealResult[JsonNode]] {.async.} =
  rdb.token = ""
  if rdb.db != nil:
    result = await dbconn.invalidate(rdb.db)

proc setVar*(rdb: ReconnectingDb, name: string, value: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  rdb.vars[name] = value
  if rdb.db != nil:
    result = await dbconn.setVar(rdb.db, name, value)

proc unsetVar*(rdb: ReconnectingDb, name: string): Future[SurrealResult[JsonNode]] {.async.} =
  rdb.vars.del(name)
  if rdb.db != nil:
    result = await dbconn.unsetVar(rdb.db, name)

proc signinNs*(rdb: ReconnectingDb, ns, user, pass: string): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil:
    result = await dbconn.signinNs(rdb.db, ns, user, pass)
    if result.isOk and result.ok.kind == JString:
      rdb.token = result.ok.getStr()

proc signinDb*(rdb: ReconnectingDb, ns, database, user, pass: string): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil:
    result = await dbconn.signinDb(rdb.db, ns, database, user, pass)
    if result.isOk and result.ok.kind == JString:
      rdb.token = result.ok.getStr()

proc query*(rdb: ReconnectingDb, sql: string, vars: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await dbconn.query(rdb.db, sql, vars)

proc query*(rdb: ReconnectingDb, sql: SurQL, vars: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await dbconn.query(rdb.db, sql, vars)

proc select*(rdb: ReconnectingDb, thing: string): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await dbconn.select(rdb.db, thing)

proc select*(rdb: ReconnectingDb, thing: RecordId): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await dbconn.select(rdb.db, thing)

proc select*(rdb: ReconnectingDb, thing: DbTable): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await dbconn.select(rdb.db, thing)

proc create*(rdb: ReconnectingDb, thing: string, content: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await dbconn.create(rdb.db, thing, content)

proc create*(rdb: ReconnectingDb, thing: RecordId, content: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await dbconn.create(rdb.db, thing, content)

proc insert*(rdb: ReconnectingDb, table: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await dbconn.insert(rdb.db, table, content)

proc update*(rdb: ReconnectingDb, thing: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await dbconn.update(rdb.db, thing, content)

proc update*(rdb: ReconnectingDb, thing: RecordId, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await dbconn.update(rdb.db, thing, content)

proc upsert*(rdb: ReconnectingDb, thing: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await dbconn.upsert(rdb.db, thing, content)

proc merge*(rdb: ReconnectingDb, thing: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await dbconn.merge(rdb.db, thing, content)

proc merge*(rdb: ReconnectingDb, thing: RecordId, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await dbconn.merge(rdb.db, thing, content)

proc delete*(rdb: ReconnectingDb, thing: string): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await dbconn.delete(rdb.db, thing)

proc delete*(rdb: ReconnectingDb, thing: RecordId): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await dbconn.delete(rdb.db, thing)

proc delete*(rdb: ReconnectingDb, thing: DbTable): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await dbconn.delete(rdb.db, thing)

proc live*(rdb: ReconnectingDb, table: string, diff: bool = false, handler: LiveQueryHandler = nil): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil:
    result = await dbconn.live(rdb.db, table, diff)
    if result.isOk:
      let liveId = result.ok.getStr("")
      if liveId.len > 0:
        rdb.liveQueries[liveId] = LiveQueryReg(table: table, diff: diff, handler: handler)
        if handler != nil:
          dbconn.onNotification(rdb.db, liveId, handler)

proc kill*(rdb: ReconnectingDb, liveId: string): Future[SurrealResult[JsonNode]] {.async.} =
  rdb.liveQueries.del(liveId)
  if rdb.db != nil: result = await dbconn.kill(rdb.db, liveId)

proc run*(rdb: ReconnectingDb, fnName: string, args: JsonNode = %[]): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await dbconn.run(rdb.db, fnName, args)

proc version*(rdb: ReconnectingDb): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await dbconn.version(rdb.db)

proc info*(rdb: ReconnectingDb): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await dbconn.info(rdb.db)

proc signup*(rdb: ReconnectingDb, ns, database, access: string, params: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil:
    result = await dbconn.signup(rdb.db, ns, database, access, params)
    if result.isOk and result.ok.kind == JString:
      rdb.token = result.ok.getStr()

proc relate*(rdb: ReconnectingDb, source: string, relation: string, target: string,
             content: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await dbconn.relate(rdb.db, source, relation, target, content)

proc patch*(rdb: ReconnectingDb, thing: string, patches: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await dbconn.patch(rdb.db, thing, patches)

proc insertRelation*(rdb: ReconnectingDb, table: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  if rdb.db != nil: result = await dbconn.insertRelation(rdb.db, table, content)

# Transactions
proc begin*(rdb: ReconnectingDb): Future[SurrealResult[JsonNode]] =
  if rdb.db == nil:
    var f = newFuture[SurrealResult[JsonNode]]("begin")
    f.complete(err[JsonNode](-1, "not connected"))
    return f
  result = dbconn.begin(rdb.db)

proc commit*(rdb: ReconnectingDb): Future[SurrealResult[JsonNode]] =
  if rdb.db == nil:
    var f = newFuture[SurrealResult[JsonNode]]("commit")
    f.complete(err[JsonNode](-1, "not connected"))
    return f
  result = dbconn.commit(rdb.db)

proc cancel*(rdb: ReconnectingDb): Future[SurrealResult[JsonNode]] =
  if rdb.db == nil:
    var f = newFuture[SurrealResult[JsonNode]]("cancel")
    f.complete(err[JsonNode](-1, "not connected"))
    return f
  result = dbconn.cancel(rdb.db)
