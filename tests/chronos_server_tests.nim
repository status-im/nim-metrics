# Copyright (c) 2021-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0: http://www.apache.org/licenses/LICENSE-2.0
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import std/[uri, unittest]
import chronos, chronos/apps/http/httpclient
import ../metrics, ../metrics/chronos_httpserver

suite "Chronos metrics HTTP server test suite":

  proc httpClient(url: string): Future[HttpResponseTuple] {.async.} =
    let session = HttpSessionRef.new()
    try:
      let resp = await session.fetch(parseUri(url))
      return resp
    finally:
      await session.closeWait()

  test "new()/close() test":
    proc test() {.async.} =
      let server = MetricsHttpServerRef.new("127.0.0.1", Port(8080)).get()
      block:
        let status = await server.status()
        check status == MetricsHttpServerStatus.Stopped
      await server.close()
      block:
        let status = await server.status()
        check status == MetricsHttpServerStatus.Closed
    when defined(metrics):
      waitFor test()
    else:
      check MetricsHttpServerRef.new("127.0.0.1", Port(8080)).isErr() == true
  test "new()/start()/stop()/close() test":
    proc test() {.async.} =
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
    when defined(metrics):
      waitFor test()
    else:
      check MetricsHttpServerRef.new("127.0.0.1", Port(8080)).isErr() == true
  test "new()/start()/response/stop()/start()/response/stop()/close() test":
    proc test() {.async.} =
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
    when defined(metrics):
      waitFor test()
    else:
      check MetricsHttpServerRef.new("127.0.0.1", Port(8080)).isErr() == true
  test "new()/start()/close() test":
    proc test() {.async.} =
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
    when defined(metrics):
      waitFor test()
    else:
      check MetricsHttpServerRef.new("127.0.0.1", Port(8080)).isErr() == true
  test "HTTP 200/responses check test":
    proc test() {.async.} =
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
    when defined(metrics):
      waitFor test()
    else:
      check MetricsHttpServerRef.new("127.0.0.1", Port(8080)).isErr() == true
  test "HTTP 404/response check test":
    proc test() {.async.} =
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
    when defined(metrics):
      waitFor test()
    else:
      check MetricsHttpServerRef.new("127.0.0.1", Port(8080)).isErr() == true
