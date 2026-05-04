import std/[httpclient, asyncdispatch, json, strutils]
import ./types, ./codec

type
  HttpClient* = ref object
    client*: AsyncHttpClient
    baseUrl*: string
    ns*: string
    database*: string
    token*: string
    codec*: Codec

proc parseStatusCode(status: string): int =
  let parts = status.split(" ")
  if parts.len > 0:
    result = parseInt(parts[0])
  else:
    result = 0

proc newHttpClient*(baseUrl: string, codec: Codec = nil): HttpClient =
  let c = if codec != nil: codec else: newJsonCodec()
  result = HttpClient(
    client: newAsyncHttpClient(userAgent = "surrealdb-nim"),
    baseUrl: baseUrl.strip(chars = {'/'}),
    codec: c
  )

proc close*(c: HttpClient) =
  c.client.close()

proc health*(c: HttpClient): Future[bool] {.async.} =
  try:
    let resp = await c.client.get(c.baseUrl & "/health")
    result = resp.status.startsWith("200")
  except:
    result = false

proc use*(c: HttpClient, namespace, database: string) =
  c.ns = namespace
  c.database = database

proc signin*(c: HttpClient, user, pass: string): Future[SurrealResult[JsonNode]] {.async.} =
  let body = %*[%*{
    "user": user,
    "pass": pass,
    "NS": c.ns,
    "DB": c.database
  }]
  let data = c.codec.marshalParams(body)
  let resp = await c.client.request(c.baseUrl & "/signin", HttpPost, body = data,
    headers = newHttpHeaders({"Content-Type": "application/json", "Accept": "application/json"}))
  if resp.status.startsWith("200"):
    let body = parseJson(await resp.body)
    if body.kind == JString:
      c.token = body.getStr()
    return ok(body)
  else:
    let errBody = await resp.body
    return err[JsonNode](parseStatusCode(resp.status), errBody)

proc signinNs*(c: HttpClient, ns, user, pass: string): Future[SurrealResult[JsonNode]] {.async.} =
  let body = %*[%*{
    "user": user,
    "pass": pass,
    "NS": ns
  }]
  let data = c.codec.marshalParams(body)
  let resp = await c.client.request(c.baseUrl & "/signin", HttpPost, body = data,
    headers = newHttpHeaders({"Content-Type": "application/json", "Accept": "application/json"}))
  if resp.status.startsWith("200"):
    let body = parseJson(await resp.body)
    if body.kind == JString:
      c.token = body.getStr()
    return ok(body)
  else:
    let errBody = await resp.body
    return err[JsonNode](parseStatusCode(resp.status), errBody)

proc signinDb*(c: HttpClient, ns, database, user, pass: string): Future[SurrealResult[JsonNode]] {.async.} =
  let body = %*[%*{
    "user": user,
    "pass": pass,
    "NS": ns,
    "DB": database
  }]
  let data = c.codec.marshalParams(body)
  let resp = await c.client.request(c.baseUrl & "/signin", HttpPost, body = data,
    headers = newHttpHeaders({"Content-Type": "application/json", "Accept": "application/json"}))
  if resp.status.startsWith("200"):
    let body = parseJson(await resp.body)
    if body.kind == JString:
      c.token = body.getStr()
    return ok(body)
  else:
    let errBody = await resp.body
    return err[JsonNode](parseStatusCode(resp.status), errBody)

proc signinRecord*(c: HttpClient, ns, database, access: string, params: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  let body = %*[%*{
    "NS": ns,
    "DB": database,
    "AC": access,
    "params": params
  }]
  let data = c.codec.marshalParams(body)
  let resp = await c.client.request(c.baseUrl & "/signin", HttpPost, body = data,
    headers = newHttpHeaders({"Content-Type": "application/json", "Accept": "application/json"}))
  if resp.status.startsWith("200"):
    let body = parseJson(await resp.body)
    if body.kind == JString:
      c.token = body.getStr()
    return ok(body)
  else:
    let errBody = await resp.body
    return err[JsonNode](parseStatusCode(resp.status), errBody)

proc signup*(c: HttpClient, ns, database, access: string, params: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  let body = %*[%*{
    "NS": ns,
    "DB": database,
    "AC": access,
    "params": params
  }]
  let data = c.codec.marshalParams(body)
  let resp = await c.client.request(c.baseUrl & "/signup", HttpPost, body = data,
    headers = newHttpHeaders({"Content-Type": "application/json", "Accept": "application/json"}))
  if resp.status.startsWith("200"):
    let body = parseJson(await resp.body)
    if body.kind == JString:
      c.token = body.getStr()
    return ok(body)
  else:
    let errBody = await resp.body
    return err[JsonNode](parseStatusCode(resp.status), errBody)

proc authenticate*(c: HttpClient, token: string): Future[SurrealResult[JsonNode]] {.async.} =
  c.token = token
  return ok(newJString(token))

proc invalidate*(c: HttpClient): Future[SurrealResult[JsonNode]] {.async.} =
  c.token = ""
  return ok(newJNull())

proc info*(c: HttpClient): Future[SurrealResult[JsonNode]] {.async.} =
  var headers = newHttpHeaders({
    "Surreal-NS": c.ns,
    "Surreal-DB": c.database,
    "Accept": "application/json"
  })
  if c.token.len > 0:
    headers["Authorization"] = "Bearer " & c.token
  let resp = await c.client.request(c.baseUrl & "/info", HttpGet, headers = headers)
  if resp.status.startsWith("200"):
    let body = parseJson(await resp.body)
    return ok(body)
  else:
    let errBody = await resp.body
    return err[JsonNode](parseStatusCode(resp.status), errBody)

proc version*(c: HttpClient): Future[SurrealResult[JsonNode]] {.async.} =
  var headers = newHttpHeaders({
    "Surreal-NS": c.ns,
    "Surreal-DB": c.database,
    "Accept": "application/json"
  })
  if c.token.len > 0:
    headers["Authorization"] = "Bearer " & c.token
  let resp = await c.client.request(c.baseUrl & "/version", HttpGet, headers = headers)
  if resp.status.startsWith("200"):
    let body = parseJson(await resp.body)
    return ok(body)
  else:
    let errBody = await resp.body
    return err[JsonNode](parseStatusCode(resp.status), errBody)

proc setVar*(c: HttpClient, name: string, value: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  return ok(newJNull())

proc unsetVar*(c: HttpClient, name: string): Future[SurrealResult[JsonNode]] {.async.} =
  return ok(newJNull())

proc query*(c: HttpClient, sql: string, vars: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  var headers = newHttpHeaders({
    "Content-Type": "application/json",
    "Surreal-NS": c.ns,
    "Surreal-DB": c.database,
    "Accept": "application/json"
  })
  if c.token.len > 0:
    headers["Authorization"] = "Bearer " & c.token
  var body: JsonNode
  if vars.len > 0:
    body = %*[sql, vars]
  else:
    body = %*[sql]
  let resp = await c.client.request(c.baseUrl & "/sql", HttpPost, body = $body, headers = headers)
  if resp.status.startsWith("200"):
    let body = parseJson(await resp.body)
    return ok(body)
  else:
    let errBody = await resp.body
    return err[JsonNode](parseStatusCode(resp.status), errBody)

proc query*(c: HttpClient, sql: SurQL, vars: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  result = await c.query(string(sql), vars)

proc select*(c: HttpClient, thing: string): Future[SurrealResult[JsonNode]] {.async.} =
  result = await c.query("SELECT * FROM " & thing)

proc select*(c: HttpClient, thing: RecordId): Future[SurrealResult[JsonNode]] {.async.} =
  result = await c.query("SELECT * FROM " & $thing)

proc select*(c: HttpClient, thing: DbTable): Future[SurrealResult[JsonNode]] {.async.} =
  result = await c.query("SELECT * FROM " & string(thing))

proc create*(c: HttpClient, thing: string, content: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  result = await c.query("CREATE " & thing & " CONTENT " & $content)

proc create*(c: HttpClient, thing: RecordId, content: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  result = await c.query("CREATE " & $thing & " CONTENT " & $content)

proc insert*(c: HttpClient, table: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  result = await c.query("INSERT INTO " & table & " " & $content)

proc insert*(c: HttpClient, tbl: DbTable, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  result = await c.insert(string(tbl), content)

proc update*(c: HttpClient, thing: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  result = await c.query("UPDATE " & thing & " CONTENT " & $content)

proc update*(c: HttpClient, thing: RecordId, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  result = await c.query("UPDATE " & $thing & " CONTENT " & $content)

proc upsert*(c: HttpClient, thing: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  result = await c.query("UPSERT " & thing & " CONTENT " & $content)

proc upsert*(c: HttpClient, thing: RecordId, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  result = await c.query("UPSERT " & $thing & " CONTENT " & $content)

proc merge*(c: HttpClient, thing: string, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  result = await c.query("MERGE " & thing & " CONTENT " & $content)

proc merge*(c: HttpClient, thing: RecordId, content: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  result = await c.query("MERGE " & $thing & " CONTENT " & $content)

proc patch*(c: HttpClient, thing: string, patches: JsonNode): Future[SurrealResult[JsonNode]] {.async.} =
  result = await c.query("PATCH " & thing & " " & $patches)

proc delete*(c: HttpClient, thing: string): Future[SurrealResult[JsonNode]] {.async.} =
  result = await c.query("DELETE FROM " & thing)

proc delete*(c: HttpClient, thing: RecordId): Future[SurrealResult[JsonNode]] {.async.} =
  result = await c.query("DELETE FROM " & $thing)

proc delete*(c: HttpClient, thing: DbTable): Future[SurrealResult[JsonNode]] {.async.} =
  result = await c.query("DELETE FROM " & string(thing))

proc relate*(c: HttpClient, source: string, relation: string, target: string,
            content: JsonNode = newJObject()): Future[SurrealResult[JsonNode]] {.async.} =
  result = await c.query("RELATE " & source & "->" & relation & "->" & target &
                         (if content.kind != JNull: " CONTENT " & $content else: ""))

proc live*(c: HttpClient, table: string, diff: bool = false): Future[SurrealResult[JsonNode]] {.async.} =
  return err[JsonNode](-1, "Live queries are not supported via HTTP")

proc kill*(c: HttpClient, liveId: string): Future[SurrealResult[JsonNode]] {.async.} =
  return err[JsonNode](-1, "Live queries are not supported via HTTP")

proc onNotification*(c: HttpClient, liveId: string, handler: LiveQueryHandler) =
  discard

proc offNotification*(c: HttpClient, liveId: string) =
  discard

proc run*(c: HttpClient, fnName: string, args: JsonNode = %[]): Future[SurrealResult[JsonNode]] {.async.} =
  return err[JsonNode](-1, "Custom functions (run) are not supported via HTTP")