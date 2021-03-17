################################
# HTTP server (for Prometheus) #
################################
when defined(nimHasUsed): {.used.}

import ../metrics
import std/os
import chronos, chronos/apps/http/httpserver

var httpServerThread: Thread[TransportAddress]

proc serveHttp(address: TransportAddress) {.thread.} =
  metrics.metricsIgnoreSignalsInThread()

  proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
    if r.isOk():
      let request = r.get()
      try:
        if request.uri.path == "/metrics":
          {.gcsafe.}:
            # Prometheus will drop our metrics in surprising ways if we give
            # it timestamps, so we don't.
            let response = defaultRegistry.toText(showTimestamp = false)
            let headers = HttpTable.init([("Content-Type", CONTENT_TYPE)])
            return await request.respond(Http200, response, headers)
        else:
          return await request.respond(Http404, "Try /metrics")
      except CatchableError as exc:
        printError(exc.msg)

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

{.push raises: [Defect].}

proc startMetricsHttpServer*(address = "127.0.0.1", port = Port(8000)) {.
     raises: [Exception].} =
  httpServerThread.createThread(serveHttp, initTAddress(address, port))
