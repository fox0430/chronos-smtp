import std/[base64, unittest, importutils]

import pkg/chronos
import pkg/chronos/transports/stream

import ../chronos_smtp {.all.}
privateAccess(Smtp)

# Helper: a server that accepts AUTH LOGIN with expected credentials.
proc authServer(expectUser, expectPass: string, success: bool): Future[Port] {.async.} =
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

    # AUTH LOGIN
    discard await reader.readLine() # AUTH LOGIN
    await writer.write("334 VXNlcm5hbWU6\r\n") # "Username:" in base64

    let userLine = await reader.readLine() # base64-encoded username
    await writer.write("334 UGFzc3dvcmQ6\r\n") # "Password:" in base64

    let passLine = await reader.readLine() # base64-encoded password

    if success and userLine == encode(expectUser) and passLine == encode(expectPass):
      await writer.write("235 Authentication successful\r\n")
    else:
      await writer.write("535 Authentication failed\r\n")

    # Read QUIT (may come from quitExcpt on failure, or from close on success)
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
  return port

suite "auth – AUTH LOGIN":
  test "successful authentication":
    proc runTest() {.async.} =
      let port = await authServer("user", "pass", success = true)
      let smtp = await dial("127.0.0.1", port)
      await smtp.auth("user", "pass")
      await smtp.close()

    waitFor runTest()

  test "failed authentication raises ReplyError":
    var raised = false

    proc runTest() {.async.} =
      let port = await authServer("user", "pass", success = false)
      let smtp = await dial("127.0.0.1", port)
      try:
        await smtp.auth("wrong", "creds")
      except ReplyError:
        raised = true
      await smtp.close(quit = false)

    waitFor runTest()
    check raised
