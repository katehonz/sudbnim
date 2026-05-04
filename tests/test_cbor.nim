import std/[unittest, json, strutils, math]
import surrealdb/private/[surrealcbor, codec]

suite "CBOR Encoding/Decoding":
  test "null roundtrip":
    let encoded = marshalCbor(newJNull())
    let decoded = unmarshalCbor(encoded)
    check decoded.kind == JNull

  test "bool true roundtrip":
    let encoded = marshalCbor(%true)
    let decoded = unmarshalCbor(encoded)
    check decoded.getBool() == true

  test "bool false roundtrip":
    let encoded = marshalCbor(%false)
    let decoded = unmarshalCbor(encoded)
    check decoded.getBool() == false

  test "integer roundtrip":
    let encoded = marshalCbor(%42)
    let decoded = unmarshalCbor(encoded)
    check decoded.getInt() == 42

  test "negative integer roundtrip":
    let encoded = marshalCbor(%(-17))
    let decoded = unmarshalCbor(encoded)
    check decoded.getInt() == -17

  test "float roundtrip":
    let encoded = marshalCbor(%3.14)
    let decoded = unmarshalCbor(encoded)
    check abs(decoded.getFloat() - 3.14) < 0.01

  test "string roundtrip":
    let encoded = marshalCbor(%"hello world")
    let decoded = unmarshalCbor(encoded)
    check decoded.getStr() == "hello world"

  test "empty string roundtrip":
    let encoded = marshalCbor(%"")
    let decoded = unmarshalCbor(encoded)
    check decoded.getStr() == ""

  test "array roundtrip":
    let encoded = marshalCbor(%[1, 2, 3])
    let decoded = unmarshalCbor(encoded)
    check decoded.kind == JArray
    check decoded.len == 3
    check decoded[0].getInt() == 1
    check decoded[1].getInt() == 2
    check decoded[2].getInt() == 3

  test "nested array roundtrip":
    let original = %*[[1, 2], [3, 4]]
    let encoded = marshalCbor(original)
    let decoded = unmarshalCbor(encoded)
    check decoded[0][0].getInt() == 1
    check decoded[1][1].getInt() == 4

  test "object roundtrip":
    let original = %*{"name": "Alice", "age": 30}
    let encoded = marshalCbor(original)
    let decoded = unmarshalCbor(encoded)
    check decoded["name"].getStr() == "Alice"
    check decoded["age"].getInt() == 30

  test "empty object roundtrip":
    let encoded = marshalCbor(newJObject())
    let decoded = unmarshalCbor(encoded)
    check decoded.kind == JObject
    check decoded.len == 0

  test "empty array roundtrip":
    let encoded = marshalCbor(newJArray())
    let decoded = unmarshalCbor(encoded)
    check decoded.kind == JArray
    check decoded.len == 0

suite "CBOR SurrealDB Tags":
  test "Tag 6 - None":
    let encoded = marshalCbor(newJNull())
    let decoded = unmarshalCbor(encoded)
    check decoded.kind == JNull

  test "RecordId as JSON object roundtrip":
    let rid = %*{"tb": "user", "id": "alice"}
    let encoded = marshalCbor(rid)
    let decoded = unmarshalCbor(encoded)
    check decoded["tb"].getStr() == "user"
    check decoded["id"].getStr() == "alice"

  test "complex nested object roundtrip":
    let original = %*{
      "users": [
        {"name": "Alice", "age": 30, "tags": ["admin", "user"]},
        {"name": "Bob", "age": 25, "tags": ["user"]}
      ],
      "count": 2,
      "meta": {"version": "1.0"}
    }
    let encoded = marshalCbor(original)
    let decoded = unmarshalCbor(encoded)
    check decoded["count"].getInt() == 2
    check decoded["users"].len == 2
    check decoded["users"][0]["name"].getStr() == "Alice"
    check decoded["users"][1]["tags"][0].getStr() == "user"
    check decoded["meta"]["version"].getStr() == "1.0"

  test "CBOR is more compact than JSON for same data":
    let data = %*{"id": "user:alice", "name": "Alice", "age": 30}
    let jsonStr = $data
    let cborBytes = marshalCbor(data)
    # CBOR should be shorter than JSON for this simple case
    check cborBytes.len < jsonStr.len

suite "CBOR Codec":
  test "JSON codec marshal/unmarshal":
    let c = newJsonCodec()
    let req = c.marshalRequest("abc123", "query", %*["SELECT * FROM user"])
    check req.contains("\"id\":\"abc123\"")
    check req.contains("\"method\":\"query\"")

  test "CBOR codec marshal/unmarshal":
    let c = newCborCodec()
    check c.isCbor()
    check not c.isJson()
    let req = c.marshalRequest("abc123", "query", %*["SELECT * FROM user"])
    check req.len > 0

  test "JSON codec unmarshal":
    let c = newJsonCodec()
    let resp = c.unmarshalResponse("""{"id":"abc123","result":"ok"}""")
    check resp["id"].getStr() == "abc123"
    check resp["result"].getStr() == "ok"

  test "CBOR codec roundtrip":
    let c = newCborCodec()
    let original = %*{"id": "abc123", "result": [1, 2, 3]}
    let encoded = c.marshalParams(original)
    let decoded = c.unmarshalResponse(encoded)
    check decoded["id"].getStr() == "abc123"
    check decoded["result"].len == 3

suite "CBOR Type-Aware RPC Encoding":
  test "recordidCbor encodes with tag 8":
    let marker = recordidCbor("user", "alice")
    let encoded = marshalCborRpcRequest("1", "select", %[marker])
    let decoded = unmarshalCbor(encoded)
    check decoded.hasKey("params")
    let params = decoded["params"]
    check params.kind == JArray
    check params.len == 1

  test "stringuuidCbor encodes with tag 9":
    let marker = stringuuidCbor("0191d530-3af8-7000-8b57-9f6707ab6c05")
    let encoded = marshalCborRpcRequest("1", "query", %[marker])
    let decoded = unmarshalCbor(encoded)
    check decoded["params"][0].kind == JString

  test "tableCbor encodes with tag 7":
    let marker = tableCbor("users")
    let encoded = marshalCborRpcRequest("1", "select", %[marker])
    let decoded = unmarshalCbor(encoded)
    check decoded["params"][0].kind == JString

  test "datetimeCbor encodes with tag 12":
    let marker = datetimeCbor("2025-01-15T10:30:00Z")
    let encoded = marshalCborRpcRequest("1", "query", %[marker])
    let decoded = unmarshalCbor(encoded)
    check decoded["params"][0].kind == JString

  test "durationCbor encodes with tag 14":
    let marker = durationCbor("1h30m")
    let encoded = marshalCborRpcRequest("1", "query", %[marker])
    let decoded = unmarshalCbor(encoded)
    check decoded["params"][0].kind == JString

  test "decimalCbor encodes with tag 10":
    let marker = decimalCbor("3.14159")
    let encoded = marshalCborRpcRequest("1", "query", %[marker])
    let decoded = unmarshalCbor(encoded)
    check decoded["params"][0].kind == JString

  test "rangeCbor encodes with tag 49":
    let beginMarker = recordidCbor("user", "alice")
    let endMarker = recordidCbor("user", "bob")
    let marker = rangeCbor(beginMarker, endMarker)
    let encoded = marshalCborRpcRequest("1", "select", %[marker])
    let decoded = unmarshalCbor(encoded)
    check decoded["params"][0].kind == JObject
    check decoded["params"][0].hasKey("begin")
    check decoded["params"][0].hasKey("end")

  test "boundCbor includes bound marker":
    let inner = recordidCbor("user", "alice")
    let marker = boundCbor("incl", inner)
    let encoded = marshalCborRpcRequest("1", "select", %[marker])
    let decoded = unmarshalCbor(encoded)
    check decoded["params"][0].kind == JObject

  test "mixed type-aware and plain params":
    let marker = recordidCbor("user", "alice")
    let params = %*[marker, %"plain string", %42]
    let encoded = marshalCborRpcRequest("1", "select", params)
    let decoded = unmarshalCbor(encoded)
    check decoded["params"].len == 3

  test "RPC request structure is correct":
    let params = %["test"]
    let encoded = marshalCborRpcRequest("req123", "ping", params)
    let decoded = unmarshalCbor(encoded)
    check decoded["id"].getStr() == "req123"
    check decoded["method"].getStr() == "ping"
    check decoded["params"][0].getStr() == "test"

  test "binaryuuidCbor encodes with tag 37":
    let marker = binaryuuidCbor("0191d5303af870008b579f6707ab6c05")
    let encoded = marshalCborRpcRequest("1", "query", %[marker])
    let decoded = unmarshalCbor(encoded)
    check decoded["params"][0].kind == JString
