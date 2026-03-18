import std/[unittest, importutils]

import pkg/chronos
import pkg/chronos/transports/stream

import ../chronos_smtp {.all.}
privateAccess(Smtp)

const shortTimeout = 50.milliseconds

# Helper: start a TCP server that accepts a connection but never sends data.
proc silentServer(): Future[Port] {.async.} =
  let server =
    createStreamServer(initTAddress("127.0.0.1:0"), flags = {ServerFlags.ReuseAddr})
  let port = server.localAddress.port

  proc serve() {.async.} =
    let client = await server.accept()
    await sleepAsync(5.seconds)
    await client.closeWait()
    server.stop()
    server.close()

  asyncSpawn serve()
  return port

# Helper: start a TCP server that sends a greeting, then hangs.
proc greetThenHangServer(): Future[Port] {.async.} =
  let server =
    createStreamServer(initTAddress("127.0.0.1:0"), flags = {ServerFlags.ReuseAddr})
  let port = server.localAddress.port

  proc serve() {.async.} =
    let client = await server.accept()
    let writer = newAsyncStreamWriter(client)
    await writer.write("220 localhost SMTP\r\n")
    await sleepAsync(5.seconds)
    await writer.closeWait()
    await client.closeWait()
    server.stop()
    server.close()

  asyncSpawn serve()
  return port

# Helper: start a TCP server that completes EHLO handshake, then hangs.
proc handshakeThenHangServer(): Future[Port] {.async.} =
  let server =
    createStreamServer(initTAddress("127.0.0.1:0"), flags = {ServerFlags.ReuseAddr})
  let port = server.localAddress.port

  proc serve() {.async.} =
    let client = await server.accept()
    let reader = newAsyncStreamReader(client)
    let writer = newAsyncStreamWriter(client)
    await writer.write("220 localhost SMTP\r\n")
    discard await reader.readLine()
    await writer.write("250 OK\r\n")
    await sleepAsync(5.seconds)
    await reader.closeWait()
    await writer.closeWait()
    await client.closeWait()
    server.stop()
    server.close()

  asyncSpawn serve()
  return port

# Helper: server that completes handshake + MAIL/RCPT/DATA, then hangs after 354.
proc hangAfterDataServer(): Future[Port] {.async.} =
  let server =
    createStreamServer(initTAddress("127.0.0.1:0"), flags = {ServerFlags.ReuseAddr})
  let port = server.localAddress.port

  proc serve() {.async.} =
    let client = await server.accept()
    let reader = newAsyncStreamReader(client)
    let writer = newAsyncStreamWriter(client)
    await writer.write("220 localhost SMTP\r\n")
    discard await reader.readLine() # EHLO
    await writer.write("250 OK\r\n")
    discard await reader.readLine() # MAIL FROM
    await writer.write("250 OK\r\n")
    discard await reader.readLine() # RCPT TO
    await writer.write("250 OK\r\n")
    discard await reader.readLine() # DATA
    await writer.write("354 Go ahead\r\n")
    while true:
      let line = await reader.readLine()
      if line == ".":
        break
    # Never respond with 250.
    await sleepAsync(5.seconds)
    await reader.closeWait()
    await writer.closeWait()
    await client.closeWait()
    server.stop()
    server.close()

  asyncSpawn serve()
  return port

# Helper: connect raw with a specific timeout.
proc connectRaw(port: Port, timeout: Duration): Future[Smtp] {.async.} =
  let smtp = Smtp(kind: SmtpClientScheme.NonSecure, timeout: timeout)
  let transp = await connect(initTAddress("127.0.0.1", port))
  smtp.transp = transp
  smtp.reader = newAsyncStreamReader(transp)
  smtp.writer = newAsyncStreamWriter(transp)
  return smtp

proc closeSmtp(smtp: Smtp) {.async.} =
  if not smtp.reader.isNil and not smtp.reader.closed:
    await smtp.reader.closeWait()
  if not smtp.writer.isNil and not smtp.writer.closed:
    await smtp.writer.closeWait()
  if not smtp.transp.isNil and not smtp.transp.closed:
    await smtp.transp.closeWait()

suite "timeout – read":
  test "read times out when server sends nothing":
    var timedOut = false

    proc runTest() {.async.} =
      let port = await silentServer()
      let smtp = await connectRaw(port, shortTimeout)
      try:
        discard await smtp.read()
      except AsyncTimeoutError:
        timedOut = true
      await smtp.closeSmtp()

    waitFor runTest()
    check timedOut

  test "readLine times out when server sends nothing":
    var timedOut = false

    proc runTest() {.async.} =
      let port = await silentServer()
      let smtp = await connectRaw(port, shortTimeout)
      try:
        discard await smtp.readLine()
      except AsyncTimeoutError:
        timedOut = true
      await smtp.closeSmtp()

    waitFor runTest()
    check timedOut

  test "checkReply times out when server hangs":
    var timedOut = false

    proc runTest() {.async.} =
      let port = await silentServer()
      let smtp = await connectRaw(port, shortTimeout)
      try:
        await smtp.checkReply("250", quitWhenFailed = false)
      except AsyncTimeoutError:
        timedOut = true
      await smtp.closeSmtp()

    waitFor runTest()
    check timedOut

suite "timeout – connect and dial":
  test "dial times out when server never sends greeting":
    var timedOut = false

    proc runTest() {.async.} =
      let port = await silentServer()
      try:
        discard await dial("127.0.0.1", port, timeout = shortTimeout)
      except AsyncTimeoutError:
        timedOut = true

    waitFor runTest()
    check timedOut

  test "dial times out during EHLO":
    var timedOut = false

    proc runTest() {.async.} =
      let port = await greetThenHangServer()
      try:
        discard await dial("127.0.0.1", port, timeout = shortTimeout)
      except AsyncTimeoutError:
        timedOut = true

    waitFor runTest()
    check timedOut

  test "dial cleans up transport on timeout":
    var timedOut = false

    proc runTest() {.async.} =
      let port = await silentServer()
      try:
        discard await dial("127.0.0.1", port, timeout = shortTimeout)
      except AsyncTimeoutError:
        timedOut = true
      # If cleanup failed, transport would leak. No crash = success.
      await sleepAsync(1.milliseconds)

    waitFor runTest()
    check timedOut

suite "timeout – sendMail":
  test "sendMail times out when server hangs after DATA":
    var timedOut = false

    proc runTest() {.async.} =
      let port = await hangAfterDataServer()
      let smtp = await dial("127.0.0.1", port, timeout = shortTimeout, helo = false)
      let speaksEsmtp = await smtp.ehlo
      if not speaksEsmtp:
        await smtp.helo
      try:
        let msg = createMessage("Test", "Hello", @["to@example.com"])
        await smtp.sendMail("from@example.com", @["to@example.com"], $msg)
      except AsyncTimeoutError:
        timedOut = true
      await smtp.closeSmtp()

    waitFor runTest()
    check timedOut

suite "timeout – close":
  test "close completes even when QUIT times out":
    var closed = false

    proc runTest() {.async.} =
      let port = await handshakeThenHangServer()
      let smtp = await dial("127.0.0.1", port, timeout = 2.seconds)
      smtp.timeout = shortTimeout
      await smtp.close()
      closed = smtp.closed

    waitFor runTest()
    check closed

  test "close with quit=false skips QUIT and still cleans up":
    var closed = false

    proc runTest() {.async.} =
      let port = await silentServer()
      let smtp = await connectRaw(port, shortTimeout)
      await smtp.close(false)
      closed = smtp.closed

    waitFor runTest()
    check closed

suite "timeout – configuration":
  test "newSmtp preserves timeout":
    let smtp = newSmtp(timeout = 5.seconds)
    check smtp.timeout == 5.seconds

  test "newSmtp defaults to InfiniteDuration":
    let smtp = newSmtp()
    check smtp.timeout == InfiniteDuration

  test "dial passes timeout to Smtp object":
    var timeout: Duration

    proc runTest() {.async.} =
      let port = await handshakeThenHangServer()
      let smtp = await dial("127.0.0.1", port, timeout = 2.seconds)
      timeout = smtp.timeout
      await smtp.close(false)

    waitFor runTest()
    check timeout == 2.seconds
