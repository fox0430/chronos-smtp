import std/unittest

import pkg/chronos

import ../chronos_smtp {.all.}

suite "sendMail":
  test "Basic":
    var conn = newSmtp(debug = false)
    waitFor conn.connect("localhost", 2525.Port)

    let msg = createMessage(
      "Hello from Nim's SMTP",
      "Hello!.\n Is this awesome or what?",
      @["foo@gmail.com"])
    waitFor conn.sendmail("username@gmail.com", @["foo@gmail.com"], $msg)

  test "Basic 2":
    var conn = waitFor dial("localhost", 2525.Port, debug = false)

    let msg = createMessage(
      "Hello from Nim's SMTP",
      "Hello!.\n Is this awesome or what?",
      @["foo@gmail.com"])
    waitFor conn.sendmail("username@gmail.com", @["foo@gmail.com"], $msg)
