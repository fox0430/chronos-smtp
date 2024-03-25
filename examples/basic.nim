import pkg/chronos_smtp

proc main() {.async.} =
  var conn = newSmtp(useTls = false)
  await conn.connect("localhost", 2525.Port)

  let msg = createMessage(
    "Hello from Nim's SMTP",
    "Hello!.\n Is this awesome or what?",
    @["foo@exmaple.com"])
  await conn.sendmail("username@exmaple.com", @["foo@exmaple.com"], $msg)

when isMainModule:
  waitFor main()
