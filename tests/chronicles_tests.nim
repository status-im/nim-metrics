# nim-metrics
# Copyright (c) 2019 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import chronicles, tables, unittest,
      ../metrics, ../metrics/chronicles_support

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
    when defined(metrics):
      for collector, metricsTable in registry.collect():
        for labels, metrics in metricsTable:
          for metric in metrics:
            info "metric", metric
    info "registry", registry

