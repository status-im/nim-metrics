# Copyright (c) 2019-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0: http://www.apache.org/licenses/LICENSE-2.0
# at your option. This file may not be copied, modified, or distributed except according to those terms.

################################
# HTTP server (for Prometheus) #
################################

{.push raises: [].}

when defined(nimHasUsed):
  {.used.}

import results
import chronos, chronos/apps/http/httpserver
export chronos, results

type
  MetricsError* = object of CatchableError

  MetricsHttpServerStatus* {.pure.} = enum
    Closed
    Running
    Stopped

  MetricsServerData = object
    when defined(metrics):
      address: TransportAddress
      requestPipe: tuple[read: AsyncFD, write: AsyncFD]
      responsePipe: tuple[read: AsyncFD, write: AsyncFD]

  MetricsHttpServerRef* = ref object
    when defined(metrics):
      data: MetricsServerData
      thread: Thread[MetricsServerData]
      reqTransp: StreamTransport
      respTransp: StreamTransport

  MetricsHttpServerMiddlewareRef* = ref object of HttpServerMiddlewareRef

when defined(metrics):
  import std/os
  import ../metrics, ./common

  var httpServerThread: Thread[TransportAddress]

  proc serveHttp(address: TransportAddress) {.thread.} =
    ignoreSignalsInThread()

    proc cb(
        r: RequestFence
    ): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
      if r.isOk():
        let request = r.get()
        try:
          if request.uri.path == "/metrics":
            {.gcsafe.}:
              # Prometheus will drop our metrics in surprising ways if we give
              # it timestamps, so we don't.
              let
                response = defaultRegistry.toText()
                headers = HttpTable.init([("Content-Type", CONTENT_TYPE)])
              return await request.respond(Http200, response, headers)
          elif request.uri.path == "/health":
            return await request.respond(Http200, "OK")
          else:
            return await request.respond(Http404, "Try /metrics")
        except HttpWriteError as exc:
          return defaultResponse(exc)

    let socketFlags = {ServerFlags.ReuseAddr}
    let res = HttpServerRef.new(address, cb, socketFlags = socketFlags)
    if res.isErr():
      printError(res.error())
      return
    let server = res.get()
    server.start()
    while true:
      try:
        waitFor server.join()
      except CatchableError as e:
        printError(e.msg)
        sleep(1000)

  const
    ResponseOk = 0'u8
    ResponseError = 1'u8
    MessageSize = 255

  type
    MetricsRequest {.pure.} = enum
      Status
      Start
      Stop
      Close

    MetricsResponse = object
      status: byte
      data: array[MessageSize, byte]

    MetricsThreadData = object
      reqTransp: StreamTransport
      respTransp: StreamTransport
      http: HttpServerRef

    MetricsErrorKind {.pure.} = enum
      Timeout
      Transport
      Communication

  proc raiseMetricsError(
      msg: string, exc: ref Exception
  ) {.noreturn, noinline, raises: [MetricsError].} =
    let message = msg & ", reason: [" & $exc.name & "]: " & $exc.msg
    raise (ref MetricsError)(msg: message, parent: exc)

  proc raiseMetricsError(msg: string) {.noreturn, noinline, raises: [MetricsError].} =
    raise (ref MetricsError)(msg: msg)

  proc raiseMetricsError(
      msg: MetricsErrorKind, exc: ref Exception
  ) {.noreturn, noinline, raises: [MetricsError].} =
    case msg
    of MetricsErrorKind.Timeout:
      raiseMetricsError("Connection with metrics thread timed out", exc)
    of MetricsErrorKind.Transport:
      raiseMetricsError("Communication with metrics thread failed", exc)
    of MetricsErrorKind.Communication:
      raiseMetricsError("Communication with metrics thread failed", exc)

  proc raiseMetricsError*(
      msg: string, err: OSErrorCode
  ) {.noreturn, noinline, raises: [MetricsError].} =
    let message = msg & ", reason: [OSError]: (" & $int(err) & ") " & osErrorMsg(err)
    raise (ref MetricsError)(msg: message)

  proc respond(
      m: MetricsThreadData, mtype: byte, message: string
  ) {.async: (raises: [CancelledError, MetricsError, TransportError]).} =
    var buffer: array[MessageSize + 1, byte]
    let length = min(len(message), len(buffer) - 1)
    zeroMem(cast[pointer](addr buffer[0]), len(buffer))
    buffer[0] = mtype
    if length > 0:
      copyMem(addr buffer[1], unsafeAddr message[0], length)
    let res = await m.respTransp.write(addr buffer[0], len(buffer))
    if res != len(buffer):
      raiseMetricsError("Incomplete response has been sent")

  proc communicate(
      m: MetricsHttpServerRef, req: MetricsRequest
  ): Future[MetricsResponse] {.
      async: (raises: [CancelledError, MetricsError, TransportError])
  .} =
    var buffer: array[MessageSize + 1, byte]
    buffer[0] = byte(req)
    block:
      let res = await m.reqTransp.write(addr buffer[0], 1)
      if res != 1:
        raiseMetricsError("Incomplete request has been sent")
    await m.respTransp.readExactly(addr buffer[0], len(buffer))
    var res = MetricsResponse(status: buffer[0])
    copyMem(addr res.data[0], addr buffer[1], sizeof(res.data))
    res

  proc getMessage(m: MetricsResponse): string =
    var res = newStringOfCap(MessageSize + 1)
    for i in 0 ..< len(m.data):
      let ch = m.data[i]
      if ch == 0x00'u8:
        break
      res.add(char(ch))
    res

  proc asyncStep(
      server: MetricsServerData, data: MetricsThreadData, lastError: string
  ): Future[bool] {.async: (raises: []).} =
    var buffer: array[1, byte]
    try:
      await data.reqTransp.readExactly(addr buffer[0], len(buffer))

      if len(lastError) > 0:
        await data.respond(ResponseError, lastError)
        return true

      if isNil(data.http):
        await data.respond(ResponseError, "HTTP server is not bound!")
        return true

      case buffer[0]
      of byte(MetricsRequest.Status):
        let message =
          case data.http.state()
          of ServerStopped: "STOPPED"
          of ServerClosed: "CLOSED"
          of ServerRunning: "RUNNING"
        await data.respond(ResponseOk, message)
        true
      of byte(MetricsRequest.Start):
        if data.http.state() != HttpServerState.ServerStopped:
          let message =
            if data.http.state() == HttpServerState.ServerClosed:
              "HTTP server is already closed"
            else:
              "HTTP server is already running"
          await data.respond(ResponseError, message)
        else:
          data.http.start()
          await data.respond(ResponseOk, "")
        true
      of byte(MetricsRequest.Stop):
        if data.http.state() != HttpServerState.ServerRunning:
          let message =
            if data.http.state() == HttpServerState.ServerClosed:
              "HTTP server is already closed"
            else:
              "HTTP server is already stopped"
          await data.respond(ResponseError, message)
        else:
          await data.http.stop()
          await data.respond(ResponseOk, "")
        true
      else:
        if data.http.state() == HttpServerState.ServerClosed:
          await data.respond(ResponseError, "HTTP server is already closed")
          true
        else:
          await data.http.closeWait()
          await data.respond(ResponseOk, "")
          false
    except MetricsError:
      if not (isNil(data.http)):
        await data.http.closeWait()
      return false
    except TransportError:
      if not (isNil(data.http)):
        await data.http.closeWait()
      return false
    except HttpError:
      if not (isNil(data.http)):
        await data.http.closeWait()
      return false
    except CancelledError:
      # We did not use cancellation.
      if not (isNil(data.http)):
        await data.http.closeWait()
      return false

  proc asyncLoop(server: MetricsServerData) {.async: (raises: []).} =
    var lastError = ""

    proc cb(
        r: RequestFence
    ): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
      if r.isOk():
        let request = r.get()
        try:
          if request.uri.path == "/metrics":
            # Prometheus will drop our metrics in surprising ways if we give
            # it timestamps, so we don't.
            let
              response = block:
                {.gcsafe.}:
                  defaultRegistry.toText()
              headers = HttpTable.init([("Content-Type", CONTENT_TYPE)])
            await request.respond(Http200, response, headers)
          elif request.uri.path == "/health":
            await request.respond(Http200, "OK")
          else:
            await request.respond(Http404, "Try /metrics")
        except HttpError as exc:
          defaultResponse(exc)
      else:
        defaultResponse()

    let
      http = block:
        let
          socketFlags = {ServerFlags.ReuseAddr}
          res = HttpServerRef.new(server.address, cb, socketFlags = socketFlags)
        if res.isErr():
          lastError = res.error()
          nil
        else:
          res.get()
      reqTransp = fromPipe2(server.requestPipe.read).valueOr:
        await http.closeWait()
        return
      respTransp = fromPipe2(server.responsePipe.write).valueOr:
        await http.closeWait()
        await reqTransp.closeWait()
        return
      threadData =
        MetricsThreadData(reqTransp: reqTransp, respTransp: respTransp, http: http)

    while true:
      let res = await asyncStep(server, threadData, lastError)
      if not (res):
        break

    await noCancel allFutures(reqTransp.closeWait(), respTransp.closeWait())

  proc serveMetricsServer(server: MetricsServerData) {.thread.} =
    ignoreSignalsInThread()
    let loop {.used.} = getThreadDispatcher()
    waitFor asyncLoop(server)

proc startMetricsHttpServer*(
    address = "127.0.0.1", port = Port(8000)
) {.raises: [Exception], deprecated: "Please use MetricsHttpServerRef API".} =
  when defined(metrics):
    httpServerThread.createThread(serveHttp, initTAddress(address, port))

proc new*(
    t: typedesc[MetricsHttpServerRef], address: string, port: Port
): Result[MetricsHttpServerRef, cstring] {.raises: [].} =
  ## Initialize new instance of MetricsHttpServerRef.
  ##
  ## This involves creation of new thread and new processing loop in the new
  ## thread.
  when defined(metrics):
    template closePipe(b: untyped): untyped =
      closeHandle(b.read)
      closeHandle(b.write)

    let taddress =
      try:
        initTAddress(address, port)
      except TransportAddressError:
        return err("Invalid server address")
    var
      request = block:
        let res = createAsyncPipe()
        if (res.read == asyncInvalidPipe) or (res.write == asyncInvalidPipe):
          return err("Unable to create communication request pipe")
        res
      cleanupRequest = true
    defer:
      if cleanupRequest:
        request.closePipe()

    var
      response = block:
        let res = createAsyncPipe()
        if (res.read == asyncInvalidPipe) or (res.write == asyncInvalidPipe):
          request.closePipe()
          return err("Unable to create communication response pipe")
        res
      cleanupResponse = true
    defer:
      if cleanupResponse:
        response.closePipe()

    let data =
      MetricsServerData(address: taddress, requestPipe: request, responsePipe: response)
    var server = MetricsHttpServerRef(data: data)
    try:
      createThread(server.thread, serveMetricsServer, data)
    except Exception:
      return err("Unexpected error while spawning metrics server's thread")
    except ResourceExhaustedError:
      return err("Unable to spawn metrics server's thread")

    server.reqTransp =
      try:
        fromPipe(request.write)
      except CatchableError:
        return err(
          "Unable to establish communication channel with " & "metrics server thread"
        )
    server.respTransp =
      try:
        fromPipe(response.read)
      except CatchableError:
        return err(
          "Unable to establish communication channel with " & "metrics server thread"
        )

    cleanupRequest = false
    cleanupResponse = false
    ok(server)
  else:
    err("Could not initialize metrics server, because metrics are disabled")

proc start*(
    server: MetricsHttpServerRef
) {.async: (raises: [MetricsError, CancelledError]).} =
  ## Start metrics HTTP server.
  when defined(metrics):
    if not (server.thread.running()):
      raiseMetricsError("Metrics server is not running")
    let resp =
      try:
        await communicate(server, MetricsRequest.Start).wait(5.seconds)
      except AsyncTimeoutError as exc:
        raiseMetricsError(MetricsErrorKind.Timeout, exc)
      except MetricsError as exc:
        raiseMetricsError(MetricsErrorKind.Communication, exc)
      except TransportError as exc:
        raiseMetricsError(MetricsErrorKind.Transport, exc)
    if resp.status != 0x00'u8:
      raiseMetricsError("Metrics server returns an error: " & resp.getMessage())

proc stop*(
    server: MetricsHttpServerRef
) {.async: (raises: [MetricsError, CancelledError]).} =
  ## Force metrics HTTP server to stop accepting new connections.
  when defined(metrics):
    if not (server.thread.running()):
      raiseMetricsError("Metrics server is not running")
    let resp =
      try:
        await communicate(server, MetricsRequest.Stop).wait(5.seconds)
      except AsyncTimeoutError as exc:
        raiseMetricsError(MetricsErrorKind.Timeout, exc)
      except MetricsError as exc:
        raiseMetricsError(MetricsErrorKind.Communication, exc)
      except TransportError as exc:
        raiseMetricsError(MetricsErrorKind.Transport, exc)
    if resp.status != 0x00'u8:
      raiseMetricsError("Metrics server returns an error: " & resp.getMessage())

proc close*(server: MetricsHttpServerRef) {.async: (raises: []).} =
  ## Close metrics HTTP server and release all the resources.
  when defined(metrics):
    # We ignore all the exception because there is no way to report error.
    if not (server.thread.running()):
      return

    try:
      discard await communicate(server, MetricsRequest.Close).wait(5.seconds)
    except AsyncTimeoutError:
      discard
    except MetricsError:
      discard
    except TransportError:
      discard
    except CancelledError:
      discard

    # Closing pipes, other pipe ends should be closed by foreign thread.
    await noCancel allFutures(
      server.reqTransp.closeWait(), server.respTransp.closeWait()
    )
    # Thread should exit very soon.
    server.thread.joinThread()

proc status*(
    server: MetricsHttpServerRef
): Future[MetricsHttpServerStatus] {.async: (raises: [CancelledError, MetricsError]).} =
  ## Returns current status of metrics HTTP server.
  ##
  ## Note, that if `metrics` variable is not defined this procedure will return
  ## ``MetricsHttpServerStatus.Closed``.
  when defined(metrics):
    if not (server.thread.running()):
      return MetricsHttpServerStatus.Closed

    let resp =
      try:
        await communicate(server, MetricsRequest.Status).wait(5.seconds)
      except AsyncTimeoutError as exc:
        raiseMetricsError(MetricsErrorKind.Timeout, exc)
      except MetricsError as exc:
        raiseMetricsError(MetricsErrorKind.Communication, exc)
      except TransportError as exc:
        raiseMetricsError(MetricsErrorKind.Transport, exc)

    if resp.status != 0x00'u8:
      raiseMetricsError("Metrics server returns an error: " & resp.getMessage())

    case resp.getMessage()
    of "STOPPED":
      MetricsHttpServerStatus.Stopped
    of "CLOSED":
      MetricsHttpServerStatus.Closed
    of "RUNNING":
      MetricsHttpServerStatus.Running
    else:
      raiseMetricsError("Metrics server returns unsupported status!")
  else:
    MetricsHttpServerStatus.Closed

proc new*(t: typedesc[MetricsHttpServerMiddlewareRef]): HttpServerMiddlewareRef =
  proc middlewareCallback(
      middleware: HttpServerMiddlewareRef,
      reqfence: RequestFence,
      handler: HttpProcessCallback2,
  ): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
    if reqfence.isOk():
      let request = reqfence.get()
      try:
        if request.uri.path == "/metrics":
          when defined(metrics):
            # Prometheus will drop our metrics in surprising ways if we give
            # it timestamps, so we don't.
            let
              response = block:
                {.gcsafe.}:
                  defaultRegistry.toText()
              headers = HttpTable.init([("Content-Type", CONTENT_TYPE)])
            await request.respond(Http200, response, headers)
          else:
            await request.respond(
              Http200, "Metrics are not enabled, build your application with -d:metrics"
            )
        elif request.uri.path == "/health":
          await request.respond(Http200, "OK")
        else:
          await handler(reqfence)
      except HttpWriteError as exc:
        defaultResponse(exc)
    else:
      await handler(reqfence)

  let middleware = MetricsHttpServerMiddlewareRef(handler: middlewareCallback)
  HttpServerMiddlewareRef(middleware)
