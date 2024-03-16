# (c) Copyright 2024 Shuhei Nogawa
# This software is released under the MIT License, see LICENSE.
#
# Copyright (c) 2012 Dominik Picheta
# https://github.com/nim-lang/smtp/blob/master/LICENSE

import std/[base64, strtabs, strutils]

import
  pkg/chronos,
  pkg/chronos/streams/tlsstream,
  pkg/chronos/transports/common,
  pkg/chronos/transports/stream

export chronos, Port, TLSFlags

type
  SmtpClientScheme* {.pure.} = enum
    NonSecure
    Secure

  Message* = object
    msgTo: seq[string]
    msgCc: seq[string]
    msgSubject: string
    msgOtherHeaders: StringTableRef
    msgBody: string

  SmtpError* = object of AsyncError
  ReplyError* = object of IOError

  Smtp* = ref object
    case kind: SmtpClientScheme
    of SmtpClientScheme.NonSecure:
      discard
    of SmtpClientScheme.Secure:
      treader: AsyncStreamReader
      twriter: AsyncStreamWriter
      tls: TLSAsyncStream
      flags: set[TLSFlags]
    transp: StreamTransport
    reader: AsyncStreamReader
    writer: AsyncStreamWriter
    hostname: string
    port: Port
    debug: bool

proc containsNewline(xs: seq[string]): bool =
  for x in xs:
    if x.contains({'\c', '\L'}):
      return true

proc debugSend*(smtp: Smtp, cmd: string) {.async.} =
  ## Sends `cmd` on the socket connected to the SMTP server.
  ##
  ## If the `smtp` object was created with `debug` enabled,
  ## debugSend will invoke `echo("C:" & cmd)` before sending.
  ##
  ## This is a lower level proc and not something that you typically
  ## would need to call when using this module. One exception to
  ## this is if you are implementing any
  ## `SMTP extensions<https://en.wikipedia.org/wiki/Extended_SMTP>`_.

  if smtp.debug:
    echo("C:" & cmd)
  await smtp.writer.write(cmd)

proc debugRead*(smtp: Smtp): Future[string] {.async.} =
  ## Receives a line of data from the socket connected to the
  ## SMTP server.
  ##
  ## If the `smtp` object was created with `debug` enabled,
  ## debugRead will invoke `echo("S:" & result.string)` after
  ## the data is received.
  ##
  ## This is a lower level proc and not something that you typically
  ## would need to call when using this module. One exception to
  ## this is if you are implementing any
  ## `SMTP extensions<https://en.wikipedia.org/wiki/Extended_SMTP>`_.
  ##
  ## See `checkReply(reply)<#checkReply,AsyncSmtp,string>`_.
  result = await smtp.reader.readLine
  if smtp.debug:
    echo("S:" & result)

proc quitExcpt(smtp: Smtp, msg: string) {.async.} =
  await smtp.debugSend("QUIT")
  raise newException(ReplyError, msg)

proc createMessage*(
  mSubject, mBody: string,
  mTo, mCc: seq[string],
  otherHeaders: openArray[tuple[name, value: string]]): Message =
    ## Creates a new MIME compliant message.
    ##
    ## You need to make sure that `mSubject`, `mTo` and `mCc` don't contain
    ## any newline characters. Failing to do so will raise `AssertionDefect`.
    doAssert(not mSubject.contains({'\c', '\L'}),
             "'mSubject' shouldn't contain any newline characters")
    doAssert(not (mTo.containsNewline() or mCc.containsNewline()),
             "'mTo' and 'mCc' shouldn't contain any newline characters")

    result.msgTo = mTo
    result.msgCc = mCc
    result.msgSubject = mSubject
    result.msgBody = mBody
    result.msgOtherHeaders = newStringTable()
    for n, v in items(otherHeaders):
      result.msgOtherHeaders[n] = v

proc createMessage*(
  mSubject, mBody: string,
  mTo: seq[string] = @[],
  mCc: seq[string] = @[]): Message =
    ## Alternate version of the above.
    ##
    ## You need to make sure that `mSubject`, `mTo` and `mCc` don't contain
    ## any newline characters. Failing to do so will raise `AssertionDefect`.
    doAssert(not mSubject.contains({'\c', '\L'}),
             "'mSubject' shouldn't contain any newline characters")
    doAssert(not (mTo.containsNewline() or mCc.containsNewline()),
             "'mTo' and 'mCc' shouldn't contain any newline characters")
    result.msgTo = mTo
    result.msgCc = mCc
    result.msgSubject = mSubject
    result.msgBody = mBody
    result.msgOtherHeaders = newStringTable()

proc `$`*(msg: Message): string =
  ## stringify for `Message`.
  result = ""
  if msg.msgTo.len() > 0:
    result = "TO: " & msg.msgTo.join(", ") & "\c\L"
  if msg.msgCc.len() > 0:
    result.add("CC: " & msg.msgCc.join(", ") & "\c\L")
  # TODO: Folding? i.e when a line is too long, shorten it...
  result.add("Subject: " & msg.msgSubject & "\c\L")
  for key, value in pairs(msg.msgOtherHeaders):
    result.add(key & ": " & value & "\c\L")

  result.add("\c\L")
  result.add(msg.msgBody)

proc newSmtp(debug: bool = true, useTls: bool = false): Smtp =
  if useTls:
    return Smtp(debug: debug, kind: SmtpClientScheme.Secure)
  else:
    return Smtp(debug: debug, kind: SmtpClientScheme.NonSecure)

proc checkReply*(smtp: Smtp, reply: string) {.async.} =
  let line = await smtp.debugRead
  if not line.startsWith(reply):
    await quitExcpt(smtp, "Expected " & reply & " reply, got: " & line)

proc helo*(smtp: Smtp, helo: string = "HELO") {.async.} =
  await smtp.debugSend(helo & " " & smtp.hostname & "\c\L")
  await smtp.checkReply("250")

proc lhlo*(smtp: Smtp) {.async.} =
  # Sends the LHLO request (for LMTP)
  await smtp.helo("LHLO")

proc readEhlo(smtp: Smtp): Future[bool] {.async.} =
  ## Skips "250-" lines, read until "250 " found.
  ## Return `true` if server supports `EHLO`, false otherwise.
  while true:
    var line = await smtp.debugRead
    if line.startsWith("250-"): continue
    elif line.startsWith("250 "): return true # last line
    else: return false

proc ehlo*(smtp: Smtp): Future[bool] {.async.} =
  echo "send EHLO"
  ## Sends EHLO request.
  await smtp.debugSend("EHLO " & smtp.hostname & "\c\L")
  return await smtp.readEhlo

proc connect*(
  smtp: Smtp,
  hostname: string,
  port: Port,
  flags: set[TLSFlags] = {},
  helo: bool = true) {.async.} =
    ## Establishes a connection with a SMTP server.

    let addresses = resolveTAddress(hostname, port)
    var lastError = ""
    for a in addresses:
      let transp =
        try:
          await connect(a)
        except CancelledError as e:
          lastError = e.msg
          continue
        except TransportError:
          nil

      if not transp.isNil:
        smtp.transp = transp
        smtp.hostname = hostname

        case smtp.kind:
        of SmtpClientScheme.NonSecure:
          smtp.reader = newAsyncStreamReader(smtp.transp)
          smtp.writer = newAsyncStreamWriter(smtp.transp)
        of SmtpClientScheme.Secure:
          let
            treader = newAsyncStreamReader(smtp.transp)
            twriter = newAsyncStreamWriter(smtp.transp)

            tls =
              try:
                newTLSClientAsyncStream(
                  treader,
                  twriter,
                  hostname,
                  flags = flags)
              except TLSStreamInitError as e:
                lastError = e.msg
                continue

          smtp.transp = transp
          smtp.treader = treader
          smtp.twriter = twriter
          smtp.reader = tls.reader
          smtp.writer = tls.writer
          smtp.tls = tls

        await smtp.checkReply("220")

        if helo:
          let speaksEsmtp = await smtp.ehlo
          if not speaksEsmtp:
            await smtp.helo

        return

    # If all attempts to connect to the remote host have failed.
    if lastError.len > 0:
      raise newException(
        SmtpError,
        "Could not connect to remote host, reason: " & lastError)
    else:
      raise newException(
        SmtpError,
        "Could not connect to remote host")

proc dial*(
  hostname: string,
  port: Port,
  useTls: bool = false,
  flags: set[TLSFlags] = {},
  debug: bool = true,
  helo: bool = true): Future[Smtp] {.async.} =

    result = newSmtp(debug, useTls)
    await result.connect(hostname, port, flags, helo)

proc startTls*(smtp: Smtp, flags: set[TLSFlags] = {}) {.async.} =
  ## Put the SMTP connection in TLS (Transport Layer Security) mode.
  ## May fail with ReplyError
  await smtp.debugSend("STARTTLS\c\L")
  await smtp.checkReply("220")

  let tls = newTLSClientAsyncStream(
    smtp.reader,
    smtp.writer,
    smtp.hostname,
    flags = flags)

  # Upgrade to TLS stream
  var newSmtp = Smtp(kind: SmtpClientScheme.Secure)
  newSmtp.transp = smtp.transp
  newSmtp.treader = smtp.reader
  newSmtp.twriter = smtp.writer
  newSmtp.reader = tls.reader
  newSmtp.writer = tls.writer
  newSmtp.tls = tls
  newSmtp.flags = flags
  smtp[] = newSmtp[]

  let speaksEsmtp = await smtp.ehlo
  if not speaksEsmtp:
    await smtp.helo

proc auth*(smtp: Smtp, username, password: string) {.async.} =
  ## Sends an AUTH command to the server to login as the `username`
  ## using `password`.
  ## May fail with ReplyError.

  await smtp.debugSend("AUTH LOGIN\c\L")
  await smtp.checkReply("334") # TODO: Check whether it's asking for the "Username:"
                               # i.e "334 VXNlcm5hbWU6"
  await smtp.debugSend(encode(username) & "\c\L")
  await smtp.checkReply("334") # TODO: Same as above, only "Password:" (I think?)

  await smtp.debugSend(encode(password) & "\c\L")
  await smtp.checkReply("235") # Check whether the authentication was successful.

proc sendMail*(
  smtp: Smtp,
  fromAddr: string,
  toAddrs: seq[string],
  msg: string) {.async.} =
    ## Sends `msg` from `fromAddr` to the addresses specified in `toAddrs`.
    ## Messages may be formed using `createMessage` by converting the
    ## Message into a string.
    ##
    ## You need to make sure that `fromAddr` and `toAddrs` don't contain
    ## any newline characters. Failing to do so will raise `AssertionDefect`.
    doAssert(not (toAddrs.containsNewline() or fromAddr.contains({'\c', '\L'})),
             "'toAddrs' and 'fromAddr' shouldn't contain any newline characters")

    await smtp.debugSend("MAIL FROM:<" & fromAddr & ">\c\L")
    await smtp.checkReply("250")
    for address in items(toAddrs):
      await smtp.debugSend("RCPT TO:<" & address & ">\c\L")
      await smtp.checkReply("250")

    # Send the message
    await smtp.debugSend("DATA" & "\c\L")
    await smtp.checkReply("354")
    await smtp.debugSend(msg & "\c\L")
    await smtp.debugSend(".\c\L")
    await smtp.checkReply("250")

proc close*(smtp: Smtp) {.async.} =
  ## Disconnects from the SMTP server and closes the socket.
  await smtp.debugSend("QUIT\c\L")
  if smtp.transp != nil: smtp.transp.close()
