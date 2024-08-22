# Copyright (c) 2019 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0: http://www.apache.org/licenses/LICENSE-2.0
# at your option. This file may not be copied, modified, or distributed except according to those terms.

from chronicles import formatIt, expandIt

import ../metrics, std/[locks, times]

when defined(metrics):
  import tables

  formatIt(Metric):
    $it

  proc toLog(collector: SimpleCollector): seq[string] =
    withLock collector.lock:
      for metrics in collector.metrics:
        for metric in metrics:
          result.add($metric)

  formatIt(Counter):
    it.toLog

  formatIt(Gauge):
    it.toLog

  formatIt(Summary):
    it.toLog

  formatIt(Histogram):
    it.toLog

  proc toLog(registry: Registry): seq[string] =
    var res: seq[string]
    registry.collect(
      proc(
        name: string,
        value: float64,
        labels: openArray[string],
        labelValues: openArray[string],
        timestamp: Time,
      ) =
          res.add(
            $Metric(
              name: name,
              value: value,
              labels: @labels,
              labelValues: @labelValues,
              timestamp: timestamp,
            )
          )
    )
    res

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
