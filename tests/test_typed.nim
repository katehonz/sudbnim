import std/[unittest, json, asyncdispatch, strutils]
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
