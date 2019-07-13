# nim-metrics
# Copyright (c) 2019 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

from chronicles import formatIt, expandIt
import sets, tables,
      ../metrics

when defined(metrics):
  formatIt(Metric):
    it.toText(showTimestamp = false)

  proc toLog(collector: Collector): seq[string] =
    result = @[]
    for metrics in collector.metrics.values():
      for metric in metrics:
        result.add(metric.toText(showTimestamp = false))

  proc toLog(c: Counter): auto =
    Collector(c).toLog()

  formatIt(Counter):
    it.toLog

  proc toLog(c: Gauge): auto =
    Collector(c).toLog()

  formatIt(Gauge):
    it.toLog

  proc toLog(registry: Registry): seq[seq[string]] =
    result = @[]
    {.gcsafe.}:
      for metricsTable in registry.collect().values():
        for metrics in metricsTable.values():
          var res: seq[string]
          for metric in metrics:
            res.add(metric.toText(showTimestamp = false))
          result.add(res)

  formatIt(Registry):
    it.toLog
else:
  # not defined(metrics)
  formatIt(Metric):
    "metrics disabled"

  formatIt(Counter):
    "metrics disabled"

  formatIt(Gauge):
    "metrics disabled"

  formatIt(Registry):
    "metrics disabled"

