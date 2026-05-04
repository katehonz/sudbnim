import std/[asyncnet, asyncdispatch, nativesockets, random, uri, strutils, base64, streams]

type
  WSOpcode* = enum
    wsCont = 0x0, wsText = 0x1, wsBinary = 0x2, wsClose = 0x8, wsPing = 0x9, wsPong = 0xa

  WSState* = enum
    wsConnecting, wsOpen, wsClosing, wsClosed

  WSError* = object of IOError
  WSClosedError* = object of WSError

  WsFrame = tuple[fin: bool, opcode: WSOpcode, data: string]

  WSClient* = ref object
    socket*: AsyncSocket
    state*: WSState
    masked*: bool

proc genMaskKey(): array[4, char] =
  for i in 0..3: result[i] = char(rand(255))

proc encodeFrame(client: WSClient, opcode: WSOpcode, data: string): string =
  var ret = newStringStream()
  ret.write((opcode.uint8 or 0x80).uint8)
  var b1 = 0u8
  if data.len <= 125: b1 = data.len.uint8
  elif data.len <= 0xffff: b1 = 126u8
  else: b1 = 127u8
  if client.masked: b1 = b1 or (1 shl 7)
  ret.write(b1)
  if data.len > 125:
    if data.len <= 0xffff: ret.write(htons(data.len.uint16))
    else:
      let n = data.len
      ret.write(char((n shr 56) and 255))
      ret.write(char((n shr 48) and 255))
      ret.write(char((n shr 40) and 255))
      ret.write(char((n shr 32) and 255))
      ret.write(char((n shr 24) and 255))
      ret.write(char((n shr 16) and 255))
      ret.write(char((n shr 8) and 255))
      ret.write(char(n and 255))
  var d = data
  if client.masked:
    let mk = genMaskKey()
    for i in 0..<d.len: d[i] = (d[i].uint8 xor mk[i mod 4].uint8).char
    ret.write(mk)
  ret.write(d)
  ret.setPosition(0); result = ret.readAll()

proc sendWs*(c: WSClient, data: string, opcode: WSOpcode = wsText) {.async.} =
  if c.state != wsOpen: return
  try:
    let frame = c.encodeFrame(opcode, data)
    await c.socket.send(frame)
  except: c.state = wsClosed

proc recvFrame(c: WSClient): Future[WsFrame] {.async.} =
  if c.state == wsClosed: raise newException(WSClosedError, "Socket closed")
  var header: string
  try: header = await c.socket.recv(2)
  except:
    c.state = wsClosed
    raise newException(WSClosedError, "Socket closed")
  if header.len != 2:
    c.state = wsClosed
    raise newException(WSClosedError, "Socket closed")
  let b0 = header[0].uint8; let b1 = header[1].uint8
  result.fin = (b0 and 0x80) != 0
  {.push warning[HoleEnumConv]: off.}
  result.opcode = (b0 and 0x0f).WSOpcode
  {.pop.}
  let hasMask = (b1 and 0x80) != 0
  var finalLen: uint = 0
  let hl = uint(b1 and 0x7f)
  if hl == 0x7e:
    var l = await c.socket.recv(2)
    if l.len != 2: c.state = wsClosed; raise newException(WSClosedError, "Socket closed")
    finalLen = cast[ptr uint16](l[0].addr)[].htons
  elif hl == 0x7f:
    var l = await c.socket.recv(8)
    if l.len != 8: c.state = wsClosed; raise newException(WSClosedError, "Socket closed")
    finalLen = cast[ptr uint32](l[4].addr)[].htonl
  else: finalLen = hl
  var mk = ""
  if hasMask:
    mk = await c.socket.recv(4)
    if mk.len != 4: c.state = wsClosed; raise newException(WSClosedError, "Socket closed")
  var d = await c.socket.recv(int(finalLen))
  if d.len != int(finalLen): c.state = wsClosed; raise newException(WSClosedError, "Socket closed")
  if hasMask:
    for i in 0..<d.len: d[i] = (d[i].uint8 xor mk[i mod 4].uint8).char
  result.data = d

proc receivePacket*(c: WSClient): Future[(WSOpcode, string)] {.async.} =
  var frame = await c.recvFrame()
  result = (frame.opcode, frame.data)
  while not frame.fin:
    frame = await c.recvFrame()
    if frame.opcode != wsCont:
      raise newException(WSClosedError, "Expected continuation frame")
    result[1].add(frame.data)

proc pingWs*(c: WSClient, data = "") {.async.} =
  await c.sendWs(data, wsPing)

proc setupPings*(c: WSClient, seconds: float) =
  proc loop() {.async.} =
    while c.state != wsClosed:
      await c.pingWs()
      await sleepAsync(int(seconds * 1000))
  asyncCheck loop()

proc closeWs*(c: WSClient) =
  c.state = wsClosed
  try: c.socket.close()
  except: discard

proc newWsClient*(url: string): Future[WSClient] {.async.} =
  var client = WSClient(masked: true, state: wsConnecting)
  var uri = parseUri(url)
  var port = Port(80)
  case uri.scheme
  of "ws": port = Port(80)
  of "wss":
    port = Port(443)
    raise newException(WSError, "wss not supported yet")
  else: raise newException(WSError, "Invalid scheme: " & uri.scheme)
  if uri.port.len > 0: port = Port(parseInt(uri.port))
  let host = uri.hostname
  let path = if uri.path.len > 0: uri.path else: "/"
  client.socket = newAsyncSocket()
  await client.socket.connect(host, port)
  var secStr = newString(16)
  for i in 0..<secStr.len: secStr[i] = char(rand(255))
  let secKey = encode(secStr)
  var req = "GET " & path & " HTTP/1.1\r\n"
  req.add("Host: " & host & ":" & $port.uint16 & "\r\n")
  req.add("Connection: Upgrade\r\n")
  req.add("Upgrade: websocket\r\n")
  req.add("Sec-WebSocket-Version: 13\r\n")
  req.add("Sec-WebSocket-Key: " & secKey & "\r\n")
  req.add("\r\n")
  await client.socket.send(req)
  var response = ""
  while true:
    let line = await client.socket.recvLine()
    if line.len == 0: break
    if line == "\r\n": break
    response.add(line & "\n")
  if not response.contains("101"):
    client.socket.close()
    raise newException(WSError, "WebSocket upgrade failed")
  client.state = wsOpen
  result = client
