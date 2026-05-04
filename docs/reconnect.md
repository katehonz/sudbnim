# Reconnecting Connection

`ReconnectingDb` provides automatic reconnection with configurable retry strategies, inspired by the `rews` package from the [Go SurrealDB driver](https://github.com/surrealdb/surrealdb-go).

## Why Use Reconnecting?

SurrealDB WebSocket connections can drop due to:
- Network instability
- Server restarts
- Load balancer timeouts
- Deployments / rolling updates

`ReconnectingDb` transparently handles reconnection, restoring your session state so your application doesn't need to care about transient failures.

## Basic Usage

```nim
import std/[json, asyncdispatch]
import surrealdb

proc main() {.async.} =
  let rdb = newReconnectingDb("ws://localhost:8000")
  await rdb.start()           # Connect + start reconnection poll loop
  defer: rdb.disconnect()

  # Use + signin — namespace, database, and JWT token are captured
  discard await rdb.use("test", "test")
  discard await rdb.signin("root", "root")

  # Perform operations normally
  let users = await rdb.select(tb"user")
  echo users.ok

waitFor main()
```

## Retry Strategies

### No Retry (fail immediately)

```nim
let rdb = newReconnectingDb("ws://localhost:8000")
# retryer = nil → fails on first connection error
```

### Exponential Backoff

```nim
let retryer = ExponentialBackoff(
  initialDelay: 1.0,    # First retry after 1 second
  maxDelay: 30.0,        # Cap at 30 seconds
  multiplier: 2.0,       # Double delay each attempt
  maxRetries: 10,        # Give up after 10 attempts
                         # 0 = unlimited retries
  jitter: true           # Add ±30% random jitter to avoid thundering herd
)

let rdb = newReconnectingDb("ws://localhost:8000", retryer)
```

Retry progression with defaults:
```
Attempt 1: ~1.0s
Attempt 2: ~2.0s
Attempt 3: ~4.0s
Attempt 4: ~8.0s
Attempt 5: ~16.0s
Attempt 6: ~30.0s  (capped)
Attempt 7: ~30.0s
...
```

### Fixed Delay

```nim
let retryer = FixedDelay(
  delay: 5.0,            # Always wait 5 seconds
  maxRetries: 3           # Retry at most 3 times
)

let rdb = newReconnectingDb("ws://localhost:8000", retryer)
```

## Session State Restoration

On reconnection, `ReconnectingDb` automatically restores:

| State | Captured by | Restored via |
|---|---|---|
| Namespace & database | `rdb.use(ns, db)` | `rdb.use(ns, db)` |
| JWT token | `rdb.signin(...)` → `.ok` is `JString` | `rdb.authenticate(token)` |
| JWT token | `rdb.authenticate(token)` | `rdb.authenticate(token)` |
| Query variables | `rdb.setVar(name, val)` | `rdb.setVar(name, val)` |
| Live queries | `rdb.live(table, handler)` | Re-subscribed + handlers remapped |

### Token Capture Rules

Tokens are captured when the response is a **JString**:

```nim
# Captured (returns JWT string)
let r = await rdb.signin("root", "root")
let r = await rdb.signinNs("ns", "user", "pass")
let r = await rdb.signup("ns", "db", "access", params)

# Captured directly
await rdb.authenticate("my-jwt-token")
```

Token capture is automatic — you don't need to manually store it. On reconnect, the last captured token is re-sent with `authenticate()`.

### Live Query Replay

Live queries registered on `ReconnectingDb` are automatically re-subscribed after reconnection. Your handlers continue receiving notifications without any code changes:

```nim
var rdb = newReconnectingDb("ws://localhost:8000", retryer)
await rdb.start()

var notifications: seq[NotificationAction]
let lr = await rdb.live("user", handler = proc (action: NotificationAction, data: JsonNode) =
  notifications.add action
)

# If the connection drops and reconnects, the live query is re-registered
# and the handler continues to receive events.
```

### Variable Persistence

```nim
discard await rdb.setVar("api_version", %*"v2")
discard await rdb.setVar("tenant_id", %*"acme-123")

# After reconnect, both $api_version and $tenant_id are available
let r = await rdb.query("SELECT * FROM users WHERE tenant = $tenant_id")
```

## Reconnection Poll Loop

`ReconnectingDb` checks the connection every **5 seconds** via `reconnectLoop`:

```
[Connected] → wait 5s → isConnected? ──yes──→ wait 5s → ...
                                │
                                no
                                │
                                ↓
                        [Reconnecting]
                                │
                                ↓
                    connectWithRetry(attempt)
                                │
                    ┌─────success──────┐
                    │                  │
              [Connected]        retry? → yes → wait delay → try again
                                        → no  → [Disconnected]
```

## State Machine

```
stateDisconnected ──── connect() ────→ stateConnecting
                                              │
                                    ┌─ success ──┐
                                    ↓             ↓
                              stateConnected   retry exhausted → stateDisconnected
                                    │
                          connection lost
                                    │
                                    ↓
                              stateConnecting ──→ ...
```

Check current state:

```nim
case rdb.state
of stateDisconnected: echo "Not connected"
of stateConnecting: echo "Attempting to connect..."
of stateConnected: echo "Connected"
of stateClosing: echo "Shutting down..."
of stateClosed: echo "Closed"
```

## Error Handling

Each operation on `ReconnectingDb` checks if the underlying `Db` is available:

```nim
let r = await rdb.query("SELECT * FROM user")
# Returns SurrealResult[JsonNode] as normal
# If db is nil (never connected), returns an error result
```

If a query fails due to connection loss, the **reconnection happens in the background** (5-second poll loop). Your next request will use the reconnected session automatically.

## Reconnect Callback

You can register a callback that fires after each successful reconnection:

```nim
rdb.onReconnect = proc() =
  echo "Reconnected to SurrealDB!"
```

## Custom Connection Factory

For advanced use (custom headers, TLS, custom WebSocket factory):

```nim
# The underlying connect() proc is used internally.
# For custom needs, you can create a custom db and wrap it:

proc myConnect(): Future[Db] {.async.} =
  let db = await connect("ws://my-server:8000/rpc")
  # ... custom setup ...
  return db

# Or pre-connect and insert into ReconnectingDb
let rdb = newReconnectingDb("ws://localhost:8000", retryer)
await rdb.start()
# rdb.db is now available for direct operations if needed
```

## Graceful Shutdown

```nim
proc shutdown(rdb: ReconnectingDb) =
  echo "Shutting down..."
  rdb.disconnect()
  # rdb.state → stateClosed
  # Connection closed, reconnection loop stopped
  # No more operations possible
```

## Comparison: `Db` vs `ReconnectingDb`

| Feature | `Db` | `ReconnectingDb` |
|---|---|---|
| Reconnection | Manual | Automatic |
| Retry strategy | None | Configurable (exp.backoff, fixed) |
| Session restore | Manual | Automatic (ns, db, token, vars) |
| State tracking | `isConnected()` | `state` enum |
| Overhead | Minimal | 5-second poll timer |
| Use case | Simple scripts, tests | Production services |
