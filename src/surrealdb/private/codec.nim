## Codec abstraction — allows switching between JSON and CBOR wire formats.
import std/[json]
import ./surrealcbor

type
  CodecKind* = enum
    ckJson = "json"
    ckCbor = "cbor"

  Codec* = ref object
    kind*: CodecKind

proc newJsonCodec*(): Codec = Codec(kind: ckJson)
proc newCborCodec*(): Codec = Codec(kind: ckCbor)

proc marshalRequest*(c: Codec, id: string, rpcMethod: string, params: JsonNode,
                     sessionId: string = "", txnId: string = ""): string =
  case c.kind
  of ckJson:
    var req = %*{"id": id, "method": rpcMethod, "params": params}
    if sessionId.len > 0: req["session"] = %*sessionId
    if txnId.len > 0: req["txn"] = %*txnId
    result = $req
  of ckCbor:
    result = surrealcbor.marshalCborRpcRequest(id, rpcMethod, params, sessionId, txnId)

proc unmarshalResponse*(c: Codec, data: string): JsonNode =
  case c.kind
  of ckJson:
    result = parseJson(data)
  of ckCbor:
    result = surrealcbor.unmarshalCbor(data)

proc marshalParams*(c: Codec, node: JsonNode): string =
  case c.kind
  of ckJson: result = $node
  of ckCbor: result = surrealcbor.marshalCbor(node)

proc isCbor*(c: Codec): bool = c.kind == ckCbor
proc isJson*(c: Codec): bool = c.kind == ckJson
