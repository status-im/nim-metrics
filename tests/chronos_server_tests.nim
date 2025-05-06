# Copyright (c) 2021-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0: http://www.apache.org/licenses/LICENSE-2.0
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import std/[uri]
import chronos, chronos/apps/http/[httpclient, httpserver]
import chronos/unittest2/asynctests
import ../metrics, ../metrics/chronos_httpserver

suite "Chronos metrics HTTP server test suite":
  proc httpClient(
      url: string
  ): Future[HttpResponseTuple] {.async: (raises: [CancelledError, HttpError]).} =
    let session = HttpSessionRef.new()
    try:
      await session.fetch(parseUri(url))
    finally:
      await session.closeWait()

  asyncTest "new()/close() test":
    when defined(metrics):
      let server = MetricsHttpServerRef.new("127.0.0.1", Port(8080)).get()
      block:
        let status = await server.status()
        check status == MetricsHttpServerStatus.Stopped
      await server.close()
      block:
        let status = await server.status()
        check status == MetricsHttpServerStatus.Closed
    else:
      check MetricsHttpServerRef.new("127.0.0.1", Port(8080)).isErr() == true

  asyncTest "new()/start()/stop()/close() test":
    when defined(metrics):
      let server = MetricsHttpServerRef.new("127.0.0.1", Port(8080)).get()
      block:
        let status = await server.status()
        check status == MetricsHttpServerStatus.Stopped
      await server.start()
      block:
        let status = await server.status()
        check status == MetricsHttpServerStatus.Running
      await server.stop()
      block:
        let status = await server.status()
        check status == MetricsHttpServerStatus.Stopped
      await server.close()
      block:
        let status = await server.status()
        check status == MetricsHttpServerStatus.Closed
    else:
      check MetricsHttpServerRef.new("127.0.0.1", Port(8080)).isErr() == true

  asyncTest "new()/start()/response/stop()/start()/response/stop()/close() " & "test":
    when defined(metrics):
      let server = MetricsHttpServerRef.new("127.0.0.1", Port(8080)).get()
      block:
        let status = await server.status()
        check status == MetricsHttpServerStatus.Stopped
      await server.start()
      block:
        let status = await server.status()
        check status == MetricsHttpServerStatus.Running
      block:
        let resp = await httpClient("http://127.0.0.1:8080/health")
        check:
          resp.status == 200
          resp.data.bytesToString == "OK"
      await server.stop()
      block:
        let status = await server.status()
        check status == MetricsHttpServerStatus.Stopped
      await server.start()
      block:
        let status = await server.status()
        check status == MetricsHttpServerStatus.Running
      block:
        let resp = await httpClient("http://127.0.0.1:8080/health")
        check:
          resp.status == 200
          resp.data.bytesToString == "OK"
      await server.stop()
      block:
        let status = await server.status()
        check status == MetricsHttpServerStatus.Stopped
      await server.close()
      block:
        let status = await server.status()
        check status == MetricsHttpServerStatus.Closed
    else:
      check MetricsHttpServerRef.new("127.0.0.1", Port(8080)).isErr() == true

  asyncTest "new()/start()/close() test":
    when defined(metrics):
      let server = MetricsHttpServerRef.new("127.0.0.1", Port(8080)).get()
      block:
        let status = await server.status()
        check status == MetricsHttpServerStatus.Stopped
      await server.start()
      block:
        let status = await server.status()
        check status == MetricsHttpServerStatus.Running
      await server.close()
      block:
        let status = await server.status()
        check status == MetricsHttpServerStatus.Closed
    else:
      check MetricsHttpServerRef.new("127.0.0.1", Port(8080)).isErr() == true

  asyncTest "HTTP 200/responses check test":
    when defined(metrics):
      let server = MetricsHttpServerRef.new("127.0.0.1", Port(8080)).get()
      block:
        let status = await server.status()
        check status == MetricsHttpServerStatus.Stopped
      await server.start()
      block:
        let status = await server.status()
        check status == MetricsHttpServerStatus.Running
      block:
        let resp = await httpClient("http://127.0.0.1:8080/metrics")
        check:
          resp.status == 200
          len(resp.data) > 0

      block:
        let resp = await httpClient("http://127.0.0.1:8080/health")
        check:
          resp.status == 200
          resp.data.bytesToString() == "OK"
      await server.stop()
      block:
        let status = await server.status()
        check status == MetricsHttpServerStatus.Stopped
      await server.close()
      block:
        let status = await server.status()
        check status == MetricsHttpServerStatus.Closed
    else:
      check MetricsHttpServerRef.new("127.0.0.1", Port(8080)).isErr() == true

  asyncTest "HTTP 404/response check test":
    when defined(metrics):
      let server = MetricsHttpServerRef.new("127.0.0.1", Port(8080)).get()
      block:
        let status = await server.status()
        check status == MetricsHttpServerStatus.Stopped
      await server.start()
      block:
        let status = await server.status()
        check status == MetricsHttpServerStatus.Running

      block:
        let resp = await httpClient("http://127.0.0.1:8080/somePath")
        check:
          resp.status == 404
          len(resp.data) > 0

      await server.stop()
      block:
        let status = await server.status()
        check status == MetricsHttpServerStatus.Stopped
      await server.close()
      block:
        let status = await server.status()
        check status == MetricsHttpServerStatus.Closed
    else:
      check MetricsHttpServerRef.new("127.0.0.1", Port(8080)).isErr() == true

  asyncTest "Chronos middleware test":
    when defined(metrics):
      proc process(
          r: RequestFence
      ): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
        if r.isOk():
          let request = r.get()
          if request.uri.path == "/test":
            try:
              await request.respond(Http200, "TESTOK")
            except HttpWriteError as exc:
              defaultResponse(exc)
          else:
            defaultResponse()
        else:
          defaultResponse()

      let
        socketFlags = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr}
        middlewares = [MetricsHttpServerMiddlewareRef.new()]
        res = HttpServerRef.new(
          initTAddress("127.0.0.1:0"),
          process,
          middlewares = middlewares,
          socketFlags = socketFlags,
        )
      check res.isOk()
      let server = res.get()
      server.start()
      try:
        let
          address = server.instance.localAddress()
          uri1 = "http://" & $address & "/metrics"
          uri2 = "http://" & $address & "/health"
          uri3 = "http://" & $address & "/test"
          res1 = await httpClient(uri1)
          res2 = await httpClient(uri2)
          res3 = await httpClient(uri3)
        check:
          res1.status == 200
          len(res1.data) > 0
          res2.status == 200
          res2.data.bytesToString() == "OK"
          res3.status == 200
          res3.data.bytesToString() == "TESTOK"
      finally:
        await server.stop()
        await server.closeWait()
    else:
      check not (isNil(MetricsHttpServerMiddlewareRef.new()))
