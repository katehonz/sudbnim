import std/[json, tables, strutils, macros, random, sequtils, math]

type
  RecordId* = object
    table*: string
    id*: string

  DbTable* = distinct string

  SurQL* = distinct string

  UUID* = distinct string

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

proc `$`*(rid: RecordId): string = rid.table & ":" & rid.id
proc `==`*(a, b: RecordId): bool = a.table == b.table and a.id == b.id
proc `$`*(t: DbTable): string = string(t)
proc `$`*(q: SurQL): string = string(q)
proc `$`*(u: UUID): string = string(u)
proc `%%`*(rid: RecordId): JsonNode = %*{"tb": rid.table, "id": rid.id}

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
