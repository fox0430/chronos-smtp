import std/[strutils, unittest]

import ../chronos_smtp

suite "createMessage and $ operator":
  test "To only":
    let msg = createMessage("Test Subject", "Hello", @["alice@example.com"])
    let s = $msg
    check "To: alice@example.com\c\L" in s
    check "Cc:" notin s
    check "Subject: Test Subject\c\L" in s
    check s.endsWith("Hello")

  test "To and Cc":
    let msg =
      createMessage("Test", "Body", @["alice@example.com"], @["bob@example.com"])
    let s = $msg
    check "To: alice@example.com\c\L" in s
    check "Cc: bob@example.com\c\L" in s

  test "multiple To and Cc":
    let msg = createMessage(
      "Test",
      "Body",
      @["alice@example.com", "bob@example.com"],
      @["carol@example.com", "dave@example.com"],
    )
    let s = $msg
    check "To: alice@example.com, bob@example.com\c\L" in s
    check "Cc: carol@example.com, dave@example.com\c\L" in s

  test "empty To and Cc":
    let msg = createMessage("Test", "Body")
    let s = $msg
    check "To:" notin s
    check "Cc:" notin s
    check "Subject: Test\c\L" in s
    check s.endsWith("Body")

  test "with otherHeaders":
    let msg = createMessage(
      "Test",
      "Body",
      @["alice@example.com"],
      @[],
      [("X-Custom", "value1"), ("X-Another", "value2")],
    )
    let s = $msg
    check "X-Custom: value1\c\L" in s
    check "X-Another: value2\c\L" in s

  test "header and body separated by blank line":
    let msg = createMessage("Test", "Body", @["alice@example.com"])
    let s = $msg
    # Headers end with \c\L, then blank line \c\L, then body
    check "\c\L\c\LBody" in s

  test "body content preserved":
    let body = "Line 1\c\LLine 2\c\LLine 3"
    let msg = createMessage("Test", body)
    let s = $msg
    check s.endsWith(body)
