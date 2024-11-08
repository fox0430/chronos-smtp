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
  pkg/chronos/transports/stream,
  pkg/chronicles

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
    closed*: bool
    case kind*: SmtpClientScheme
    of SmtpClientScheme.NonSecure:
      discard
    of SmtpClientScheme.Secure:
      treader*: AsyncStreamReader
      twriter*: AsyncStreamWriter
      tls*: TLSAsyncStream
      flags*: set[TLSFlags]
    transp*: StreamTransport
    reader*: AsyncStreamReader
    writer*: AsyncStreamWriter
    host*: string
    port*: Port

proc heloCommand*(param: string): string {.inline.} =
  "HELO " & param & "\c\L"

proc ehloCommand*(param: string): string {.inline.} =
  "EHLO " & param & "\c\L"

proc lhloCommand*(param: string): string {.inline.} =
  "LHLO " & param & "\c\L"

proc starttlsCommand*(): string {.inline.} =
  "STARTTLS\c\L"

proc mailCommand*(param: string): string {.inline.} =
  "MAIL FROM:<" & param & ">\c\L"

proc rcptCommand*(param: string): string {.inline.} =
  "RCPT TO:<" & param & ">\c\L"

proc dataCommand*(): string {.inline.} =
  "DATA\c\L"

proc quitComand*(): string {.inline.} =
  "QUIT\c\L"

proc noopCommand*(): string {.inline.} =
  "NOOP\c\L"

proc helpCommand*(param: string): string {.inline.} =
  "HELP " & param & "\c\L"

proc vrfyCommand*(param: string): string {.inline.} =
  "VRFY " & param & "\c\L"

proc expnCommand*(param: string): string {.inline.} =
  "EXPN " & param & "\c\L"

proc resetCommand*(): string {.inline.} =
  "RSET\c\L"

proc authCommand*(): string {.inline.} =
  "AUTH LOGIN\c\L"

proc containsNewline(xs: seq[string]): bool =
  for x in xs:
    if x.contains({'\c', '\L'}):
      return true

proc send*(smtp: Smtp, cmd: string) {.async.} =
  debug "Client:", cmd
  await smtp.writer.write(cmd)

proc read*(smtp: Smtp): Future[string] {.async.} =
  ## Return all lines

  result.add await smtp.reader.readLine
  var posi = 3
  while result.len > posi and result[posi] == '-':
    let line = await smtp.reader.readLine
    posi = result.len + 4
    result.add '\n' & line

  debug "Server:", result

proc readLine*(smtp: Smtp): Future[string] {.async.} =
  result = await smtp.reader.readLine
  debug "Server:", result

proc quitExcpt(smtp: Smtp, msg: string) {.async.} =
  await smtp.send(quitComand())
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

proc newSmtp*(useTls: bool = false): Smtp =
  if useTls:
    return Smtp(kind: SmtpClientScheme.Secure)
  else:
    return Smtp(kind: SmtpClientScheme.NonSecure)

proc checkReply*(
  smtp: Smtp,
  reply: string,
  quitWhenFailed: bool = true) {.async.} =
    let line = await smtp.read
    if not line.startsWith(reply):
      let msg = "Expected " & reply & " reply, got: " & line
      if quitWhenFailed:
        await quitExcpt(smtp, msg)
      else:
        raise newException(ReplyError, msg)

proc helo*(smtp: Smtp) {.async.} =
  await smtp.send(heloCommand(smtp.host))
  await smtp.checkReply("250")

proc lhlo*(smtp: Smtp) {.async.} =
  # Sends the LHLO request (for LMTP)
  await smtp.send(lhloCommand(smtp.host))

proc readEhlo(smtp: Smtp): Future[bool] {.async.} =
  ## Skips "250-" lines, read until "250 " found.
  ## Return `true` if server supports `EHLO`, false otherwise.
  while true:
    var line = await smtp.readLine
    if line.startsWith("250-"): continue
    elif line.startsWith("250 "): return true # last line
    else: return false

proc ehlo*(smtp: Smtp): Future[bool] {.async.} =
  ## Sends EHLO request.
  await smtp.send(ehloCommand(smtp.host))
  return await smtp.readEhlo

proc connect*(
  smtp: Smtp,
  host: string,
  port: Port,
  flags: set[TLSFlags] = {},
  helo: bool = true,
  quitWhenFailed: bool = true) {.async.} =
    ## Establishes a connection with a SMTP server.

    let addresses = resolveTAddress(host, port)
    var lastError = ""
    for a in addresses:
      let transp =
        try:
          await connect(a)
        except CancelledError as e:
          raise e
        except TransportError:
          nil

      if not transp.isNil:
        smtp.transp = transp
        smtp.host = host
        smtp.port = port

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
                  host,
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

        await smtp.checkReply("220", quitWhenFailed)

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
  host: string,
  port: Port,
  useTls: bool = false,
  flags: set[TLSFlags] = {},
  helo: bool = true,
  quitWhenFailed: bool = true): Future[Smtp] {.async.} =

    result = newSmtp(useTls)
    try:
      await result.connect(host, port, flags, helo, quitWhenFailed)
    except CancelledError as e:
      raise e

proc startTls*(smtp: Smtp, flags: set[TLSFlags] = {}) {.async.} =
  ## Put the SMTP connection in TLS (Transport Layer Security) mode.
  ## May fail with ReplyError
  await smtp.send(starttlsCommand())
  await smtp.checkReply("220")

  let
    treader = newAsyncStreamReader(smtp.transp)
    twriter = newAsyncStreamWriter(smtp.transp)
    tls = newTLSClientAsyncStream(
      treader,
      twriter,
      smtp.host,
      flags = flags)

  # Upgrade to TLS stream
  var newSmtp = Smtp(
    kind: SmtpClientScheme.Secure,
    transp: smtp.transp,
    treader: treader,
    twriter: twriter,
    tls: tls,
    reader: tls.reader,
    writer: tls.writer,
    flags: flags,
    host: smtp.host,
    port: smtp.port)
  smtp[] = newSmtp[]

  let speaksEsmtp = await smtp.ehlo
  if not speaksEsmtp:
    await smtp.helo

proc auth*(smtp: Smtp, username, password: string) {.async.} =
  ## Sends an AUTH command to the server to login as the `username`
  ## using `password`.
  ## May fail with ReplyError.

  await smtp.send(authCommand())
  await smtp.checkReply("334") # TODO: Check whether it's asking for the "Username:"
                               # i.e "334 VXNlcm5hbWU6"
  await smtp.send(encode(username) & "\c\L")
  await smtp.checkReply("334") # TODO: Same as above, only "Password:" (I think?)

  await smtp.send(encode(password) & "\c\L")
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

    await smtp.send(mailCommand(fromAddr))
    await smtp.checkReply("250")
    for address in items(toAddrs):
      await smtp.send(rcptCommand(address))
      await smtp.checkReply("250")

    # Send the message
    await smtp.send(dataCommand())
    await smtp.checkReply("354")
    await smtp.send(msg & "\c\L")
    await smtp.send(".\c\L")
    await smtp.checkReply("250")

proc close*(smtp: Smtp, quit: bool = true) {.async.} =
  ## Disconnects from the SMTP server and closes the stream.

  if quit:
    await smtp.send(quitComand())

  var futs: seq[Future[void]]
  if not smtp.reader.isNil and not smtp.reader.closed:
    futs.add smtp.reader.closeWait
  if not smtp.writer.isNil and not smtp.writer.closed:
    futs.add smtp.writer.closeWait
  if smtp.kind == SmtpClientScheme.Secure:
    if not smtp.treader.isNil and not smtp.treader.closed:
      futs.add smtp.treader.closeWait
    if not smtp.twriter.isNil and not smtp.twriter.closed:
      futs.add smtp.twriter.closeWait
  futs.add smtp.transp.closeWait

  if futs.len > 0: await noCancel(allFutures(futs))

  smtp.closed = true
