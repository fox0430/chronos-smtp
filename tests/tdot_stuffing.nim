import std/[strutils, unittest]

import pkg/chronos
import pkg/chronos/transports/stream

import ../chronos_smtp {.all.}

# A minimal SMTP server that accepts one message and captures the DATA payload.
# Performs dot de-stuffing per RFC 5321: strips one leading dot from lines
# starting with "..".
proc captureServer(captured: ptr string): Future[Port] {.async.} =
  let server =
    createStreamServer(initTAddress("127.0.0.1:0"), flags = {ServerFlags.ReuseAddr})
  let port = server.localAddress.port

  proc serve() {.async.} =
    let client = await server.accept()
    let reader = newAsyncStreamReader(client)
    let writer = newAsyncStreamWriter(client)

    # Greeting
    await writer.write("220 localhost SMTP\r\n")

    # EHLO
    discard await reader.readLine()
    await writer.write("250 OK\r\n")

    # MAIL FROM
    discard await reader.readLine()
    await writer.write("250 OK\r\n")

    # RCPT TO
    discard await reader.readLine()
    await writer.write("250 OK\r\n")

    # DATA
    discard await reader.readLine()
    await writer.write("354 Go ahead\r\n")

    # Read until lone ".\r\n", applying dot de-stuffing
    var body = ""
    while true:
      let line = await reader.readLine()
      if line == ".":
        break
      # Dot de-stuffing: strip one leading dot from lines starting with ".."
      if line.startsWith(".."):
        body.add line[1 .. ^1] & "\n"
      else:
        body.add line & "\n"

    captured[] = body
    await writer.write("250 OK\r\n")

    # QUIT
    discard await reader.readLine()
    try:
      await writer.write("221 Bye\r\n")
    except AsyncStreamWriteEOFError:
      discard

    await reader.closeWait()
    await writer.closeWait()
    await client.closeWait()
    server.stop()
    server.close()

  asyncSpawn serve()
  return port

proc sendAndCapture(msgBody: string, raw = false): string =
  ## Send a message and return what the server captured.
  ## If `raw` is true, `msgBody` is passed directly to sendMail without
  ## wrapping it in createMessage (useful for testing the first-line edge case).
  var captured: string

  proc run() {.async.} =
    let port = await captureServer(addr captured)
    let smtp = await dial("localhost", port, helo = false)
    let speaksEsmtp = await smtp.ehlo
    if not speaksEsmtp:
      await smtp.helo

    if raw:
      await smtp.sendMail("from@example.com", @["to@example.com"], msgBody)
    else:
      let msg = createMessage("Test", msgBody, @["to@example.com"])
      await smtp.sendMail("from@example.com", @["to@example.com"], $msg)
    await smtp.close()

  waitFor run()
  return captured

suite "dot transparency (RFC 5321 Section 4.5.2)":
  test "message without leading dots is unchanged":
    let body = sendAndCapture("Hello World")
    check "Hello World" in body
    check ".." notin body

  test "single dot on a line is escaped and survives round-trip":
    let body = sendAndCapture("before\r\n.\r\nafter")
    # After dot-stuffing on wire and de-stuffing on server, the lone dot survives.
    check "before\n" in body
    check ".\n" in body
    check "after\n" in body

  test "dot at start of line survives round-trip":
    let body = sendAndCapture("line1\r\n.line2\r\nline3")
    check ".line2\n" in body
    check "line3\n" in body

  test "multiple dot lines":
    let body = sendAndCapture("a\r\n.b\r\n.c\r\n.\r\nd")
    check ".b\n" in body
    check ".c\n" in body
    check ".\n" in body
    check "d\n" in body

  test "line with multiple dots is preserved":
    let body = sendAndCapture("line1\r\n..already doubled\r\nline3")
    # ".." in original → "..." on wire → de-stuff → ".."
    check "..already doubled\n" in body

  test "raw msg starting with a dot is escaped":
    let body = sendAndCapture(".first line\r\nsecond", raw = true)
    check ".first line\n" in body
    check "second\n" in body

  test "no dots at line start needs no escaping":
    let body = sendAndCapture("no dots. in. middle.\r\nsecond line.")
    check "no dots. in. middle.\n" in body
    check "second line.\n" in body
