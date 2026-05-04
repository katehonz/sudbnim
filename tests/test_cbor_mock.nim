import std/[unittest, json, strutils]
import surrealdb

suite "CBOR Codec Integration":
  test "newCborCodec creates CBOR codec":
    let c = newCborCodec()
    check c.isCbor()
    check not c.isJson()

  test "newJsonCodec creates JSON codec":
    let c = newJsonCodec()
    check c.isJson()
    check not c.isCbor()

  test "CBOR marshalRequest produces valid CBOR":
    let c = newCborCodec()
    let data = c.marshalRequest("test1", "version", newJArray())
    check data.len > 0
    # Verify it can be decoded
    let decoded = c.unmarshalResponse(data)
    check decoded["id"].getStr() == "test1"
    check decoded["method"].getStr() == "version"

  test "CBOR marshalRequest with session and txn":
    let c = newCborCodec()
    let data = c.marshalRequest("test2", "select",
      %*["user:alice"],
      sessionId = "session-001",
      txnId = "txn-001")
    check data.len > 0
    let decoded = c.unmarshalResponse(data)
    check decoded["id"].getStr() == "test2"
    check decoded["method"].getStr() == "select"
    check decoded["session"].getStr() == "session-001"
    check decoded["txn"].getStr() == "txn-001"

  test "CBOR marshalRequest without session/txn":
    let c = newCborCodec()
    let data = c.marshalRequest("test3", "query", %*["SELECT 1"])
    let decoded = c.unmarshalResponse(data)
    check decoded["id"].getStr() == "test3"
    check decoded["method"].getStr() == "query"
    check not decoded.hasKey("session")
    check not decoded.hasKey("txn")

  test "JSON marshalRequest produces correct JSON":
    let c = newJsonCodec()
    let data = c.marshalRequest("test4", "select", %*["user:alice"])
    check data.contains("\"id\":\"test4\"")
    check data.contains("\"method\":\"select\"")

  test "CBOR roundtrip RPC error response":
    let c = newCborCodec()
    let errResp = %*{
      "id": "err1",
      "error": {"code": -32000, "message": "something failed"}
    }
    let encoded = c.marshalParams(errResp)
    let decoded = c.unmarshalResponse(encoded)
    check decoded["id"].getStr() == "err1"
    check decoded["error"]["code"].getInt() == -32000

  test "CBOR roundtrip RPC result response":
    let c = newCborCodec()
    let okResp = %*{
      "id": "ok1",
      "result": {"name": "Alice", "age": 30}
    }
    let encoded = c.marshalParams(okResp)
    let decoded = c.unmarshalResponse(encoded)
    check decoded["id"].getStr() == "ok1"
    check decoded["result"]["name"].getStr() == "Alice"
    check decoded["result"]["age"].getInt() == 30

  test "CBOR is more compact than JSON for RPC requests":
    let cJson = newJsonCodec()
    let cCbor = newCborCodec()
    let params = %*["SELECT * FROM user WHERE age > 25"]
    let jsonData = cJson.marshalRequest("cmp1", "query", params)
    let cborData = cCbor.marshalRequest("cmp1", "query", params)
    check cborData.len < jsonData.len
