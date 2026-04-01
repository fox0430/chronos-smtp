import std/[strutils, unittest, importutils]

import pkg/chronos
import pkg/chronos/transports/stream

import ../chronos_smtp {.all.}
privateAccess(Smtp)

type RejectStage = enum
  ## Which SMTP command the server should reject.
  rsMailFrom
  rsRcptTo
  rsAfterData

# Helper: a server that accepts SMTP up to `stage`, then rejects with `code`.
proc rejectServer(stage: RejectStage, code: string): Future[Port] {.async.} =
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
    if stage == rsMailFrom:
      await writer.write(code & " Rejected\r\n")
      discard await reader.readLine() # QUIT
    else:
      await writer.write("250 OK\r\n")

      discard await reader.readLine() # RCPT TO
      if stage == rsRcptTo:
        await writer.write(code & " Rejected\r\n")
        discard await reader.readLine() # QUIT
      else:
        await writer.write("250 OK\r\n")

        discard await reader.readLine() # DATA
        await writer.write("354 Go ahead\r\n")
        while true:
          let line = await reader.readLine()
          if line == ".":
            break
        await writer.write(code & " Rejected\r\n")
        discard await reader.readLine() # QUIT

    await reader.closeWait()
    await writer.closeWait()
    await client.closeWait()
    server.stop()
    server.close()

  asyncSpawn serve()
  return port

suite "error – connect failure":
  test "connect to unreachable host raises SmtpError":
    var raised = false

    proc runTest() {.async.} =
      try:
        # Port 1 is unlikely to have an SMTP server
        discard await dial("127.0.0.1", 1.Port)
      except SmtpError:
        raised = true

    waitFor runTest()
    check raised

suite "error – sendMail ReplyError":
  test "MAIL FROM rejected raises ReplyError":
    var raised = false
    var errMsg: string

    proc runTest(outMsg: ptr string) {.async.} =
      let port = await rejectServer(rsMailFrom, "550")
      let smtp = await dial("127.0.0.1", port)
      try:
        await smtp.sendMail("from@example.com", @["to@example.com"], "test")
      except ReplyError as e:
        raised = true
        outMsg[] = e.msg
      await smtp.close(quit = false)

    waitFor runTest(addr errMsg)
    check raised
    check "550" in errMsg

  test "RCPT TO rejected raises ReplyError":
    var raised = false
    var errMsg: string

    proc runTest(outMsg: ptr string) {.async.} =
      let port = await rejectServer(rsRcptTo, "550")
      let smtp = await dial("127.0.0.1", port)
      try:
        await smtp.sendMail("from@example.com", @["to@example.com"], "test")
      except ReplyError as e:
        raised = true
        outMsg[] = e.msg
      await smtp.close(quit = false)

    waitFor runTest(addr errMsg)
    check raised
    check "550" in errMsg

  test "post-DATA rejection raises ReplyError":
    var raised = false
    var errMsg: string

    proc runTest(outMsg: ptr string) {.async.} =
      let port = await rejectServer(rsAfterData, "554")
      let smtp = await dial("127.0.0.1", port)
      try:
        await smtp.sendMail("from@example.com", @["to@example.com"], "test")
      except ReplyError as e:
        raised = true
        outMsg[] = e.msg
      await smtp.close(quit = false)

    waitFor runTest(addr errMsg)
    check raised
    check "554" in errMsg

  test "ReplyError is catchable as SmtpError":
    var raised = false

    proc runTest() {.async.} =
      let port = await rejectServer(rsMailFrom, "550")
      let smtp = await dial("127.0.0.1", port)
      try:
        await smtp.sendMail("from@example.com", @["to@example.com"], "test")
      except SmtpError:
        raised = true
      await smtp.close(quit = false)

    waitFor runTest()
    check raised
