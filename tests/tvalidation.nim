import std/unittest

import pkg/chronos

import ../chronos_smtp

suite "createMessage – validation":
  test "newline in subject raises AssertionDefect":
    var raised = false
    try:
      discard createMessage("Bad\r\nSubject", "Body")
    except AssertionDefect:
      raised = true
    check raised

  test "carriage return in subject raises AssertionDefect":
    var raised = false
    try:
      discard createMessage("Bad\rSubject", "Body")
    except AssertionDefect:
      raised = true
    check raised

  test "newline in To raises AssertionDefect":
    var raised = false
    try:
      discard createMessage("Test", "Body", @["bad\r\n@example.com"])
    except AssertionDefect:
      raised = true
    check raised

  test "newline in Cc raises AssertionDefect":
    var raised = false
    try:
      discard
        createMessage("Test", "Body", @["ok@example.com"], @["bad\r\n@example.com"])
    except AssertionDefect:
      raised = true
    check raised

suite "sendMail – validation":
  test "newline in fromAddr raises AssertionDefect":
    var raised = false

    proc runTest() {.async.} =
      let smtp = newSmtp()
      try:
        await smtp.sendMail("from\r\n@example.com", @["to@example.com"], "test")
      except AssertionDefect:
        raised = true

    waitFor runTest()
    check raised

  test "newline in toAddrs raises AssertionDefect":
    var raised = false

    proc runTest() {.async.} =
      let smtp = newSmtp()
      try:
        await smtp.sendMail("from@example.com", @["to\r\n@example.com"], "test")
      except AssertionDefect:
        raised = true

    waitFor runTest()
    check raised
