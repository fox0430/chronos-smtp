import std/[strutils, unittest]

import pkg/chronos
import pkg/chronos/transports/stream

import ../chronos_smtp {.all.}

# Helper: start a local TCP server that sends `payload` then closes.
proc servOnce(payload: string): Future[Port] {.async.} =
  let server =
    createStreamServer(initTAddress("127.0.0.1:0"), flags = {ServerFlags.ReuseAddr})
  let port = server.localAddress.port

  proc serve() {.async.} =
    let client = await server.accept()
    let writer = newAsyncStreamWriter(client)
    await writer.write(payload)
    await writer.closeWait()
    await client.closeWait()
    server.stop()
    server.close()

  asyncSpawn serve()
  return port

# Helper: connect an Smtp object (NonSecure, no EHLO handshake) to addr.
proc connectRaw(port: Port): Future[Smtp] {.async.} =
  let smtp = Smtp(kind: SmtpClientScheme.NonSecure)
  let transp = await connect(initTAddress("127.0.0.1", port))
  smtp.transp = transp
  smtp.reader = newAsyncStreamReader(transp)
  smtp.writer = newAsyncStreamWriter(transp)
  return smtp

proc closeSmtp(smtp: Smtp) {.async.} =
  await smtp.reader.closeWait()
  await smtp.writer.closeWait()
  await smtp.transp.closeWait()

# Read a response and return it along with the smtp object for inspection.
proc readResponse(payload: string): Future[(string, Smtp)] {.async.} =
  let port = await servOnce(payload)
  let smtp = await connectRaw(port)
  let resp = await smtp.read()
  return (resp, smtp)

suite "read – multiline response parsing":
  test "single line response":
    let (resp, smtp) = waitFor readResponse("250 OK\r\n")
    check resp == "250 OK"
    check smtp.logs.len == 1
    waitFor smtp.closeSmtp()

  test "two-line multiline response":
    let (resp, smtp) = waitFor readResponse("250-First\r\n250 Second\r\n")
    check resp == "250-First\n250 Second"
    check smtp.logs.len == 1
    waitFor smtp.closeSmtp()

  test "three-line multiline response":
    let (resp, smtp) = waitFor readResponse("250-One\r\n250-Two\r\n250 Three\r\n")
    check resp == "250-One\n250-Two\n250 Three"
    waitFor smtp.closeSmtp()

  test "many continuation lines":
    var payload = ""
    for i in 0 ..< 10:
      payload.add "250-Line" & $i & "\r\n"
    payload.add "250 End\r\n"

    let (resp, smtp) = waitFor readResponse(payload)
    let lines = resp.split('\n')
    check lines.len == 11
    check lines[0] == "250-Line0"
    check lines[10] == "250 End"
    waitFor smtp.closeSmtp()

  test "lines with varying lengths":
    let payload =
      "250-This is a very long first line with lots of content\r\n" & "250-OK\r\n" &
      "250 Done\r\n"
    let (resp, smtp) = waitFor readResponse(payload)
    let lines = resp.split('\n')
    check lines.len == 3
    check lines[0] == "250-This is a very long first line with lots of content"
    check lines[1] == "250-OK"
    check lines[2] == "250 Done"
    waitFor smtp.closeSmtp()

  test "short response (3 chars, no continuation marker)":
    let (resp, smtp) = waitFor readResponse("250\r\n")
    check resp == "250"
    waitFor smtp.closeSmtp()

  test "empty line from server (EOF)":
    let (resp, smtp) = waitFor readResponse("")
    check resp == ""
    waitFor smtp.closeSmtp()

  test "checkReply with multiline 250":
    proc runTest() {.async.} =
      let port = await servOnce("250-Hello\r\n250 OK\r\n")
      let smtp = await connectRaw(port)
      await smtp.checkReply("250")
      await smtp.closeSmtp()

    waitFor runTest()

  test "checkReply fails on wrong code":
    proc runTest() {.async.} =
      let port = await servOnce("550 Denied\r\n")
      let smtp = await connectRaw(port)
      try:
        await smtp.checkReply("250", quitWhenFailed = false)
        fail()
      except ReplyError:
        discard
      await smtp.closeSmtp()

    waitFor runTest()
