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
- 127 теста (58 unit + 33 mock + 6 typed + 21 CBOR + 9 CBOR codec)

### ⚠️ Частично направено (Phase 5)
- ✅ CBOR codec чрез cborious библиотека (surrealcbor.nim)
- ✅ CBOR encode/decode за JsonNode (primitives, arrays, maps, null, bool, int, float, string)
- ✅ SurrealDB CBOR tag константи (Tags 6-94)
- ✅ Codec abstraction (JSON vs CBOR) — codec.nim
- ✅ WebSocket binary frame integration (wsBinary opcode в connection.nim)
- ✅ Connection.nim CBOR mode — Db.codec field, connect(url, codec)
- ✅ CBOR RPC request/response roundtrip
- ✅ 30 CBOR теста
- 🔲 SurrealDB type → tagged CBOR encoding (RecordId → tag 8, UUID → tag 37)
- 🔲 Two-phase CBOR unmarshal за typed wrappers

### ❌ Оставащо (сравнено с Go драйвъра)
- CBOR SurrealDB type-aware encoding (RecordId → tag 8, UUID → tag 37)
- HTTP connection backend (Nim е WebSocket-only)

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

## Phase 5: CBOR поддръжка (В ПРОГРЕС)

### ✅ Завършено
- CBOR codec чрез `cborious` библиотека (surrealcbor.nim)
- JsonNode ↔ CBOR roundtrip (primitives, arrays, maps)
- SurrealDB CBOR tag константи (Tags 6,7,8,9,10,12,13,14,15,37,49,50,51,88-94)
- Tag encoding за SurrealDB типове (RecordId, Table, UUID, DateTime, Duration, Geometry и др.)
- Tag decoding с dispatch по tag number
- NONE (Tag 6) → null handling
- Codec abstraction (JSON vs CBOR) — codec.nim
- 21 CBOR теста

### 🔲 Оставащо
- WebSocket binary frame integration (wsBinary opcode в websocket.nim)
- Connection.nim CBOR mode (автоматично използване на CBOR при `?codec=cbor`)
- Two-phase CBOR unmarshal за typed wrappers
- SurrealDB type → tagged CBOR encoding (RecordId → tag 8 и т.н.)
- HTTP connection backend

---

## Оценка на усилието

| Phase | Статус | Оценка |
|---|---|---|
| Phase 1: Типове | ✅ Завършен | — |
| Phase 2: Session API | ✅ Завършен | — |
| Phase 3: Typed wrappers | ✅ Завършен | — |
| Phase 4: Query система | ✅ Завършен | — |
| Phase 5: CBOR | ⚠️ В прогрес | ~50% готово, остава WS integration |

---

## Критерии за успех

- ✅ Всички съществуващи тестове минават (86 теста)
- ✅ Нови тестове за всеки Phase (Session auth, RecordId/DbTable overloads, SurrealString)
- ❌ Документацията (`docs/*.md`) е актуализирана
- ✅ API-то е backwards compatible (стар код работи без промени)
