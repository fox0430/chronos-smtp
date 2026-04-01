# (c) Copyright 2024 Shuhei Nogawa
# This software is released under the MIT License, see LICENSE.
#
# Copyright (c) 2012 Dominik Picheta
# https://github.com/nim-lang/smtp/blob/master/LICENSE

import std/[base64, strtabs, strutils, strformat, sysrand]
from std/times import now, utc, format, toTime, toUnix

import
  pkg/chronos,
  pkg/chronos/streams/tlsstream,
  pkg/chronos/transports/common,
  pkg/chronos/transports/stream,
  pkg/chronicles

export chronos, Port, TLSFlags, Duration, AsyncTimeoutError

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

  AuthMethod* = enum
    AuthLogin
    AuthPlain

  SmtpError* = object of AsyncError
  ReplyError* = object of SmtpError

  TlsContext = object
    treader: AsyncStreamReader
    twriter: AsyncStreamWriter
    stream: TLSAsyncStream
    flags: set[TLSFlags]

  Smtp* = ref object
    closed*: bool
    tlsCtx: TlsContext
    transp: StreamTransport
    reader: AsyncStreamReader
    writer: AsyncStreamWriter
    host: string
    port: Port
    useTls: bool
    timeout*: Duration
    logs*: seq[string]

proc kind*(smtp: Smtp): SmtpClientScheme =
  if smtp.useTls: SmtpClientScheme.Secure else: SmtpClientScheme.NonSecure

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

proc quitCommand*(): string {.inline.} =
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

proc authLoginCommand*(): string {.inline.} =
  "AUTH LOGIN\c\L"

proc authPlainCommand*(username, password: string): string {.inline.} =
  "AUTH PLAIN " & encode("\0" & username & "\0" & password) & "\c\L"

proc containsNewline(xs: seq[string]): bool =
  for x in xs:
    if x.contains({'\c', '\L'}):
      return true

proc generateDate(): string =
  ## Generate a date string in RFC 5322 format.
  now().utc.format("ddd, dd MMM yyyy HH:mm:ss '+0000'")

proc generateMessageId(domain: string = "localhost"): string =
  ## Generate a unique Message-ID in RFC 5322 format.
  var randomBytes: array[8, byte]
  if not urandom(randomBytes):
    raise newException(ValueError, "Failed to generate random bytes")
  var hex = ""
  for b in randomBytes:
    hex.add(b.toHex(2).toLowerAscii())
  "<" & $now().toTime.toUnix & "." & hex & "@" & domain & ">"

proc send*(smtp: Smtp, cmd: string) {.async.} =
  smtp.logs.add fmt"Client: {cmd}"
  debug "Client:", cmd

  await smtp.writer.write(cmd).wait(smtp.timeout)

proc read*(smtp: Smtp): Future[string] {.async.} =
  ## Return all lines of a (possibly multiline) SMTP response.
  ## Multiline responses use "xxx-" for continuation and "xxx " for the final line.

  var line = await smtp.reader.readLine().wait(smtp.timeout)
  result.add line
  while line.len > 3 and line[3] == '-':
    line = await smtp.reader.readLine().wait(smtp.timeout)
    result.add '\n' & line

  smtp.logs.add fmt"Server: {result}"
  debug "Server:", result

proc readLine*(smtp: Smtp): Future[string] {.async.} =
  result = await smtp.reader.readLine().wait(smtp.timeout)

  smtp.logs.add fmt"Server: {result}"
  debug "Server:", result

proc quitExcpt(smtp: Smtp, msg: string) {.async.} =
  await smtp.send(quitCommand())
  raise newException(ReplyError, msg)

proc createMessage*(
    mSubject, mBody: string,
    mTo, mCc: seq[string],
    otherHeaders: openArray[tuple[name, value: string]],
): Message =
  ## Creates a new MIME compliant message.
  ##
  ## You need to make sure that `mSubject`, `mTo` and `mCc` don't contain
  ## any newline characters. Failing to do so will raise `AssertionDefect`.
  if mSubject.contains({'\c', '\L'}):
    raise
      newException(ValueError, "'mSubject' shouldn't contain any newline characters")
  if mTo.containsNewline() or mCc.containsNewline():
    raise newException(
      ValueError, "'mTo' and 'mCc' shouldn't contain any newline characters"
    )

  result.msgTo = mTo
  result.msgCc = mCc
  result.msgSubject = mSubject
  result.msgBody = mBody
  result.msgOtherHeaders = newStringTable()
  for n, v in items(otherHeaders):
    result.msgOtherHeaders[n] = v

  if "Date" notin result.msgOtherHeaders:
    result.msgOtherHeaders["Date"] = generateDate()
  if "Message-ID" notin result.msgOtherHeaders:
    result.msgOtherHeaders["Message-ID"] = generateMessageId()

proc createMessage*(
    mSubject, mBody: string, mTo: seq[string] = @[], mCc: seq[string] = @[]
): Message =
  ## Alternate version of the above.
  ##
  ## You need to make sure that `mSubject`, `mTo` and `mCc` don't contain
  ## any newline characters. Failing to do so will raise `ValueError`.
  createMessage(mSubject, mBody, mTo, mCc, {:})

proc `$`*(msg: Message): string =
  ## stringify for `Message`.
  if msg.msgTo.len() > 0:
    result = "To: " & msg.msgTo.join(", ") & "\c\L"
  if msg.msgCc.len() > 0:
    result.add("Cc: " & msg.msgCc.join(", ") & "\c\L")
  # TODO: Folding? i.e when a line is too long, shorten it...
  result.add("Subject: " & msg.msgSubject & "\c\L")
  for key, value in pairs(msg.msgOtherHeaders):
    result.add(key & ": " & value & "\c\L")

  result.add("\c\L")
  result.add(msg.msgBody)

proc newSmtp*(useTls: bool = false, timeout = InfiniteDuration): Smtp =
  Smtp(useTls: useTls, timeout: timeout)

proc checkReply*(smtp: Smtp, reply: string, quitWhenFailed: bool = true) {.async.} =
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
  ## Sends the LHLO request (for LMTP)
  await smtp.send(lhloCommand(smtp.host))
  await smtp.checkReply("250")

proc ehlo*(smtp: Smtp): Future[bool] {.async.} =
  ## Sends EHLO request.
  ## Return `true` if server supports `EHLO`, false otherwise.
  await smtp.send(ehloCommand(smtp.host))
  let reply = await smtp.read
  return reply.startsWith("250")

proc cleanupResources(smtp: Smtp) {.async.} =
  ## Close all open streams and transport on the smtp object.
  var futs: seq[Future[void]]
  if not smtp.reader.isNil and not smtp.reader.closed:
    futs.add smtp.reader.closeWait
  if not smtp.writer.isNil and not smtp.writer.closed:
    futs.add smtp.writer.closeWait
  if not smtp.tlsCtx.treader.isNil and not smtp.tlsCtx.treader.closed:
    futs.add smtp.tlsCtx.treader.closeWait
  if not smtp.tlsCtx.twriter.isNil and not smtp.tlsCtx.twriter.closed:
    futs.add smtp.tlsCtx.twriter.closeWait
  if not smtp.transp.isNil:
    futs.add smtp.transp.closeWait
  if futs.len > 0:
    await noCancel(allFutures(futs))

  smtp.closed = true

proc connect*(
    smtp: Smtp,
    host: string,
    port: Port,
    flags: set[TLSFlags] = {},
    helo: bool = true,
    quitWhenFailed: bool = true,
) {.async.} =
  ## Establishes a connection with a SMTP server.

  let addresses = resolveTAddress(host, port)
  var lastError = ""
  for a in addresses:
    let transp =
      try:
        await connect(a).wait(smtp.timeout)
      except CancelledError as e:
        raise e
      except AsyncTimeoutError as e:
        raise e
      except TransportError:
        nil

    if not transp.isNil:
      smtp.transp = transp
      smtp.host = host
      smtp.port = port

      if not smtp.useTls:
        smtp.reader = newAsyncStreamReader(smtp.transp)
        smtp.writer = newAsyncStreamWriter(smtp.transp)
      else:
        let
          treader = newAsyncStreamReader(smtp.transp)
          twriter = newAsyncStreamWriter(smtp.transp)

          tls =
            try:
              newTLSClientAsyncStream(treader, twriter, host, flags = flags)
            except TLSStreamInitError as e:
              lastError = e.msg
              var futs: seq[Future[void]]
              futs.add treader.closeWait
              futs.add twriter.closeWait
              futs.add transp.closeWait
              await noCancel(allFutures(futs))
              continue

        smtp.tlsCtx =
          TlsContext(treader: treader, twriter: twriter, stream: tls, flags: flags)
        smtp.reader = tls.reader
        smtp.writer = tls.writer

      try:
        await smtp.checkReply("220", quitWhenFailed)

        if helo:
          let speaksEsmtp = await smtp.ehlo
          if not speaksEsmtp:
            await smtp.helo
      except CatchableError as e:
        await noCancel(smtp.cleanupResources)
        raise e

      return

  # If all attempts to connect to the remote host have failed.
  if lastError.len > 0:
    raise
      newException(SmtpError, "Could not connect to remote host, reason: " & lastError)
  else:
    raise newException(SmtpError, "Could not connect to remote host")

proc dial*(
    host: string,
    port: Port,
    useTls: bool = false,
    flags: set[TLSFlags] = {},
    helo: bool = true,
    quitWhenFailed: bool = true,
    timeout = InfiniteDuration,
): Future[Smtp] {.async.} =
  let smtp = newSmtp(useTls, timeout)
  try:
    await smtp.connect(host, port, flags, helo, quitWhenFailed)
  except CatchableError as e:
    await noCancel(smtp.cleanupResources)
    raise e
  return smtp

proc startTls*(smtp: Smtp, flags: set[TLSFlags] = {}) {.async.} =
  ## Put the SMTP connection in TLS (Transport Layer Security) mode.
  ## May fail with ReplyError
  await smtp.send(starttlsCommand())
  await smtp.checkReply("220")

  # Create new TLS streams first (before closing old ones)
  # If TLS init fails, old streams remain usable
  let
    treader = newAsyncStreamReader(smtp.transp)
    twriter = newAsyncStreamWriter(smtp.transp)
    tls =
      try:
        newTLSClientAsyncStream(treader, twriter, smtp.host, flags = flags)
      except TLSStreamInitError as e:
        var futs: seq[Future[void]]
        futs.add treader.closeWait
        futs.add twriter.closeWait
        await noCancel(allFutures(futs))
        raise e

  # TLS succeeded - now close old reader/writer
  var closeFuts: seq[Future[void]]
  if not smtp.reader.isNil and not smtp.reader.closed:
    closeFuts.add smtp.reader.closeWait
  if not smtp.writer.isNil and not smtp.writer.closed:
    closeFuts.add smtp.writer.closeWait
  if closeFuts.len > 0:
    await noCancel(allFutures(closeFuts))

  # Upgrade to TLS stream
  smtp.useTls = true
  smtp.tlsCtx =
    TlsContext(treader: treader, twriter: twriter, stream: tls, flags: flags)
  smtp.reader = tls.reader
  smtp.writer = tls.writer

  let speaksEsmtp = await smtp.ehlo
  if not speaksEsmtp:
    await smtp.helo

proc checkChallenge(smtp: Smtp, expected: string) {.async.} =
  ## Read a 334 challenge response and verify its payload matches `expected`.
  let line = await smtp.read
  if not line.startsWith("334"):
    await quitExcpt(smtp, "Expected 334 reply, got: " & line)
  let payload = line[4 ..^ 1].strip()
  if payload != expected:
    await quitExcpt(smtp, "Unexpected 334 challenge: " & payload)

proc auth*(
    smtp: Smtp, username, password: string, authMethod: AuthMethod = AuthLogin
) {.async.} =
  ## Sends an AUTH command to the server to login as the `username`
  ## using `password`.
  ## May fail with ReplyError.

  case authMethod
  of AuthLogin:
    await smtp.send(authLoginCommand())
    await smtp.checkChallenge("VXNlcm5hbWU6") # Base64 "Username:"
    await smtp.send(encode(username) & "\c\L")
    await smtp.checkChallenge("UGFzc3dvcmQ6") # Base64 "Password:"
    await smtp.send(encode(password) & "\c\L")
    await smtp.checkReply("235")
  of AuthPlain:
    await smtp.send(authPlainCommand(username, password))
    await smtp.checkReply("235")

proc sendMail*(
    smtp: Smtp, fromAddr: string, toAddrs: seq[string], msg: string
) {.async.} =
  ## Sends `msg` from `fromAddr` to the addresses specified in `toAddrs`.
  ## Messages may be formed using `createMessage` by converting the
  ## Message into a string.
  ##
  ## You need to make sure that `fromAddr` and `toAddrs` don't contain
  ## any newline characters. Failing to do so will raise `ValueError`.
  if toAddrs.containsNewline() or fromAddr.contains({'\c', '\L'}):
    raise newException(
      ValueError, "'toAddrs' and 'fromAddr' shouldn't contain any newline characters"
    )

  await smtp.send(mailCommand(fromAddr))
  await smtp.checkReply("250")
  for address in items(toAddrs):
    await smtp.send(rcptCommand(address))
    await smtp.checkReply("250")

  # Send the message
  await smtp.send(dataCommand())
  await smtp.checkReply("354")

  # Dot transparency (RFC 5321 Section 4.5.2):
  # Lines starting with "." must be escaped by prepending an extra ".".
  var stuffed = msg.replace("\c\L.", "\c\L..")
  if stuffed.startsWith("."):
    stuffed = "." & stuffed
  await smtp.send(stuffed & "\c\L")
  await smtp.send(".\c\L")
  await smtp.checkReply("250")

proc close*(smtp: Smtp, quit: bool = true) {.async.} =
  ## Disconnects from the SMTP server and closes the stream.

  if quit:
    try:
      await smtp.send(quitCommand())
    except CancelledError as e:
      raise e
    except CatchableError:
      discard

  await noCancel(smtp.cleanupResources)
