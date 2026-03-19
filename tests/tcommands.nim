import std/[base64, strutils, unittest, importutils]

import ../chronos_smtp {.all.}
privateAccess(Smtp)

suite "command generation":
  test "heloCommand":
    check heloCommand("example.com") == "HELO example.com\c\L"

  test "ehloCommand":
    check ehloCommand("example.com") == "EHLO example.com\c\L"

  test "lhloCommand":
    check lhloCommand("example.com") == "LHLO example.com\c\L"

  test "starttlsCommand":
    check starttlsCommand() == "STARTTLS\c\L"

  test "mailCommand":
    check mailCommand("user@example.com") == "MAIL FROM:<user@example.com>\c\L"

  test "rcptCommand":
    check rcptCommand("user@example.com") == "RCPT TO:<user@example.com>\c\L"

  test "dataCommand":
    check dataCommand() == "DATA\c\L"

  test "quitCommand":
    check quitCommand() == "QUIT\c\L"

  test "noopCommand":
    check noopCommand() == "NOOP\c\L"

  test "helpCommand":
    check helpCommand("MAIL") == "HELP MAIL\c\L"

  test "vrfyCommand":
    check vrfyCommand("user") == "VRFY user\c\L"

  test "expnCommand":
    check expnCommand("list") == "EXPN list\c\L"

  test "resetCommand":
    check resetCommand() == "RSET\c\L"

  test "authLoginCommand":
    check authLoginCommand() == "AUTH LOGIN\c\L"

  test "authPlainCommand":
    let cmd = authPlainCommand("user", "pass")
    check cmd.startsWith("AUTH PLAIN ")
    check cmd.endsWith("\c\L")
    let encoded = cmd["AUTH PLAIN ".len ..< cmd.len - 2]
    check decode(encoded) == "\0user\0pass"

suite "kind":
  test "NonSecure by default":
    let smtp = newSmtp()
    check smtp.kind == SmtpClientScheme.NonSecure

  test "Secure when useTls is true":
    let smtp = newSmtp(useTls = true)
    check smtp.kind == SmtpClientScheme.Secure

suite "newSmtp":
  test "useTls defaults to false":
    let smtp = newSmtp()
    check smtp.useTls == false

  test "useTls set to true":
    let smtp = newSmtp(useTls = true)
    check smtp.useTls == true

  test "closed defaults to false":
    let smtp = newSmtp()
    check smtp.closed == false

  test "logs starts empty":
    let smtp = newSmtp()
    check smtp.logs.len == 0
