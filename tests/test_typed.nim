import std/[unittest, json, strutils]
import surrealdb
import surrealdb/typed

type
  Person = object
    name: string
    age: int

suite "Typed wrappers":
  test "toQueryResult ok":
    let raw = QueryResult[JsonNode](status: "OK", time: "1ms", result: %*{"name": "Alice", "age": 30})
    let qr = toQueryResult[Person](raw)
    check qr.status == "OK"
    check qr.result.name == "Alice"
    check qr.result.age == 30
    check qr.error == nil

  test "toQueryResult err":
    let raw = QueryResult[JsonNode](status: "ERR", time: "1ms", result: %*"syntax error near 'FROM'")
    let qr = toQueryResult[Person](raw)
    check qr.status == "ERR"
    check qr.error != nil
    check qr.error.message == "syntax error near 'FROM'"

  test "toQueryResult unmarshal error":
    let raw = QueryResult[JsonNode](status: "OK", time: "1ms", result: %*{"name": "Alice", "age": "not_a_number"})
    let qr = toQueryResult[Person](raw)
    check qr.status == "ERR"
    check qr.error != nil
    check qr.error.message.contains("unmarshal error")

suite "send[T] generic RPC":
  test "allowedSendMethods contains all expected methods":
    check allowedSendMethods.contains("select")
    check allowedSendMethods.contains("create")
    check allowedSendMethods.contains("insert")
    check allowedSendMethods.contains("insert_relation")
    check allowedSendMethods.contains("kill")
    check allowedSendMethods.contains("live")
    check allowedSendMethods.contains("merge")
    check allowedSendMethods.contains("relate")
    check allowedSendMethods.contains("update")
    check allowedSendMethods.contains("upsert")
    check allowedSendMethods.contains("patch")
    check allowedSendMethods.contains("delete")
    check allowedSendMethods.contains("query")
    check allowedSendMethods.len == 13

  test "send[T] method whitelist is case-insensitive":
    let methods = ["SELECT", "Query", "PATCH", "Delete", "INSERT"]
    for m in methods:
      check allowedSendMethods.contains(m.toLowerAscii())

  test "send[T] rejects unauthorized method":
    check not allowedSendMethods.contains("nonexistent")
    check not allowedSendMethods.contains("signin")
    check not allowedSendMethods.contains("use")
    check not allowedSendMethods.contains("attach")
