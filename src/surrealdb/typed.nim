import std/[json, asyncdispatch, jsonutils, options]
import surrealdb/private/[types, connection]

export types, connection

proc toQueryResult*[T](raw: QueryResult[JsonNode]): QueryResult[T] {.raises: [CatchableError].} =
  result.status = raw.status
  result.time = raw.time
  if raw.status == "ERR":
    if raw.error != nil:
      result.error = raw.error
    elif raw.result != nil and raw.result.kind == JObject:
      result.error = parseServerError(raw.result)
    elif raw.result != nil and raw.result.kind == JString:
      result.error = ServerError(code: 0, message: raw.result.getStr(), kind: ekUnknown)
    else:
      result.error = ServerError(code: 0, message: "unknown query error", kind: ekUnknown)
  else:
    try:
      result.result = jsonTo(raw.result, T)
    except CatchableError as e:
      result.status = "ERR"
      result.error = ServerError(code: 0, message: "unmarshal error: " & e.msg, kind: ekInvalidData)

proc query*[T](db: Db, sql: string, vars: JsonNode = newJObject()): Future[SurrealResult[seq[QueryResult[T]]]] {.async.} =
  let raw = await connection.query(db, sql, vars)
  if not raw.isOk:
    return err[seq[QueryResult[T]]](raw.error.code, raw.error.message, raw.error.serverError)
  var outSeq: seq[QueryResult[T]]
  if raw.ok.kind == JArray:
    for item in raw.ok:
      let qr = jsonTo(item, QueryResult[JsonNode])
      outSeq.add toQueryResult[T](qr)
  result = ok(outSeq)

proc query*[T](db: Db, sql: SurQL, vars: JsonNode = newJObject()): Future[SurrealResult[seq[QueryResult[T]]]] {.async.} =
  result = await query[T](db, string(sql), vars)

proc query*[T](s: Session, sql: string, vars: JsonNode = newJObject()): Future[SurrealResult[seq[QueryResult[T]]]] {.async.} =
  let raw = await connection.query(s, sql, vars)
  if not raw.isOk:
    return err[seq[QueryResult[T]]](raw.error.code, raw.error.message, raw.error.serverError)
  var outSeq: seq[QueryResult[T]]
  if raw.ok.kind == JArray:
    for item in raw.ok:
      let qr = jsonTo(item, QueryResult[JsonNode])
      outSeq.add toQueryResult[T](qr)
  result = ok(outSeq)

proc query*[T](s: Session, sql: SurQL, vars: JsonNode = newJObject()): Future[SurrealResult[seq[QueryResult[T]]]] {.async.} =
  result = await query[T](s, string(sql), vars)

proc query*[T](tx: Transaction, sql: string, vars: JsonNode = newJObject()): Future[SurrealResult[seq[QueryResult[T]]]] {.async.} =
  let raw = await connection.query(tx, sql, vars)
  if not raw.isOk:
    return err[seq[QueryResult[T]]](raw.error.code, raw.error.message, raw.error.serverError)
  var outSeq: seq[QueryResult[T]]
  if raw.ok.kind == JArray:
    for item in raw.ok:
      let qr = jsonTo(item, QueryResult[JsonNode])
      outSeq.add toQueryResult[T](qr)
  result = ok(outSeq)

proc create*[T](db: Db, thing: string, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.create(db, thing, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc create*[T](db: Db, thing: RecordId, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.create(db, thing, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc select*[T](db: Db, thing: string, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.select(db, thing)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc select*[T](db: Db, thing: RecordId, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.select(db, thing)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc select*[T](db: Db, thing: DbTable, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.select(db, thing)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc update*[T](db: Db, thing: string, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.update(db, thing, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc update*[T](db: Db, thing: RecordId, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.update(db, thing, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc upsert*[T](db: Db, thing: string, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.upsert(db, thing, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc upsert*[T](db: Db, thing: RecordId, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.upsert(db, thing, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc merge*[T](db: Db, thing: string, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.merge(db, thing, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc merge*[T](db: Db, thing: RecordId, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.merge(db, thing, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc insert*[T](db: Db, table: string, content: JsonNode, _: typedesc[T]): Future[SurrealResult[seq[T]]] {.async.} =
  let raw = await connection.insert(db, table, content)
  if not raw.isOk:
    return err[seq[T]](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, seq[T]))
  except CatchableError as e:
    result = err[seq[T]](-1, "unmarshal error: " & e.msg)

proc insert*[T](db: Db, table: DbTable, content: JsonNode, _: typedesc[T]): Future[SurrealResult[seq[T]]] {.async.} =
  let raw = await connection.insert(db, table, content)
  if not raw.isOk:
    return err[seq[T]](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, seq[T]))
  except CatchableError as e:
    result = err[seq[T]](-1, "unmarshal error: " & e.msg)

proc delete*[T](db: Db, thing: string, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.delete(db, thing)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc delete*[T](db: Db, thing: RecordId, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.delete(db, thing)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc delete*[T](db: Db, thing: DbTable, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.delete(db, thing)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

# Session typed delegates
proc create*[T](s: Session, thing: string, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.create(s, thing, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc select*[T](s: Session, thing: string, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.select(s, thing)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc update*[T](s: Session, thing: string, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.update(s, thing, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc upsert*[T](s: Session, thing: string, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.upsert(s, thing, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc merge*[T](s: Session, thing: string, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.merge(s, thing, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc insert*[T](s: Session, table: string, content: JsonNode, _: typedesc[T]): Future[SurrealResult[seq[T]]] {.async.} =
  let raw = await connection.insert(s, table, content)
  if not raw.isOk:
    return err[seq[T]](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, seq[T]))
  except CatchableError as e:
    result = err[seq[T]](-1, "unmarshal error: " & e.msg)

proc delete*[T](s: Session, thing: string, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.delete(s, thing)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

# Transaction typed delegates
proc create*[T](tx: Transaction, thing: string, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.create(tx, thing, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc select*[T](tx: Transaction, thing: string, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.select(tx, thing)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc update*[T](tx: Transaction, thing: string, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.update(tx, thing, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc upsert*[T](tx: Transaction, thing: string, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.upsert(tx, thing, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc merge*[T](tx: Transaction, thing: string, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.merge(tx, thing, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc insert*[T](tx: Transaction, table: string, content: JsonNode, _: typedesc[T]): Future[SurrealResult[seq[T]]] {.async.} =
  let raw = await connection.insert(tx, table, content)
  if not raw.isOk:
    return err[seq[T]](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, seq[T]))
  except CatchableError as e:
    result = err[seq[T]](-1, "unmarshal error: " & e.msg)

proc delete*[T](tx: Transaction, thing: string, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.delete(tx, thing)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

# --- Missing RecordId/DbTable overloads for Session ---

proc create*[T](s: Session, thing: RecordId, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.create(s, thing, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc select*[T](s: Session, thing: RecordId, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.select(s, thing)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc select*[T](s: Session, thing: DbTable, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.select(s, thing)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc update*[T](s: Session, thing: RecordId, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.update(s, thing, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc upsert*[T](s: Session, thing: RecordId, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.upsert(s, thing, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc merge*[T](s: Session, thing: RecordId, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.merge(s, thing, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc insert*[T](s: Session, table: DbTable, content: JsonNode, _: typedesc[T]): Future[SurrealResult[seq[T]]] {.async.} =
  let raw = await connection.insert(s, table, content)
  if not raw.isOk:
    return err[seq[T]](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, seq[T]))
  except CatchableError as e:
    result = err[seq[T]](-1, "unmarshal error: " & e.msg)

proc delete*[T](s: Session, thing: RecordId, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.delete(s, thing)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc delete*[T](s: Session, thing: DbTable, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.delete(s, thing)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

# --- Missing RecordId/DbTable overloads for Transaction ---

proc create*[T](tx: Transaction, thing: RecordId, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.create(tx, thing, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc select*[T](tx: Transaction, thing: RecordId, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.select(tx, thing)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc select*[T](tx: Transaction, thing: DbTable, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.select(tx, thing)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc update*[T](tx: Transaction, thing: RecordId, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.update(tx, thing, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc upsert*[T](tx: Transaction, thing: RecordId, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.upsert(tx, thing, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc merge*[T](tx: Transaction, thing: RecordId, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.merge(tx, thing, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc insert*[T](tx: Transaction, table: DbTable, content: JsonNode, _: typedesc[T]): Future[SurrealResult[seq[T]]] {.async.} =
  let raw = await connection.insert(tx, table, content)
  if not raw.isOk:
    return err[seq[T]](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, seq[T]))
  except CatchableError as e:
    result = err[seq[T]](-1, "unmarshal error: " & e.msg)

proc delete*[T](tx: Transaction, thing: RecordId, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.delete(tx, thing)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc delete*[T](tx: Transaction, thing: DbTable, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.delete(tx, thing)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

# --- patch[T], relate[T], insertRelation[T] ---

proc patch*[T](db: Db, thing: string, patches: JsonNode, _: typedesc[T]): Future[SurrealResult[seq[T]]] {.async.} =
  let raw = await connection.patch(db, thing, patches)
  if not raw.isOk:
    return err[seq[T]](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, seq[T]))
  except CatchableError as e:
    result = err[seq[T]](-1, "unmarshal error: " & e.msg)

proc patch*[T](db: Db, thing: RecordId, patches: JsonNode, _: typedesc[T]): Future[SurrealResult[seq[T]]] {.async.} =
  let raw = await connection.patch(db, $thing, patches)
  if not raw.isOk:
    return err[seq[T]](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, seq[T]))
  except CatchableError as e:
    result = err[seq[T]](-1, "unmarshal error: " & e.msg)

proc patch*[T](s: Session, thing: string, patches: JsonNode, _: typedesc[T]): Future[SurrealResult[seq[T]]] {.async.} =
  let raw = await connection.patch(s, thing, patches)
  if not raw.isOk:
    return err[seq[T]](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, seq[T]))
  except CatchableError as e:
    result = err[seq[T]](-1, "unmarshal error: " & e.msg)

proc patch*[T](tx: Transaction, thing: string, patches: JsonNode, _: typedesc[T]): Future[SurrealResult[seq[T]]] {.async.} =
  let raw = await connection.patch(tx, thing, patches)
  if not raw.isOk:
    return err[seq[T]](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, seq[T]))
  except CatchableError as e:
    result = err[seq[T]](-1, "unmarshal error: " & e.msg)

proc relate*[T](db: Db, source: string, relation: string, target: string,
                content: JsonNode = newJObject(), _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.relate(db, source, relation, target, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc relate*[T](s: Session, source: string, relation: string, target: string,
                content: JsonNode = newJObject(), _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.relate(s, source, relation, target, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc relate*[T](tx: Transaction, source: string, relation: string, target: string,
                content: JsonNode = newJObject(), _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.relate(tx, source, relation, target, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc insertRelation*[T](db: Db, table: string, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.insertRelation(db, table, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc insertRelation*[T](s: Session, table: string, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.insertRelation(s, table, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc insertRelation*[T](tx: Transaction, table: string, content: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  let raw = await connection.insertRelation(tx, table, content)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

# --- Public generic Send[T] ---

const allowedSendMethods* = [
  "select", "create", "insert", "insert_relation",
  "kill", "live", "merge", "relate", "update", "upsert",
  "patch", "delete", "query",
]

proc send*[T](db: Db, rpcMethod: string, params: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  ## Low-level generic RPC call with method whitelist checking.
  ## Only methods listed in allowedSendMethods are permitted.
  ## Returns typed SurrealResult[T] by unmarshaling the JSON response.
  if not allowedSendMethods.contains(rpcMethod.toLowerAscii()):
    return err[T](-1, "method not allowed in Send: " & rpcMethod)
  let raw = await connection.send(db, rpcMethod, params)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)

proc send*[T](s: Session, rpcMethod: string, params: JsonNode, _: typedesc[T]): Future[SurrealResult[T]] {.async.} =
  if not allowedSendMethods.contains(rpcMethod.toLowerAscii()):
    return err[T](-1, "method not allowed in Send: " & rpcMethod)
  let raw = await connection.ssend(s, rpcMethod, params)
  if not raw.isOk:
    return err[T](raw.error.code, raw.error.message, raw.error.serverError)
  try:
    result = ok(jsonTo(raw.ok, T))
  except CatchableError as e:
    result = err[T](-1, "unmarshal error: " & e.msg)
