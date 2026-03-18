import std/[strutils, unittest, importutils]

import pkg/chronos
import pkg/chronos/transports/stream

import ../chronos_smtp {.all.}
privateAccess(Smtp)

# Helper: a server that tracks whether QUIT was received.
proc quitTrackingServer(gotQuit: ptr bool): Future[Port] {.async.} =
  let server =
    createStreamServer(initTAddress("127.0.0.1:0"), flags = {ServerFlags.ReuseAddr})
  let port = server.localAddress.port

  proc serve() {.async.} =
    let client = await server.accept()
    let reader = newAsyncStreamReader(client)
    let writer = newAsyncStreamWriter(client)

    # Greeting + EHLO
    await writer.write("220 localhost SMTP\r\n")
    discard await reader.readLine() # EHLO
    await writer.write("250 OK\r\n")

    # Wait for QUIT or connection close
    try:
      let line = await reader.readLine()
      if line.startsWith("QUIT"):
        if not gotQuit.isNil:
          gotQuit[] = true
        try:
          await writer.write("221 Bye\r\n")
        except AsyncStreamWriteEOFError:
          discard
    except AsyncStreamReadError:
      discard

    await reader.closeWait()
    await writer.closeWait()
    await client.closeWait()
    server.stop()
    server.close()

  asyncSpawn serve()
  return port

suite "close":
  test "close with quit=true sends QUIT":
    var gotQuit = false

    proc runTest() {.async.} =
      let port = await quitTrackingServer(addr gotQuit)
      let smtp = await dial("127.0.0.1", port)
      await smtp.close(quit = true)

    waitFor runTest()
    check gotQuit

  test "close with quit=false does not send QUIT":
    var gotQuit = false

    proc runTest() {.async.} =
      let port = await quitTrackingServer(addr gotQuit)
      let smtp = await dial("127.0.0.1", port)
      await smtp.close(quit = false)

    waitFor runTest()
    check not gotQuit

  test "closed flag is true after close":
    var wasClosed = false

    proc runTest() {.async.} =
      let port = await quitTrackingServer(nil)
      let smtp = await dial("127.0.0.1", port)
      await smtp.close()
      wasClosed = smtp.closed

    waitFor runTest()
    check wasClosed
