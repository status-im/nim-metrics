# Copyright (c) 2019 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0: http://www.apache.org/licenses/LICENSE-2.0)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import chronicles, unittest,
      ../metrics, ../metrics/chronicles_support

when defined(metrics):
  import tables

suite "logging":
  test "info":
    var registry = newRegistry()
    declareCounter myCounter, "help", registry = registry
    myCounter.inc()
    info "myCounter", myCounter
    declareCounter lCounter, "l help", @["foo", "bar"], registry
    let labelValues = @["a", "x \"y\" \n\\z"]
    lCounter.inc(4.5, labelValues = labelValues)
    info "lCounter", lCounter
    declareGauge myGauge, "help", registry = registry
    myGauge.set(9.5)
    info "myGauge", myGauge
    declareSummary mySummary, "help", registry = registry
    mySummary.observe(10)
    info "mySummary", mySummary
    declareHistogram myHistogram, "help", registry = registry
    myHistogram.observe(10)
    info "myHistogram", myHistogram
    when defined(metrics):
      for collector, metricsTable in registry.collect():
        for labels, metrics in metricsTable:
          for metric in metrics:
            info "metric", metric
    info "registry", registry
    info "default registry", defaultRegistry

