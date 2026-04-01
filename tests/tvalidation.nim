import std/unittest

import pkg/chronos

import ../chronos_smtp

suite "createMessage – validation":
  test "newline in subject raises ValueError":
    var raised = false
    try:
      discard createMessage("Bad\r\nSubject", "Body")
    except ValueError:
      raised = true
    check raised

  test "carriage return in subject raises ValueError":
    var raised = false
    try:
      discard createMessage("Bad\rSubject", "Body")
    except ValueError:
      raised = true
    check raised

  test "newline in To raises ValueError":
    var raised = false
    try:
      discard createMessage("Test", "Body", @["bad\r\n@example.com"])
    except ValueError:
      raised = true
    check raised

  test "newline in Cc raises ValueError":
    var raised = false
    try:
      discard
        createMessage("Test", "Body", @["ok@example.com"], @["bad\r\n@example.com"])
    except ValueError:
      raised = true
    check raised

suite "sendMail – validation":
  test "newline in fromAddr raises ValueError":
    var raised = false

    proc runTest() {.async.} =
      let smtp = newSmtp()
      try:
        await smtp.sendMail("from\r\n@example.com", @["to@example.com"], "test")
      except ValueError:
        raised = true

    waitFor runTest()
    check raised

  test "newline in toAddrs raises ValueError":
    var raised = false

    proc runTest() {.async.} =
      let smtp = newSmtp()
      try:
        await smtp.sendMail("from@example.com", @["to\r\n@example.com"], "test")
      except ValueError:
        raised = true

    waitFor runTest()
    check raised
