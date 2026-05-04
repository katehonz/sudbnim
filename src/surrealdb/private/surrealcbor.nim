## SurrealDB CBOR codec — encoding/decoding SurrealDB types via CBOR tags.
## Uses cborious as the base CBOR library.
import std/[json, strutils, streams, sequtils, options]
import cborious
import ./types

const
  TagNone* = 6'u64
  TagTable* = 7'u64
  TagRecordID* = 8'u64
  TagStringUUID* = 9'u64
  TagStringDecimal* = 10'u64
  TagCustomDatetime* = 12'u64
  TagStringDuration* = 13'u64
  TagCustomDuration* = 14'u64
  TagFuture* = 15'u64
  TagSpecBinaryUUID* = 37'u64
  TagRange* = 49'u64
  TagBoundIncluded* = 50'u64
  TagBoundExcluded* = 51'u64
  TagGeometryPoint* = 88'u64
  TagGeometryLine* = 89'u64
  TagGeometryPolygon* = 90'u64
  TagGeometryMultiPoint* = 91'u64
  TagGeometryMultiLine* = 92'u64
  TagGeometryMultiPolygon* = 93'u64
  TagGeometryCollection* = 94'u64

proc cborPackSurrealValue*(s: CborStream, node: JsonNode)
proc cborUnpackSurrealValue*(s: CborStream): JsonNode

# --- Tag encoding ---

proc cborPackNone*(s: CborStream) =
  s.cborPackTag(CborTag(TagNone))
  s.cborPackNull()

proc cborPackTable*(s: CborStream, t: DbTable) =
  s.cborPackTag(CborTag(TagTable))
  s.cborPack(string(t))

proc cborPackRecordId*(s: CborStream, rid: RecordId) =
  s.cborPackTag(CborTag(TagRecordID))
  s.cborPack(@[rid.table, $rid.id])

proc cborPackStringUUID*(s: CborStream, u: UUID) =
  s.cborPackTag(CborTag(TagStringUUID))
  s.cborPack(string(u))

proc cborPackStringDecimal*(s: CborStream, d: Decimal) =
  s.cborPackTag(CborTag(TagStringDecimal))
  s.cborPack(string(d))

proc cborPackDatetime*(s: CborStream, dt: Datetime) =
  s.cborPackTag(CborTag(TagCustomDatetime))
  s.cborPack(string(dt))

proc cborPackStringDuration*(s: CborStream, d: Duration) =
  s.cborPackTag(CborTag(TagStringDuration))
  s.cborPack(string(d))

proc cborPackFuture*(s: CborStream, f: SurFuture) =
  s.cborPackTag(CborTag(TagFuture))
  s.cborPack(string(f))

proc cborPackGeometryPoint*(s: CborStream, gp: GeometryPoint) =
  s.cborPackTag(CborTag(TagGeometryPoint))
  s.cborPack(@[gp.longitude, gp.latitude])

proc cborPackGeometryLine*(s: CborStream, gl: GeometryLine) =
  s.cborPackTag(CborTag(TagGeometryLine))
  s.cborPack(gl.mapIt(@[it.longitude, it.latitude]))

proc cborPackGeometryPolygon*(s: CborStream, gp: GeometryPolygon) =
  s.cborPackTag(CborTag(TagGeometryPolygon))
  s.cborPack(gp.mapIt(it.mapIt(@[it.longitude, it.latitude])))

proc cborPackGeometryMultiPoint*(s: CborStream, gm: GeometryMultiPoint) =
  s.cborPackTag(CborTag(TagGeometryMultiPoint))
  s.cborPack(seq[GeometryPoint](gm).mapIt(@[it.longitude, it.latitude]))

proc cborPackGeometryMultiLine*(s: CborStream, gm: GeometryMultiLine) =
  s.cborPackTag(CborTag(TagGeometryMultiLine))
  s.cborPack(seq[GeometryLine](gm).mapIt(it.mapIt(@[it.longitude, it.latitude])))

proc cborPackGeometryMultiPolygon*(s: CborStream, gm: GeometryMultiPolygon) =
  s.cborPackTag(CborTag(TagGeometryMultiPolygon))
  s.cborPack(seq[GeometryPolygon](gm).mapIt(it.mapIt(it.mapIt(@[it.longitude, it.latitude]))))

proc cborPackGeometryCollection*(s: CborStream, gc: GeometryCollection) =
  s.cborPackTag(CborTag(TagGeometryCollection))
  s.cborPackSurrealValue(gc.geometries)

proc cborPackBoundIncluded*(s: CborStream, val: JsonNode) =
  s.cborPackTag(CborTag(TagBoundIncluded))
  s.cborPackSurrealValue(val)

proc cborPackBoundExcluded*(s: CborStream, val: JsonNode) =
  s.cborPackTag(CborTag(TagBoundExcluded))
  s.cborPackSurrealValue(val)

proc cborPackRange*(s: CborStream, r: Range) =
  s.cborPackTag(CborTag(TagRange))
  s.cborPackSurrealValue(r.beginBound)
  s.cborPackSurrealValue(r.endBound)

proc cborPackPatchData*(s: CborStream, pd: PatchData) =
  s.cborPackInt(3, CborMajor.Array)
  s.cborPack(pd.op)
  s.cborPack(pd.path)
  s.cborPackSurrealValue(pd.value)

proc cborPackRelationship*(s: CborStream, rel: Relationship) =
  var mapLen = 3
  if rel.id.isSome: inc mapLen
  if rel.data != nil and rel.data.kind != JObject: inc mapLen
  elif rel.data != nil and rel.data.len > 0: inc mapLen
  s.cborPackInt(mapLen.uint64, CborMajor.Map)
  if rel.id.isSome:
    s.cborPack("id")
    s.cborPackRecordId(rel.id.get)
  s.cborPack("in")
  s.cborPackRecordId(rel.inRec)
  s.cborPack("out")
  s.cborPackRecordId(rel.outRec)
  s.cborPack("relation")
  s.cborPackTable(rel.relation)
  if rel.data != nil and (rel.data.kind != JObject or rel.data.len > 0):
    s.cborPack("data")
    s.cborPackSurrealValue(rel.data)

proc cborPackAuth*(s: CborStream, a: Auth) =
  var mapLen = 0
  if a.namespace.isSome: inc mapLen
  if a.database.isSome: inc mapLen
  if a.scope.isSome: inc mapLen
  if a.access.isSome: inc mapLen
  if a.username.isSome: inc mapLen
  if a.password.isSome: inc mapLen
  s.cborPackInt(mapLen.uint64, CborMajor.Map)
  if a.namespace.isSome: s.cborPack("NS"); s.cborPack(a.namespace.get)
  if a.database.isSome: s.cborPack("DB"); s.cborPack(a.database.get)
  if a.scope.isSome: s.cborPack("SC"); s.cborPack(a.scope.get)
  if a.access.isSome: s.cborPack("AC"); s.cborPack(a.access.get)
  if a.username.isSome: s.cborPack("user"); s.cborPack(a.username.get)
  if a.password.isSome: s.cborPack("pass"); s.cborPack(a.password.get)

proc cborPackTokens*(s: CborStream, t: Tokens) =
  s.cborPackInt(2, CborMajor.Map)
  s.cborPack("access")
  s.cborPack(t.access)
  s.cborPack("refresh")
  s.cborPack(t.refresh)

# --- Tag decoding ---

proc cborUnpackNone*(s: CborStream): JsonNode =
  s.cborExpectTag(CborTag(TagNone))
  var dummy: string
  try: s.cborUnpack(dummy) except: discard
  result = newJNull()

proc cborUnpackTable*(s: CborStream): DbTable =
  s.cborExpectTag(CborTag(TagTable))
  var name: string
  s.cborUnpack(name)
  result = DbTable(name)

proc cborUnpackRecordId*(s: CborStream): RecordId =
  s.cborExpectTag(CborTag(TagRecordID))
  var parts: seq[string]
  s.cborUnpack(parts)
  if parts.len >= 2:
    result = RecordId(table: parts[0], id: %*parts[1])

proc cborUnpackStringUUID*(s: CborStream): UUID =
  s.cborExpectTag(CborTag(TagStringUUID))
  var val: string
  s.cborUnpack(val)
  result = UUID(val)

proc cborUnpackStringDecimal*(s: CborStream): Decimal =
  s.cborExpectTag(CborTag(TagStringDecimal))
  var val: string
  s.cborUnpack(val)
  result = Decimal(val)

proc cborUnpackDatetime*(s: CborStream): Datetime =
  s.cborExpectTag(CborTag(TagCustomDatetime))
  var val: string
  s.cborUnpack(val)
  result = Datetime(val)

proc cborUnpackStringDuration*(s: CborStream): Duration =
  s.cborExpectTag(CborTag(TagStringDuration))
  var val: string
  s.cborUnpack(val)
  result = Duration(val)

proc cborUnpackFuture*(s: CborStream): SurFuture =
  s.cborExpectTag(CborTag(TagFuture))
  var val: string
  s.cborUnpack(val)
  result = SurFuture(val)

proc cborUnpackGeometryPoint*(s: CborStream): GeometryPoint =
  s.cborExpectTag(CborTag(TagGeometryPoint))
  var coords: seq[float64]
  s.cborUnpack(coords)
  if coords.len >= 2:
    result = GeometryPoint(longitude: coords[0], latitude: coords[1])

proc cborUnpackGeometryLine*(s: CborStream): GeometryLine =
  s.cborExpectTag(CborTag(TagGeometryLine))
  var coords: seq[seq[float64]]
  s.cborUnpack(coords)
  for c in coords:
    if c.len >= 2:
      result.add(GeometryPoint(longitude: c[0], latitude: c[1]))

proc cborUnpackGeometryPolygon*(s: CborStream): GeometryPolygon =
  s.cborExpectTag(CborTag(TagGeometryPolygon))
  var rings: seq[seq[seq[float64]]]
  s.cborUnpack(rings)
  for ring in rings:
    var line: GeometryLine
    for c in ring:
      if c.len >= 2:
        line.add(GeometryPoint(longitude: c[0], latitude: c[1]))
    result.add(line)

proc cborUnpackGeometryMultiPoint*(s: CborStream): GeometryMultiPoint =
  s.cborExpectTag(CborTag(TagGeometryMultiPoint))
  var coords: seq[seq[float64]]
  s.cborUnpack(coords)
  var points: seq[GeometryPoint]
  for c in coords:
    if c.len >= 2:
      points.add(GeometryPoint(longitude: c[0], latitude: c[1]))
  result = GeometryMultiPoint(points)

proc cborUnpackGeometryMultiLine*(s: CborStream): GeometryMultiLine =
  s.cborExpectTag(CborTag(TagGeometryMultiLine))
  var lines: seq[seq[seq[float64]]]
  s.cborUnpack(lines)
  var gLines: seq[GeometryLine]
  for line in lines:
    var gl: GeometryLine
    for c in line:
      if c.len >= 2:
        gl.add(GeometryPoint(longitude: c[0], latitude: c[1]))
    gLines.add(gl)
  result = GeometryMultiLine(gLines)

proc cborUnpackGeometryMultiPolygon*(s: CborStream): GeometryMultiPolygon =
  s.cborExpectTag(CborTag(TagGeometryMultiPolygon))
  var polys: seq[seq[seq[seq[float64]]]]
  s.cborUnpack(polys)
  var gPolys: seq[GeometryPolygon]
  for poly in polys:
    var gp: GeometryPolygon
    for ring in poly:
      var gl: GeometryLine
      for c in ring:
        if c.len >= 2:
          gl.add(GeometryPoint(longitude: c[0], latitude: c[1]))
      gp.add(gl)
    gPolys.add(gp)
  result = GeometryMultiPolygon(gPolys)

proc cborUnpackGeometryCollection*(s: CborStream): GeometryCollection =
  s.cborExpectTag(CborTag(TagGeometryCollection))
  result = GeometryCollection(geometries: s.cborUnpackSurrealValue())

# --- JsonNode CBOR encode/decode (recursive) ---

proc cborPackSurrealValue*(s: CborStream, node: JsonNode) =
  if node.isNil:
    s.cborPackNull()
    return
  case node.kind
  of JNull: s.cborPackNull()
  of JBool: s.cborPack(node.getBool())
  of JInt: s.cborPack(node.getInt())
  of JFloat: s.cborPack(node.getFloat())
  of JString: s.cborPack(node.getStr())
  of JArray:
    s.cborPackInt(node.len.uint64, CborMajor.Array)
    for item in node:
      s.cborPackSurrealValue(item)
  of JObject:
    s.cborPackInt(node.len.uint64, CborMajor.Map)
    for key, val in node:
      s.cborPack(key)
      s.cborPackSurrealValue(val)

proc cborUnpackSurrealValue*(s: CborStream): JsonNode =
  let (major, ai) = s.readInitial()
  case major
  of CborMajor.Unsigned:
    let val = s.readAddInfo(ai)
    result = %val.int64
  of CborMajor.Negative:
    let val = s.readAddInfo(ai)
    result = %(-1 - val.int64)
  of CborMajor.Binary:
    var bytes: seq[byte]
    s.setPosition(s.getPosition() - 1)
    s.cborUnpack(bytes)
    result = %bytes
  of CborMajor.String:
    var str: string
    s.setPosition(s.getPosition() - 1)
    s.cborUnpack(str)
    result = %str
  of CborMajor.Array:
    if ai == AiIndef:
      result = newJArray()
      while true:
        let (m, a) = s.readInitial()
        if m == CborMajor.Simple and a == 0x1f: break
        s.setPosition(s.getPosition() - 1)
        result.add(s.cborUnpackSurrealValue())
    else:
      let arrLen = s.readAddInfo(ai).int
      result = newJArray()
      for i in 0..<arrLen:
        result.add(s.cborUnpackSurrealValue())
  of CborMajor.Map:
    if ai == AiIndef:
      result = newJObject()
      while true:
        let (m, a) = s.readInitial()
        if m == CborMajor.Simple and a == 0x1f: break
        s.setPosition(s.getPosition() - 1)
        var key: string
        s.cborUnpack(key)
        result[key] = s.cborUnpackSurrealValue()
    else:
      let mapLen = s.readAddInfo(ai).int
      result = newJObject()
      for i in 0..<mapLen:
        var key: string
        s.cborUnpack(key)
        result[key] = s.cborUnpackSurrealValue()
  of CborMajor.Tag:
    let tagNum = s.readAddInfo(ai)
    case tagNum
    of TagRecordID:
      var parts: seq[string]
      s.cborUnpack(parts)
      if parts.len >= 2:
        result = %*{"tb": parts[0], "id": %*parts[1]}
      else:
        result = newJNull()
    of TagStringUUID:
      var val: string
      s.cborUnpack(val)
      result = %val
    of TagStringDecimal:
      var val: string
      s.cborUnpack(val)
      result = %val
    of TagCustomDatetime:
      var val: string
      s.cborUnpack(val)
      result = %val
    of TagStringDuration:
      var val: string
      s.cborUnpack(val)
      result = %val
    of TagFuture:
      var val: string
      s.cborUnpack(val)
      result = %val
    of TagSpecBinaryUUID:
      var bytes: seq[byte]
      s.cborUnpack(bytes)
      result = %bytes.mapIt(it.toHex(2)).join("").toLowerAscii()
    of TagRange:
      var beginBound = s.cborUnpackSurrealValue()
      var endBound = s.cborUnpackSurrealValue()
      result = %*{"begin": beginBound, "end": endBound}
    of TagBoundIncluded:
      result = %*{"incl": s.cborUnpackSurrealValue()}
    of TagBoundExcluded:
      result = %*{"excl": s.cborUnpackSurrealValue()}
    of TagGeometryPoint:
      var coords: seq[float64]
      s.cborUnpack(coords)
      if coords.len >= 2:
        result = %*{"type": "Point", "coordinates": [coords[0], coords[1]]}
      else:
        result = newJNull()
    of TagGeometryLine:
      var coords: seq[seq[float64]]
      s.cborUnpack(coords)
      var gl: GeometryLine
      for c in coords:
        if c.len >= 2:
          gl.add(GeometryPoint(longitude: c[0], latitude: c[1]))
      result = %*{"type": "LineString", "coordinates": gl.mapIt([it.longitude, it.latitude])}
    of TagGeometryPolygon:
      var rings: seq[seq[seq[float64]]]
      s.cborUnpack(rings)
      var gp: GeometryPolygon
      for ring in rings:
        var line: GeometryLine
        for c in ring:
          if c.len >= 2:
            line.add(GeometryPoint(longitude: c[0], latitude: c[1]))
        gp.add(line)
      result = %*{"type": "Polygon", "coordinates": gp.mapIt(it.mapIt([it.longitude, it.latitude]))}
    of TagGeometryMultiPoint:
      var coords: seq[seq[float64]]
      s.cborUnpack(coords)
      var points: seq[GeometryPoint]
      for c in coords:
        if c.len >= 2:
          points.add(GeometryPoint(longitude: c[0], latitude: c[1]))
      result = %*{"type": "MultiPoint", "coordinates": points.mapIt([it.longitude, it.latitude])}
    of TagGeometryMultiLine:
      var lines: seq[seq[seq[float64]]]
      s.cborUnpack(lines)
      var gLines: seq[GeometryLine]
      for line in lines:
        var gl: GeometryLine
        for c in line:
          if c.len >= 2:
            gl.add(GeometryPoint(longitude: c[0], latitude: c[1]))
        gLines.add(gl)
      result = %*{"type": "MultiLineString", "coordinates": gLines.mapIt(it.mapIt([it.longitude, it.latitude]))}
    of TagGeometryMultiPolygon:
      var polys: seq[seq[seq[seq[float64]]]]
      s.cborUnpack(polys)
      var gPolys: seq[GeometryPolygon]
      for poly in polys:
        var gp: GeometryPolygon
        for ring in poly:
          var gl: GeometryLine
          for c in ring:
            if c.len >= 2:
              gl.add(GeometryPoint(longitude: c[0], latitude: c[1]))
          gp.add(gl)
        gPolys.add(gp)
      result = %*{"type": "MultiPolygon", "coordinates": gPolys.mapIt(it.mapIt(it.mapIt([it.longitude, it.latitude])))}
    of TagGeometryCollection:
      result = %*{"type": "GeometryCollection", "geometries": s.cborUnpackSurrealValue()}
    of TagNone:
      var dummy: string
      s.cborUnpack(dummy)
      result = newJNull()
    of TagTable:
      var name: string
      s.cborUnpack(name)
      result = %name
    else:
      result = s.cborUnpackSurrealValue()
  of CborMajor.Simple:
    case ai
    of 20: result = %false
    of 21: result = %true
    of 22, 23: result = newJNull()
    else:
      if ai == 25:
        var f: float32
        s.setPosition(s.getPosition() - 1)
        s.cborUnpack(f)
        result = %f.float64
      elif ai == 26:
        var f: float32
        s.setPosition(s.getPosition() - 1)
        s.cborUnpack(f)
        result = %f.float64
      elif ai == 27:
        var f: float64
        s.setPosition(s.getPosition() - 1)
        s.cborUnpack(f)
        result = %f
      else:
        result = newJNull()

# --- Type-aware params encoding for RPC ---

const
  MarkerRecordId* = "#recordid"
  MarkerStringUuid* = "#stringuuid"
  MarkerBinaryUuid* = "#binaryuuid"
  MarkerTable* = "#table"
  MarkerDatetime* = "#datetime"
  MarkerDuration* = "#duration"
  MarkerDecimal* = "#decimal"
  MarkerRange* = "#range"
  MarkerBound* = "#bound"

proc cborPackRpcValue*(s: CborStream, node: JsonNode) =
  if node.isNil:
    s.cborPackNull()
    return
  case node.kind
  of JNull: s.cborPackNull()
  of JBool: s.cborPack(node.getBool())
  of JInt: s.cborPack(node.getInt())
  of JFloat: s.cborPack(node.getFloat())
  of JString: s.cborPack(node.getStr())
  of JArray:
    s.cborPackInt(node.len.uint64, CborMajor.Array)
    for item in node:
      s.cborPackRpcValue(item)
  of JObject:
    if node.hasKey(MarkerRecordId):
      let inner = node[MarkerRecordId]
      if inner.kind == JObject and inner.hasKey("tb") and inner.hasKey("id"):
        s.cborPackTag(CborTag(TagRecordID))
        s.cborPack(@[inner["tb"].getStr(), inner["id"].getStr()])
      else:
        s.cborPackSurrealValue(node)
    elif node.hasKey(MarkerStringUuid):
      let inner = node[MarkerStringUuid]
      s.cborPackTag(CborTag(TagStringUUID))
      s.cborPack(inner.getStr())
    elif node.hasKey(MarkerBinaryUuid):
      let inner = node[MarkerBinaryUuid]
      s.cborPackTag(CborTag(TagSpecBinaryUUID))
      var bytes: seq[byte]
      if inner.kind == JString:
        let hex = inner.getStr()
        for i in countup(0, hex.len - 1, 2):
          bytes.add(parseHexInt(hex.substr(i, i + 1)).uint8)
      elif inner.kind == JArray:
        for b in inner:
          bytes.add(b.getInt().uint8)
      s.cborPack(bytes)
    elif node.hasKey(MarkerTable):
      let inner = node[MarkerTable]
      s.cborPackTag(CborTag(TagTable))
      s.cborPack(inner.getStr())
    elif node.hasKey(MarkerDatetime):
      let inner = node[MarkerDatetime]
      s.cborPackTag(CborTag(TagCustomDatetime))
      s.cborPack(inner.getStr())
    elif node.hasKey(MarkerDuration):
      let inner = node[MarkerDuration]
      s.cborPackTag(CborTag(TagCustomDuration))
      s.cborPack(inner.getStr())
    elif node.hasKey(MarkerDecimal):
      let inner = node[MarkerDecimal]
      s.cborPackTag(CborTag(TagStringDecimal))
      s.cborPack(inner.getStr())
    elif node.hasKey(MarkerRange):
      let inner = node[MarkerRange]
      s.cborPackTag(CborTag(TagRange))
      if inner.kind == JArray and inner.len == 2:
        s.cborPackRpcValue(inner[0])
        s.cborPackRpcValue(inner[1])
    elif node.hasKey(MarkerBound):
      let inner = node[MarkerBound]
      if inner.kind == JObject:
        if inner.hasKey("incl"):
          s.cborPackTag(CborTag(TagBoundIncluded))
          s.cborPackRpcValue(inner["incl"])
        elif inner.hasKey("excl"):
          s.cborPackTag(CborTag(TagBoundExcluded))
          s.cborPackRpcValue(inner["excl"])
        else:
          s.cborPackSurrealValue(node)
      else:
        s.cborPackSurrealValue(node)
    else:
      s.cborPackSurrealValue(node)

# --- Public API ---

proc marshalCbor*(node: JsonNode): string =
  var s = CborStream.init(1024)
  s.cborPackSurrealValue(node)
  result = s.data

proc unmarshalCbor*(data: string): JsonNode =
  var s = CborStream.init(data)
  s.setPosition(0)
  result = s.cborUnpackSurrealValue()

proc marshalCborRpcRequest*(id: string, rpcMethod: string, params: JsonNode,
                            sessionId: string = "", txnId: string = ""): string =
  var mapLen = 3
  if sessionId.len > 0: inc mapLen
  if txnId.len > 0: inc mapLen
  var s = CborStream.init(512)
  s.cborPackInt(mapLen.uint64, CborMajor.Map)
  s.cborPack("id")
  s.cborPack(id)
  s.cborPack("method")
  s.cborPack(rpcMethod)
  s.cborPack("params")
  s.cborPackRpcValue(params)
  if sessionId.len > 0:
    s.cborPack("session")
    s.cborPack(sessionId)
  if txnId.len > 0:
    s.cborPack("txn")
    s.cborPack(txnId)
  result = s.data

proc recordidCbor*(table: string, id: string): JsonNode =
  result = %*{MarkerRecordId: {"tb": table, "id": id}}

proc stringuuidCbor*(u: string): JsonNode =
  result = %*{MarkerStringUuid: u}

proc binaryuuidCbor*(hex: string): JsonNode =
  result = %*{MarkerBinaryUuid: hex}

proc tableCbor*(t: string): JsonNode =
  result = %*{MarkerTable: t}

proc datetimeCbor*(dt: string): JsonNode =
  result = %*{MarkerDatetime: dt}

proc durationCbor*(d: string): JsonNode =
  result = %*{MarkerDuration: d}

proc decimalCbor*(dec: string): JsonNode =
  result = %*{MarkerDecimal: dec}

proc rangeCbor*(rangebegin, rangeend: JsonNode): JsonNode =
  var arr = newJArray()
  arr.add(rangebegin)
  arr.add(rangeend)
  result = %*{MarkerRange: arr}

proc boundCbor*(kind: string, val: JsonNode): JsonNode =
  result = %*{MarkerBound: {"kind": val}}
