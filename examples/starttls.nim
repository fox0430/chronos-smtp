import pkg/chronos_smtp

proc main() {.async.} =
  var conn = newSmtp(debug = true, useTls = false)
  await conn.connect("smtp.gmail.com", 587.Port)
  await conn.startTls
  await conn.auth("username", "password")

  let msg = createMessage(
    "Hello from Nim's SMTP",
    "Hello!.\n Is this awesome or what?",
    @["foo@gmail.com"])
  await conn.sendmail("username@gmail.com", @["foo@gmail.com"], $msg)

when isMainModule:
  waitFor main()
