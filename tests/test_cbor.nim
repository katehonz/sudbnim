import std/[unittest, json, options, strutils, math]
import surrealdb/private/[types, surrealcbor, codec]

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
