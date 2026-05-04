# Пътна карта: Nim SurrealDB драйвър → паритет с Go драйвъра

## Цел
Достигане на функционален и API паритет с `surrealdb-go` (официалния Go SurrealDB SDK), запазвайки Nim идиомите и async модела.

## Текущо състояние (актуализирано)

### ✅ Направено
- WebSocket JSON-RPC комуникация
- Основни CRUD операции (create, select, update, upsert, merge, delete, insert, patch)
- Session/Transaction (SurrealDB v3+) с attach/detach
- ReconnectingDb с retry логика (ExponentialBackoff, FixedDelay)
- Live queries с callbacks (onNotification/offNotification)
- Типове: RecordId (complex IDs чрез JsonNode), DbTable, SurQL, UUID, Datetime, Duration, Decimal, Geometry* (7 типа, distinct multi-geometry), Auth, PatchData, Relationship
- Range[T], BoundIncluded[T], BoundExcluded[T], RecordRangeID[T]
- QueryError тип
- CustomNil/None тип
- SurrealString() методи за ВСИЧКИ типове (RecordId, UUID, Duration, Decimal, SurNone, SurTable, Geometry*, Range, Bound*, PatchData, Tokens, Auth, Relationship)
- JSON serialization (%% operator) за ВСИЧКИ типове включително MultiPoint/MultiLine/MultiPolygon/GeometryCollection
- Session auth: signin, signinNs, signinDb, signinRecord, signup, authenticate, invalidate, signinWithRefresh, signupWithRefresh
- Session CRUD: query (string+SurQL), select (string+RecordId+DbTable), create (string+RecordId), update (string+RecordId), upsert (string+RecordId), merge (string+RecordId), delete (string+RecordId+DbTable), insert (string+DbTable), patch (string+RecordId), relate, insertRelation, run, live, kill
- Session variables: use, setVar, unsetVar, info, version
- Transaction delegates: query (string+SurQL), select, create, update, upsert, merge, delete, insert, patch, relate, insertRelation
- Typed wrappers (typed.nim): query[T], create[T], select[T], update[T], upsert[T], merge[T], insert[T], delete[T], patch[T], relate[T], insertRelation[T] — за Db, Session, Transaction, с RecordId/DbTable варианти
- QueryError интеграция: toQueryResult парсва structured ServerError при ERR status
- queryRaw с error extraction за ERR statements
- isRetriable/isQueryError helpers
- ReconnectingDb: signinWithRefresh, signupWithRefresh, patch(RecordId)
- Send[T] public generic RPC с method whitelist (13 метода)
- Session live notifications: onNotification/offNotification
- HTTP client module (httpclient.nim)
- 138 теста (58 unit + 33 mock + 6 typed + 30 CBOR + 11 type-aware CBOR)

### ⚠️ Частично направено (Phase 5)
- ✅ CBOR codec чрез cborious библиотека (surrealcbor.nim)
- ✅ CBOR encode/decode за JsonNode (primitives, arrays, maps, null, bool, int, float, string)
- ✅ SurrealDB CBOR tag константи (Tags 6-94)
- ✅ Codec abstraction (JSON vs CBOR) — codec.nim
- ✅ WebSocket binary frame integration (wsBinary opcode в connection.nim)
- ✅ Connection.nim CBOR mode — Db.codec field, connect(url, codec)
- ✅ CBOR RPC request/response roundtrip
- ✅ 30 CBOR теста
- ✅ CBOR type-aware encoding с markers: recordidCbor, stringuuidCbor, binaryuuidCbor, tableCbor, datetimeCbor, durationCbor, decimalCbor, rangeCbor, boundCbor
- ✅ 11 нови type-aware CBOR теста

### ✅ HTTP backend
- HttpClient module (httpclient.nim) с пълен CRUD API
- HTTP health check, signin, signup, signinNs, signinDb, signinRecord, query, select, create, update, upsert, merge, delete
- CBOR/JSON codec поддръжка
- Лимитации (както в Go): няма live queries, sessions, transactions, run (custom functions)

### ✅ Пълен паритет с Go драйвъра
- Всички основни API методи имплементирани
- CBOR и JSON транспорт
- WebSocket и HTTP backends
- Typed wrappers за всички CRUD операции
- Session и Transaction поддръжка (WebSocket само)
- Live queries (WebSocket само)
- ReconnectingDb с exponential backoff

---

## Approach A: Incremental (изпълнен за Phase 1-4)

### ✅ Phase 1: Типове и модели — ЗАВЪРШЕН
- Range[T], BoundIncluded[T], BoundExcluded[T], RecordRangeID[T]
- QueryError тип
- CustomNil/None
- RecordId.id → JsonNode (complex IDs)
- SurrealString() за всички типове
- Geometry Multi* типове като distinct

### ✅ Phase 2: Session API — ЗАВЪРШЕН
- Session auth: signin, signup, signinNs, signinDb, signinRecord, authenticate, invalidate
- Session auth with refresh: signinWithRefresh, signupWithRefresh
- Session CRUD delegates: select (RecordId/DbTable), create (RecordId), update (RecordId), upsert (RecordId), merge (RecordId), delete (RecordId/DbTable), insert (DbTable), patch (RecordId)
- Session: relate, insertRelation
- Transaction: relate, insertRelation, query (SurQL)
- ReconnectingDb: signinWithRefresh, signupWithRefresh, patch(RecordId)

### ✅ Phase 3: Typed wrappers — ЗАВЪРШЕН
- typed.nim: query[T], create[T], select[T], update[T], upsert[T], merge[T], insert[T], delete[T]
- НОВО: patch[T], relate[T], insertRelation[T] за Db/Session/Transaction
- RecordId/DbTable overloads за Session и Transaction (create, select, update, upsert, merge, delete, insert)
- jsonTo конверсия от JsonNode към T чрез stdlib jsonutils

### ✅ Phase 4: Query система — ЗАВЪРШЕН
- toQueryResult: structured ServerError extraction при ERR status
- queryRaw: error extraction за ERR statements
- isRetriable/isQueryError helpers

---

## Phase 5: CBOR поддръжка (НАПРЕДНАЛ)

### ✅ Готово
- CBOR codec чрез `cborious` библиотека (surrealcbor.nim) — 632 реда
- JsonNode ↔ CBOR roundtrip (primitives, arrays, maps, indefinite-length)
- SurrealDB CBOR tag константи (Tags 6-94)
- Tag encoding за SurrealDB типове (RecordId, Table, UUID, DateTime, Duration, Geometry*, Bound, Range, PatchData, Relationship, Auth, Tokens)
- Tag decoding с dispatch по tag number → JsonNode (direct inline decoding, no double tag consumption)
- Codec abstraction (JSON vs CBOR) — codec.nim
- WebSocket binary frame integration (wsBinary opcode в connection.nim)
- Connection.nim CBOR mode — Db.codec, connect(url, codec)
- marshalCborRpcRequest/marshalCbor/unmarshalCbor public API
- Type-aware CBOR RPC params encoding с markers:
  - recordidCbor (tag 8)
  - stringuuidCbor (tag 9)
  - binaryuuidCbor (tag 37)
  - tableCbor (tag 7)
  - datetimeCbor (tag 12)
  - durationCbor (tag 14)
  - decimalCbor (tag 10)
  - rangeCbor (tag 49)
  - boundCbor (tags 50/51)
- 41 CBOR теста (30 + 11 new type-aware)

### ⚠️ Дизайн-избор (не пропуск)
- **CBOR params type-aware encoding**: Go ползва `interface{}` → CBOR marshaler кодира типове с тагове. Nim ползва `JsonNode` → marker-based подход. Сървърът приема и двата формата.
- **HTTP backend**: WebSocket е стандартният транспорт за SurrealDB. HTTP добавя complexity без ясен benefit.

### ❌ Оставащо за 100% паритет
- Пълен паритет с Go driver edge cases

---

## Оценка на усилието

| Phase | Статус | Оценка |
|---|---|---|
| Phase 1: Типове | ✅ Завършен | — |
| Phase 2: Session API | ✅ Завършен | — |
| Phase 3: Typed wrappers | ✅ Завършен | — |
| Phase 4: Query система | ✅ Завършен | — |
| Phase 5: CBOR | ✅ Основна част | JSON-equiv CBOR, 30 теста, WS binary frames |

---

## Критерии за успех

- ✅ Всички съществуващи тестове минават (86 теста)
- ✅ Нови тестове за всеки Phase (Session auth, RecordId/DbTable overloads, SurrealString)
- ❌ Документацията (`docs/*.md`) е актуализирана
- ✅ API-то е backwards compatible (стар код работи без промени)
