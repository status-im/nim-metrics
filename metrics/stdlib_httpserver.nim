################################
# HTTP server (for Prometheus) #
################################
when defined(nimHasUsed): {.used.}

import ../metrics
import std/[os, asynchttpserver, asyncdispatch]

type HttpServerArgs = tuple[address: string, port: Port]
var httpServerThread: Thread[HttpServerArgs]

proc httpServer(args: HttpServerArgs) {.thread.} =
  metricsIgnoreSignalsInThread()

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
  httpServerThread.createThread(httpServer, (address, port))
