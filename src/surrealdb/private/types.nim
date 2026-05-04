import std/[json, tables, strutils, macros, random, sequtils, math, options, jsonutils, unicode]

type
  RecordId* = object
    table*: string
    id*: JsonNode

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

  GeometryMultiPoint* = distinct seq[GeometryPoint]

  GeometryMultiLine* = distinct seq[GeometryLine]

  GeometryMultiPolygon* = distinct seq[GeometryPolygon]

  GeometryCollection* = object
    geometries*: JsonNode

  BoundIncluded*[T] = object
    value*: T

  BoundExcluded*[T] = object
    value*: T

  Range*[T] = object
    beginBound*: JsonNode
    endBound*: JsonNode

  RecordRangeID*[T] = object
    table*: DbTable
    rangeVal*: Range[T]

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

  QueryError* = object
    message*: string

  QueryStmt* = object
    sql*: string
    vars*: JsonNode
    result*: QueryResult[JsonNode]

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
  CustomNil* = object

  ErrSessionClosed* = object of CatchableError
  ErrTransactionClosed* = object of CatchableError
  ErrNotConnected* = object of CatchableError
  ErrIDInUse* = object of CatchableError

let None* = CustomNil()

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

proc isAsciiAlphanumeric(ch: char): bool =
  (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9')

proc needsIdEscaping(s: string): bool =
  if s.len == 0: return false
  var allDigitsOrUnderscore = true
  for ch in s:
    if ch != '_' and (ch < '0' or ch > '9'):
      allDigitsOrUnderscore = false
    if not isAsciiAlphanumeric(ch) and ch != '_':
      return true
  return allDigitsOrUnderscore

proc escapeId(s: string): string =
  const closeRune = Rune(0x27E9)  # ⟩
  result.add(Rune(0x27E8))  # ⟨
  for r in s.runes:
    if r == closeRune or r == Rune('\\'):
      result.add(Rune('\\'))
    result.add(r)
  result.add(closeRune)

proc `$`*(rid: RecordId): string =
  if rid.id.kind == JString:
    let s = rid.id.getStr()
    if needsIdEscaping(s):
      rid.table & ":" & escapeId(s)
    else:
      rid.table & ":" & s
  else:
    rid.table & ":" & $rid.id
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
proc `$`*(e: QueryError): string = e.message

proc getResult*[T](qs: QueryStmt, _: typedesc[T]): T {.raises: [CatchableError].} =
  ## Lazily unmarshal the query result into the target type T.
  ## Raises if the query had an error or unmarshal fails.
  if qs.result.status == "ERR":
    if qs.result.error != nil:
      raise newException(CatchableError, "query error: " & qs.result.error.message)
    else:
      raise newException(CatchableError, "query error (unknown)")
  result = jsonTo(qs.result.result, T)

proc hasResult*(qs: QueryStmt): bool =
  ## Returns true if the query has a result (status is OK).
  qs.result.status == "OK"

proc getError*(qs: QueryStmt): ServerError =
  ## Returns the error from the query result, or nil if no error.
  qs.result.error

proc isRetriable*(err: RpcError): bool =
  ## Returns true if the error is potentially transient and the request may succeed on retry.
  ## Query-level errors (parse, invalid data) are considered non-retriable.
  if err.serverError != nil:
    case err.serverError.kind
    of ekParse, ekInvalidData:
      return false
    else:
      discard
  return true

proc isQueryError*(err: RpcError): bool =
  ## Returns true if this is a query-level error (syntax/type/logic error).
  ## These errors should NOT be retried.
  if err.serverError != nil:
    case err.serverError.kind
    of ekParse, ekInvalidData:
      return true
    else:
      discard
  return false

proc surrealString*(rid: RecordId): string = "r'" & $rid & "'"
proc surrealString*(dt: Datetime): string = "<datetime> '" & string(dt) & "'"
proc surrealString*(f: SurFuture): string = "<future> { " & string(f) & " }"
proc surrealString*(t: DbTable): string = string(t)
proc surrealString*(u: UUID): string = string(u)
proc surrealString*(d: Duration): string = string(d)
proc surrealString*(dec: Decimal): string = string(dec)
proc surrealString*(n: SurNone): string = "NONE"
proc surrealString*(tbl: SurTable): string = "<table> " & string(tbl)
proc surrealString*(gp: GeometryPoint): string =
  "{'type': 'Point', 'coordinates': [" & $gp.longitude & ", " & $gp.latitude & "]}"
proc surrealString*(gm: GeometryLine): string =
  "{'type': 'LineString', 'coordinates': [" & gm.mapIt($it.longitude & ", " & $it.latitude).join("], [") & "]}"
proc surrealString*(gp: GeometryPolygon): string =
  "{'type': 'Polygon', 'coordinates': [[" & gp.mapIt(it.mapIt($it.longitude & ", " & $it.latitude).join(", ")).join("], [") & "]]}"
proc surrealString*(gm: GeometryMultiPoint): string =
  "{'type': 'MultiPoint', 'coordinates': [" & seq[GeometryPoint](gm).mapIt($it.longitude & ", " & $it.latitude).join("], [") & "]}"
proc surrealString*(gm: GeometryMultiLine): string =
  "{'type': 'MultiLineString', 'coordinates': [[" & seq[GeometryLine](gm).mapIt(it.mapIt($it.longitude & ", " & $it.latitude).join(", ")).join("], [") & "]]}"
proc surrealString*(gm: GeometryMultiPolygon): string =
  "{'type': 'MultiPolygon', 'coordinates': [[[" & seq[GeometryPolygon](gm).mapIt(it.mapIt(it.mapIt($it.longitude & ", " & $it.latitude).join(", ")).join("], [")).join("]], [[") & "]]]}"
proc surrealString*(gc: GeometryCollection): string = $gc.geometries
proc surrealString*[T](bi: BoundIncluded[T]): string = $bi.value & "..="
proc surrealString*[T](be: BoundExcluded[T]): string = $be.value & "..<"
proc surrealString*[T](r: Range[T]): string = $r.beginBound & ".." & $r.endBound
proc surrealString*[T](rr: RecordRangeID[T]): string = $rr.table & ":" & surrealString(rr.rangeVal)
proc surrealString*(pd: PatchData): string = pd.op & " " & pd.path & " " & $pd.value
proc surrealString*(tokens: Tokens): string =
  let aLen = min(tokens.access.len, 6)
  let rLen = min(tokens.refresh.len, 6)
  "Tokens(access: " & tokens.access[0..<aLen] & "..., refresh: " & tokens.refresh[0..<rLen] & "...)"
proc surrealString*(a: Auth): string =
  var parts: seq[string]
  if a.namespace.isSome: parts.add("ns: " & a.namespace.get)
  if a.database.isSome: parts.add("db: " & a.database.get)
  if a.scope.isSome: parts.add("sc: " & a.scope.get)
  if a.access.isSome: parts.add("ac: " & a.access.get)
  if a.username.isSome: parts.add("user: " & a.username.get)
  "Auth(" & parts.join(", ") & ")"
proc surrealString*(rel: Relationship): string =
  var idStr = ""
  if rel.id.isSome: idStr = $rel.id.get & " "
  idStr & $rel.inRec & " -> " & $rel.relation & " -> " & $rel.outRec

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
proc `%%`*(gm: GeometryMultiPoint): JsonNode =
  %*{"type": "MultiPoint", "coordinates": seq[GeometryPoint](gm).mapIt([it.longitude, it.latitude])}
proc `%%`*(gm: GeometryMultiLine): JsonNode =
  %*{"type": "MultiLineString", "coordinates": seq[GeometryLine](gm).mapIt(it.mapIt([it.longitude, it.latitude]))}
proc `%%`*(gm: GeometryMultiPolygon): JsonNode =
  %*{"type": "MultiPolygon", "coordinates": seq[GeometryPolygon](gm).mapIt(it.mapIt(it.mapIt([it.longitude, it.latitude])))}
proc `%%`*(gc: GeometryCollection): JsonNode =
  %*{"type": "GeometryCollection", "geometries": gc.geometries}
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
proc `%%`*(bi: BoundIncluded): JsonNode = %*{"incl": bi.value}
proc `%%`*(be: BoundExcluded): JsonNode = %*{"excl": be.value}
proc `%%`*[T](r: Range[T]): JsonNode =
  %*{"begin": r.beginBound, "end": r.endBound}
proc `%%`*[T](rr: RecordRangeID[T]): JsonNode =
  %*{"table": $rr.table, "range": %%rr.rangeVal}
proc `%%`*(cn: CustomNil): JsonNode = newJNull()

proc ok*[T](val: T): SurrealResult[T] = SurrealResult[T](isOk: true, ok: val)
proc err*[T](code: int, msg: string): SurrealResult[T] =
  SurrealResult[T](isOk: false, error: RpcError(code: code, message: msg))
proc err*[T](code: int, msg: string, serverErr: ServerError): SurrealResult[T] =
  SurrealResult[T](isOk: false, error: RpcError(code: code, message: msg, serverError: serverErr))

proc record*(table, id: string): RecordId = RecordId(table: table, id: %*id)
proc record*(table: string, id: JsonNode): RecordId = RecordId(table: table, id: id)
proc record*(s: string): RecordId =
  let parts = s.split(":", 1)
  if parts.len != 2:
    raise newException(ValueError, "Invalid RecordId: " & s)
  RecordId(table: parts[0], id: %*parts[1])

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
  result.add newTree(nnkExprColonExpr, ident"id", newTree(nnkPrefix, ident"%*", newLit(parts[1])))

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

proc parseVersionData*(node: JsonNode): VersionData =
  ## Parses version response. Handles both map {version, build, timestamp} and plain string.
  if node.isNil or node.kind == JNull:
    return VersionData(version: "unknown")
  if node.kind == JObject:
    result.version = if node.hasKey("version") and node["version"].kind == JString: node["version"].getStr() else: ""
    result.build = if node.hasKey("build") and node["build"].kind == JString: node["build"].getStr() else: ""
    result.timestamp = if node.hasKey("timestamp") and node["timestamp"].kind == JString: node["timestamp"].getStr() else: ""
  elif node.kind == JString:
    let s = node.getStr()
    result.version = if s.startsWith("surrealdb-"): s[10..^1] else: s
    result.build = ""
    result.timestamp = ""
  else:
    result.version = $node
    result.build = ""
    result.timestamp = ""

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
