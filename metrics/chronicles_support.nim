# Copyright (c) 2019 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0: http://www.apache.org/licenses/LICENSE-2.0
# at your option. This file may not be copied, modified, or distributed except according to those terms.

from chronicles import formatIt, expandIt
import ../metrics

when defined(metrics):
  import tables

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

  proc toLog(c: Summary): auto =
    Collector(c).toLog()

  formatIt(Summary):
    it.toLog

  proc toLog(c: Histogram): auto =
    Collector(c).toLog()

  formatIt(Histogram):
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

  formatIt(Summary):
    "metrics disabled"

  formatIt(Histogram):
    "metrics disabled"

  formatIt(Registry):
    "metrics disabled"

# ignored collector
expandIt(type IgnoredCollector):
  ignored = "ignored"

