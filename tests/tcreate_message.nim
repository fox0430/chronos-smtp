import std/[strutils, unittest, times]

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

  test "auto-generated Date header":
    let msg = createMessage("Test", "Body")
    let s = $msg
    check "Date: " in s
    # Verify the date is close to now (within 2 seconds)
    let dateStart = s.find("Date: ") + 6
    let dateEnd = s.find("\c\L", dateStart)
    let dateStr = s[dateStart ..< dateEnd]
    let parsed = dateStr.parse("ddd, dd MMM yyyy HH:mm:ss '+0000'", utc())
    let diff = now().utc - parsed
    check diff.inSeconds.abs < 2

  test "auto-generated Message-ID header":
    let msg = createMessage("Test", "Body")
    let s = $msg
    check "Message-ID: <" in s
    check "@localhost>\c\L" in s

  test "unique Message-ID per message":
    let msg1 = createMessage("Test", "Body")
    let msg2 = createMessage("Test", "Body")
    let s1 = $msg1
    let s2 = $msg2
    let id1Start = s1.find("Message-ID: ") + 12
    let id1End = s1.find("\c\L", id1Start)
    let id2Start = s2.find("Message-ID: ") + 12
    let id2End = s2.find("\c\L", id2Start)
    check s1[id1Start ..< id1End] != s2[id2Start ..< id2End]

  test "custom Date header not overwritten":
    let msg = createMessage(
      "Test",
      "Body",
      @["alice@example.com"],
      @[],
      [("Date", "Mon, 01 Jan 2024 00:00:00 +0000")],
    )
    let s = $msg
    check "Date: Mon, 01 Jan 2024 00:00:00 +0000\c\L" in s

  test "custom Message-ID header not overwritten":
    let msg = createMessage(
      "Test",
      "Body",
      @["alice@example.com"],
      @[],
      [("Message-ID", "<custom@example.com>")],
    )
    let s = $msg
    check "Message-ID: <custom@example.com>\c\L" in s
