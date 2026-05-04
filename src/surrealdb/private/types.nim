import std/[json, tables, strutils, macros, random, sequtils, math, options]

type
  RecordId* = object
    table*: string
    id*: string

  DbTable* = distinct string

  SurQL* = distinct string

  UUID* = distinct string

  Datetime* = distinct string

  Duration* = distinct string

  Decimal* = distinct string

  SurFuture* = distinct string

  SurNone* = distinct string

  SurTable* = distinct string

  GeometryPoint* = object
    longitude*: float
    latitude*: float

  GeometryLine* = seq[GeometryPoint]

  GeometryPolygon* = seq[GeometryLine]

  GeometryMultiPoint* = seq[GeometryPoint]

  GeometryMultiLine* = seq[GeometryLine]

  GeometryMultiPolygon* = seq[GeometryPolygon]

  GeometryCollection* = object
    geometries*: JsonNode

  Auth* = object
    namespace*: Option[string]
    database*: Option[string]
    scope*: Option[string]
    access*: Option[string]
    username*: Option[string]
    password*: Option[string]

  Tokens* = object
    access*: string
    refresh*: string

  PatchData* = object
    op*: string
    path*: string
    value*: JsonNode

  Relationship* = object
    id*: Option[RecordId]
    inRec*: RecordId
    outRec*: RecordId
    relation*: DbTable
    data*: JsonNode

  VersionData* = object
    version*: string
    build*: string
    timestamp*: string

  RpcMethod* = enum
    rpcUse = "use"
    rpcInfo = "info"
    rpcVersion = "version"
    rpcSignup = "signup"
    rpcSignin = "signin"
    rpcAuthenticate = "authenticate"
    rpcInvalidate = "invalidate"
    rpcLet = "let"
    rpcUnset = "unset"
    rpcLive = "live"
    rpcKill = "kill"
    rpcQuery = "query"
    rpcSelect = "select"
    rpcCreate = "create"
    rpcInsert = "insert"
    rpcInsertRelation = "insert_relation"
    rpcUpdate = "update"
    rpcUpsert = "upsert"
    rpcRelate = "relate"
    rpcMerge = "merge"
    rpcPatch = "patch"
    rpcDelete = "delete"
    rpcRun = "run"
    rpcBegin = "begin"
    rpcCommit = "commit"
    rpcCancel = "cancel"

  ErrorKind* = enum
    ekParse = "Parse"
    ekAuth = "Auth"
    ekAccess = "Access"
    ekNotFound = "NotFound"
    ekAlreadyExists = "AlreadyExists"
    ekInvalidData = "InvalidData"
    ekPermission = "Permission"
    ekUnimplemented = "Unimplemented"
    ekInternal = "Internal"
    ekTimeout = "Timeout"
    ekConnection = "Connection"
    ekLiveKilled = "LiveKilled"
    ekUnknown = "Unknown"

  ServerError* = ref object
    code*: int
    message*: string
    kind*: ErrorKind
    details*: JsonNode
    cause*: ServerError

  RpcError* = object
    code*: int
    message*: string
    serverError*: ServerError

  SurrealResult*[T] = object
    case isOk*: bool
    of true:
      ok*: T
    of false:
      error*: RpcError

  QueryResult*[T] = object
    status*: string
    result*: T
    time*: string
    error*: ServerError

  NotificationAction* = enum
    naCreate = "CREATE"
    naUpdate = "UPDATE"
    naDelete = "DELETE"
    naKilled = "KILLED"

  Notification*[T] = object
    id*: UUID
    action*: NotificationAction
    result*: T

  LiveQueryHandler* = proc(action: NotificationAction; data: JsonNode) {.gcsafe, closure.}

  Retryer* = ref object of RootObj
    attempt*: int

  ExponentialBackoff* = ref object of Retryer
    initialDelay*: float
    maxDelay*: float
    multiplier*: float
    maxRetries*: int
    jitter*: bool

  FixedDelay* = ref object of Retryer
    delay*: float
    maxRetries*: int

  LogLevel* = enum
    llDebug, llInfo, llWarn, llError

  Logger* = ref object of RootObj
    onLog*: proc(level: LogLevel, msg: string) {.gcsafe, closure.}
    onDebug*: proc(msg: string) {.gcsafe, closure.}
    onInfo*: proc(msg: string) {.gcsafe, closure.}
    onWarn*: proc(msg: string) {.gcsafe, closure.}
    onError*: proc(msg: string) {.gcsafe, closure.}

type
  ErrSessionClosed* = object of CatchableError
  ErrTransactionClosed* = object of CatchableError
  ErrNotConnected* = object of CatchableError
  ErrIDInUse* = object of CatchableError

proc newErrSessionClosed*(): ref ErrSessionClosed =
  new(result); result.msg = "session already detached"

proc newErrTransactionClosed*(): ref ErrTransactionClosed =
  new(result); result.msg = "transaction already committed or canceled"

proc newErrNotConnected*(): ref ErrNotConnected =
  new(result); result.msg = "not connected"

proc newErrIDInUse*(): ref ErrIDInUse =
  new(result); result.msg = "id already in use"

proc log*(l: Logger, level: LogLevel, msg: string) =
  if l.isNil:
    return
  if l.onLog != nil: l.onLog(level, msg)
  case level
  of llDebug:
    if l.onDebug != nil: l.onDebug(msg)
  of llInfo:
    if l.onInfo != nil: l.onInfo(msg)
  of llWarn:
    if l.onWarn != nil: l.onWarn(msg)
  of llError:
    if l.onError != nil: l.onError(msg)

proc debug*(l: Logger, msg: string) = l.log(llDebug, msg)
proc info*(l: Logger, msg: string) = l.log(llInfo, msg)
proc warn*(l: Logger, msg: string) = l.log(llWarn, msg)
proc error*(l: Logger, msg: string) = l.log(llError, msg)

proc newConsoleLogger*(prefix = "[surrealdb]"): Logger =
  result = Logger()
  result.onLog = proc(level: LogLevel, msg: string) =
    echo prefix, " [", level, "] ", msg

proc newSilentLogger*(): Logger = Logger()

proc `$`*(rid: RecordId): string = rid.table & ":" & rid.id
proc `==`*(a, b: RecordId): bool = a.table == b.table and a.id == b.id
proc `$`*(t: DbTable): string = string(t)
proc `$`*(q: SurQL): string = string(q)
proc `$`*(u: UUID): string = string(u)
proc `$`*(dt: Datetime): string = string(dt)
proc `$`*(d: Duration): string = string(d)
proc `$`*(dec: Decimal): string = string(dec)
proc `$`*(f: SurFuture): string = string(f)
proc `$`*(n: SurNone): string = string(n)
proc `$`*(tbl: SurTable): string = string(tbl)
proc `%%`*(rid: RecordId): JsonNode = %*{"tb": rid.table, "id": rid.id}
proc `%%`*(dt: Datetime): JsonNode = %*string(dt)
proc `%%`*(d: Duration): JsonNode = %*string(d)
proc `%%`*(dec: Decimal): JsonNode = %*string(dec)
proc `%%`*(f: SurFuture): JsonNode = %*string(f)
proc `%%`*(none: SurNone): JsonNode = newJNull()
proc `%%`*(tbl: SurTable): JsonNode = %*string(tbl)
proc `%%`*(gp: GeometryPoint): JsonNode =
  %*{"type": "Point", "coordinates": [gp.longitude, gp.latitude]}
proc `%%`*(gm: GeometryLine): JsonNode =
  %*{"type": "LineString", "coordinates": gm.mapIt([it.longitude, it.latitude])}
proc `%%`*(gp: GeometryPolygon): JsonNode =
  %*{"type": "Polygon", "coordinates": gp.mapIt(it.mapIt([it.longitude, it.latitude]))}
proc `%%`*(a: Auth): JsonNode =
  result = newJObject()
  if a.namespace.isSome: result["NS"] = %*a.namespace.get
  if a.database.isSome: result["DB"] = %*a.database.get
  if a.scope.isSome: result["SC"] = %*a.scope.get
  if a.access.isSome: result["AC"] = %*a.access.get
  if a.username.isSome: result["user"] = %*a.username.get
  if a.password.isSome: result["pass"] = %*a.password.get
proc `%%`*(pd: PatchData): JsonNode = %*{"op": pd.op, "path": pd.path, "value": pd.value}
proc `%%`*(tokens: Tokens): JsonNode = %*{"access": tokens.access, "refresh": tokens.refresh}
proc `%%`*(rel: Relationship): JsonNode =
  result = newJObject()
  if rel.id.isSome: result["id"] = %*rel.id.get
  result["in"] = %*rel.inRec
  result["out"] = %*rel.outRec
  result["relation"] = %*($rel.relation)
  if rel.data.len > 0: result["data"] = rel.data

proc ok*[T](val: T): SurrealResult[T] = SurrealResult[T](isOk: true, ok: val)
proc err*[T](code: int, msg: string): SurrealResult[T] =
  SurrealResult[T](isOk: false, error: RpcError(code: code, message: msg))
proc err*[T](code: int, msg: string, serverErr: ServerError): SurrealResult[T] =
  SurrealResult[T](isOk: false, error: RpcError(code: code, message: msg, serverError: serverErr))

proc record*(table, id: string): RecordId = RecordId(table: table, id: id)
proc record*(s: string): RecordId =
  let parts = s.split(":", 1)
  if parts.len != 2:
    raise newException(ValueError, "Invalid RecordId: " & s)
  RecordId(table: parts[0], id: parts[1])

proc dbTable*(s: string): DbTable = DbTable(s)
proc newUuid*(): UUID =
  var b: array[16, byte]
  for i in 0..<16: b[i] = byte(rand(255))
  b[6] = (b[6] and 0x0f) or 0x40
  b[8] = (b[8] and 0x3f) or 0x80
  UUID(b.mapIt(it.toHex(2)).join("").toLowerAscii())

macro `rc`*(s: static string): RecordId =
  let parts = s.split(":", 1)
  if parts.len != 2:
    error "Invalid RecordId: " & s
  result = newTree(nnkObjConstr, ident"RecordId")
  result.add newTree(nnkExprColonExpr, ident"table", newLit(parts[0]))
  result.add newTree(nnkExprColonExpr, ident"id", newLit(parts[1]))

macro `tb`*(s: static string): DbTable =
  quote do: DbTable(`s`)

macro `surql`*(s: static string): SurQL =
  quote do: SurQL(`s`)

method nextDelay*(r: Retryer): float {.base.} =
  inc r.attempt
  result = 1.0

method shouldRetry*(r: Retryer): bool {.base.} = true

method reset*(r: Retryer) {.base.} =
  r.attempt = 0

method nextDelay*(b: ExponentialBackoff): float =
  inc b.attempt
  let d = b.initialDelay * pow(b.multiplier, float(b.attempt - 1))
  let delay = if d > b.maxDelay: b.maxDelay else: d
  if b.jitter:
    let j = rand(1.0) * 0.3 * delay - 0.15 * delay
    result = delay + j
  else:
    result = delay

method shouldRetry*(b: ExponentialBackoff): bool =
  b.attempt < b.maxRetries or b.maxRetries == 0

method nextDelay*(f: FixedDelay): float =
  inc f.attempt
  result = f.delay

method shouldRetry*(f: FixedDelay): bool =
  f.attempt < f.maxRetries or f.maxRetries == 0

proc parseErrorKind*(s: string): ErrorKind =
  case s
  of "Parse": ekParse
  of "Auth": ekAuth
  of "Access": ekAccess
  of "NotFound": ekNotFound
  of "AlreadyExists": ekAlreadyExists
  of "InvalidData": ekInvalidData
  of "Permission": ekPermission
  of "Unimplemented": ekUnimplemented
  of "Internal": ekInternal
  of "Timeout": ekTimeout
  of "Connection": ekConnection
  of "LiveKilled": ekLiveKilled
  else: ekUnknown

proc parseServerError*(node: JsonNode): ServerError =
  if node.isNil or node.kind != JObject:
    return nil
  result = ServerError(
    code: if node.hasKey("code") and node["code"].kind == JInt: node["code"].getInt() else: 0,
    message: if node.hasKey("message") and node["message"].kind == JString: node["message"].getStr() else: "",
    kind: if node.hasKey("kind") and node["kind"].kind == JString: parseErrorKind(node["kind"].getStr()) else: ekUnknown,
    details: if node.hasKey("details"): node["details"] else: newJNull()
  )
  if node.hasKey("cause") and node["cause"].kind == JObject:
    result.cause = parseServerError(node["cause"])

proc parseRpcError*(node: JsonNode): RpcError =
  if node.isNil or node.kind != JObject:
    return RpcError(code: -32603, message: "Unknown error")
  let code = if node.hasKey("code") and node["code"].kind == JInt: node["code"].getInt() else: -32603
  let msg = if node.hasKey("message") and node["message"].kind == JString: node["message"].getStr() else: "Unknown error"
  var serverErr: ServerError = nil
  if node.hasKey("data") and node["data"].kind == JObject:
    serverErr = parseServerError(node["data"])
  elif node.hasKey("error") and node["error"].kind == JObject:
    serverErr = parseServerError(node["error"])
  else:
    serverErr = parseServerError(node)
  RpcError(code: code, message: msg, serverError: serverErr)
