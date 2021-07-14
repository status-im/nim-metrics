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
  import std/os,
    chronos, chronos/apps/http/httpserver,
    ../metrics, ./common

  var httpServerThread: Thread[TransportAddress]

  proc serveHttp(address: TransportAddress) {.thread.} =
    ignoreSignalsInThread()

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
          elif request.uri.path == "/health":
            return await request.respond(Http200, "OK")
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
  when defined(metrics):
    httpServerThread.createThread(serveHttp, initTAddress(address, port))

