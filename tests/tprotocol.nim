import std/[strutils, unittest, importutils]

import pkg/chronos
import pkg/chronos/transports/stream

import ../chronos_smtp {.all.}
privateAccess(Smtp)

# Helper: a server that responds to EHLO with multiline 250 capabilities.
proc ehloServer(capabilities: seq[string]): Future[Port] {.async.} =
  let server =
    createStreamServer(initTAddress("127.0.0.1:0"), flags = {ServerFlags.ReuseAddr})
  let port = server.localAddress.port

  proc serve() {.async.} =
    let client = await server.accept()
    let reader = newAsyncStreamReader(client)
    let writer = newAsyncStreamWriter(client)

    await writer.write("220 localhost SMTP\r\n")
    discard await reader.readLine() # EHLO

    for i, cap in capabilities:
      if i < capabilities.len - 1:
        await writer.write("250-" & cap & "\r\n")
      else:
        await writer.write("250 " & cap & "\r\n")

    try:
      discard await reader.readLine() # QUIT or other
    except AsyncStreamReadError:
      discard

    await reader.closeWait()
    await writer.closeWait()
    await client.closeWait()
    server.stop()
    server.close()

  asyncSpawn serve()
  return port

# Helper: a server that rejects EHLO (returns 500), then accepts HELO.
proc ehloFallbackServer(gotHelo: ptr bool): Future[Port] {.async.} =
  let server =
    createStreamServer(initTAddress("127.0.0.1:0"), flags = {ServerFlags.ReuseAddr})
  let port = server.localAddress.port

  proc serve() {.async.} =
    let client = await server.accept()
    let reader = newAsyncStreamReader(client)
    let writer = newAsyncStreamWriter(client)

    await writer.write("220 localhost SMTP\r\n")
    discard await reader.readLine() # EHLO
    await writer.write("500 Command not recognized\r\n")

    let heloLine = await reader.readLine() # HELO
    if heloLine.startsWith("HELO"):
      if not gotHelo.isNil:
        gotHelo[] = true
      await writer.write("250 OK\r\n")

    try:
      discard await reader.readLine() # QUIT
    except AsyncStreamReadError:
      discard

    await reader.closeWait()
    await writer.closeWait()
    await client.closeWait()
    server.stop()
    server.close()

  asyncSpawn serve()
  return port

# Helper: a server that accepts LHLO.
proc lhloServer(gotLhlo: ptr bool): Future[Port] {.async.} =
  let server =
    createStreamServer(initTAddress("127.0.0.1:0"), flags = {ServerFlags.ReuseAddr})
  let port = server.localAddress.port

  proc serve() {.async.} =
    let client = await server.accept()
    let reader = newAsyncStreamReader(client)
    let writer = newAsyncStreamWriter(client)

    await writer.write("220 localhost LMTP\r\n")
    discard await reader.readLine() # EHLO from dial
    await writer.write("250 OK\r\n")

    let line = await reader.readLine() # LHLO
    if line.startsWith("LHLO"):
      if not gotLhlo.isNil:
        gotLhlo[] = true
      await writer.write("250 OK\r\n")

    try:
      discard await reader.readLine() # QUIT
    except AsyncStreamReadError:
      discard

    await reader.closeWait()
    await writer.closeWait()
    await client.closeWait()
    server.stop()
    server.close()

  asyncSpawn serve()
  return port

# Helper: a basic SMTP server that accepts a full sendMail flow with multiple recipients.
proc multiRcptServer(rcptCount: ptr int): Future[Port] {.async.} =
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

    # Read all RCPT TO commands until DATA
    var count = 0
    while true:
      let line = await reader.readLine()
      if line.startsWith("RCPT TO:"):
        count.inc
        await writer.write("250 OK\r\n")
      elif line.startsWith("DATA"):
        break
      else:
        break
    if not rcptCount.isNil:
      rcptCount[] = count

    await writer.write("354 Go ahead\r\n")
    while true:
      let line = await reader.readLine()
      if line == ".":
        break
    await writer.write("250 OK\r\n")

    try:
      discard await reader.readLine() # QUIT
    except AsyncStreamReadError:
      discard

    await reader.closeWait()
    await writer.closeWait()
    await client.closeWait()
    server.stop()
    server.close()

  asyncSpawn serve()
  return port

# Helper: a server that checks if QUIT was sent after checkReply failure.
proc quitOnFailServer(gotQuit: ptr bool): Future[Port] {.async.} =
  let server =
    createStreamServer(initTAddress("127.0.0.1:0"), flags = {ServerFlags.ReuseAddr})
  let port = server.localAddress.port

  proc serve() {.async.} =
    let client = await server.accept()
    let reader = newAsyncStreamReader(client)
    let writer = newAsyncStreamWriter(client)

    # Send a non-250 response
    await writer.write("550 Denied\r\n")

    # Wait for QUIT
    try:
      let line = await reader.readLine()
      if line.startsWith("QUIT"):
        if not gotQuit.isNil:
          gotQuit[] = true
    except AsyncStreamReadError:
      discard

    await reader.closeWait()
    await writer.closeWait()
    await client.closeWait()
    server.stop()
    server.close()

  asyncSpawn serve()
  return port

# Helper: connect raw without EHLO handshake.
proc connectRaw(port: Port): Future[Smtp] {.async.} =
  let smtp = Smtp(timeout: InfiniteDuration)
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

suite "ehlo":
  test "ehlo returns true when server supports ESMTP":
    var speaksEsmtp = false

    proc runTest() {.async.} =
      let port = await ehloServer(@["localhost", "SIZE 10240000", "AUTH LOGIN PLAIN"])
      let smtp = await connectRaw(port)
      discard await smtp.reader.readLine() # consume greeting
      speaksEsmtp = await smtp.ehlo
      await smtp.closeSmtp()

    waitFor runTest()
    check speaksEsmtp

  test "ehlo returns false when server rejects":
    var speaksEsmtp = true

    proc runTest() {.async.} =
      var gotHelo = false
      let port = await ehloFallbackServer(addr gotHelo)
      let smtp = await connectRaw(port)
      discard await smtp.reader.readLine() # consume greeting
      speaksEsmtp = await smtp.ehlo
      await smtp.closeSmtp()

    waitFor runTest()
    check not speaksEsmtp

suite "helo/ehlo fallback via dial":
  test "dial falls back to HELO when EHLO is rejected":
    var gotHelo = false

    proc runTest() {.async.} =
      let port = await ehloFallbackServer(addr gotHelo)
      let smtp = await dial("127.0.0.1", port)
      await smtp.close()

    waitFor runTest()
    check gotHelo

suite "lhlo":
  test "lhlo sends LHLO command":
    var gotLhlo = false

    proc runTest() {.async.} =
      let port = await lhloServer(addr gotLhlo)
      let smtp = await dial("127.0.0.1", port)
      await smtp.lhlo
      await smtp.close()

    waitFor runTest()
    check gotLhlo

suite "connect with helo=false":
  test "connect skips EHLO/HELO when helo=false":
    var hasEhlo = false

    proc runTest() {.async.} =
      # A server that just sends greeting and waits for commands
      let server =
        createStreamServer(initTAddress("127.0.0.1:0"), flags = {ServerFlags.ReuseAddr})
      let port = server.localAddress.port

      proc serve() {.async.} =
        let client = await server.accept()
        let reader = newAsyncStreamReader(client)
        let writer = newAsyncStreamWriter(client)
        await writer.write("220 localhost SMTP\r\n")
        # Just wait for QUIT
        try:
          discard await reader.readLine()
        except AsyncStreamReadError:
          discard
        await reader.closeWait()
        await writer.closeWait()
        await client.closeWait()
        server.stop()
        server.close()

      asyncSpawn serve()

      let smtp = newSmtp()
      await smtp.connect("127.0.0.1", port, helo = false)
      for log in smtp.logs:
        if "EHLO" in log or "HELO" in log:
          hasEhlo = true
      await smtp.close()

    waitFor runTest()
    check not hasEhlo

suite "checkReply – quitWhenFailed":
  test "checkReply sends QUIT on failure when quitWhenFailed=true":
    var gotQuit = false
    var raised = false

    proc runTest() {.async.} =
      let port = await quitOnFailServer(addr gotQuit)
      let smtp = await connectRaw(port)
      try:
        await smtp.checkReply("250", quitWhenFailed = true)
      except ReplyError:
        raised = true
      await smtp.closeSmtp()

    waitFor runTest()
    check raised
    check gotQuit

  test "checkReply does not send QUIT when quitWhenFailed=false":
    var gotQuit = false
    var raised = false

    proc runTest() {.async.} =
      let port = await quitOnFailServer(addr gotQuit)
      let smtp = await connectRaw(port)
      try:
        await smtp.checkReply("250", quitWhenFailed = false)
      except ReplyError:
        raised = true
      await smtp.closeSmtp()

    waitFor runTest()
    check raised
    check not gotQuit

suite "sendMail – multiple recipients":
  test "sendMail sends RCPT TO for each recipient":
    var rcptCount = 0

    proc runTest() {.async.} =
      let port = await multiRcptServer(addr rcptCount)
      let smtp = await dial("127.0.0.1", port)
      let msg = createMessage(
        "Test", "Hello", @["a@example.com", "b@example.com", "c@example.com"]
      )
      await smtp.sendMail(
        "from@example.com", @["a@example.com", "b@example.com", "c@example.com"], $msg
      )
      await smtp.close()

    waitFor runTest()
    check rcptCount == 3

suite "startTls":
  test "startTls raises ReplyError when server rejects STARTTLS":
    var raised = false

    proc runTest() {.async.} =
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

        discard await reader.readLine() # STARTTLS
        await writer.write("454 TLS not available\r\n")

        # Expect QUIT from quitExcpt
        try:
          discard await reader.readLine()
        except AsyncStreamReadError:
          discard

        await reader.closeWait()
        await writer.closeWait()
        await client.closeWait()
        server.stop()
        server.close()

      asyncSpawn serve()

      let smtp = await dial("127.0.0.1", port)
      try:
        await smtp.startTls()
      except ReplyError:
        raised = true
      await smtp.close(quit = false)

    waitFor runTest()
    check raised
