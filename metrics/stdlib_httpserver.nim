# Copyright (c) 2019-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0: http://www.apache.org/licenses/LICENSE-2.0
# at your option. This file may not be copied, modified, or distributed except according to those terms.

################################
# HTTP server (for Prometheus) #
################################

when defined(nimHasUsed):
  {.used.}

import net

when defined(metrics):
  import std/[os, asynchttpserver, asyncdispatch],
    ../metrics, ./common

  type HttpServerArgs = tuple[address: string, port: Port]
  var httpServerThread: Thread[HttpServerArgs]

  proc httpServer(args: HttpServerArgs) {.thread.} =
    ignoreSignalsInThread()

    let (address, port) = args
    var server = newAsyncHttpServer(reuseAddr = true, reusePort = true)

    proc cb(req: Request) {.async.} =
      try:
        if req.url.path == "/metrics":
          {.gcsafe.}:
              # Prometheus will drop our metrics in surprising ways if we give
              # it timestamps, so we don't.
              await req.respond(Http200,
                                defaultRegistry.toText(showTimestamp = false),
                               newHttpHeaders([("Content-Type", CONTENT_TYPE)]))
        elif req.url.path == "/health":
          await req.respond(Http200, "OK")
        else:
          await req.respond(Http404, "Try /metrics")
      except CatchableError as e:
        printError(e.msg)

    while true:
      try:
        waitFor server.serve(port, cb, address)
      except CatchableError as e:
        printError(e.msg)
        sleep(1000)

{.push raises: [Defect].}

proc startMetricsHttpServer*(address = "127.0.0.1", port = Port(8000)) {.
     raises: [Exception].} =
  when defined(metrics):
    httpServerThread.createThread(httpServer, (address, port))

