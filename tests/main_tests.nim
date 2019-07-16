# nim-metrics
# Copyright (c) 2019 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import os, strutils, unittest,
      ../metrics

declareCounter globalCounter, "help"
declarePublicCounter globalPublicCounter, "help"
declareGauge globalGauge, "help"
declarePublicGauge globalPublicGauge, "help"

proc gcSafetyTest* {.gcsafe.} = # The test is succesful if this proc compiles
  globalCounter.inc 2
  globalPublicCounter.inc(2)
  globalGauge.set 10.0
  globalGauge.inc
  globalGauge.dec
  globalPublicGauge.set(1)

suite "counter":
  setup:
    var registry = newRegistry()
    declareCounter counter, "help", registry = registry

  test "increment":
    check(counter.value == 0)
    counter.inc()
    check(counter.value == 1)
    counter.inc(7)
    check(counter.value == 8)
    counter.inc(0.5)
    check(counter.value == 8.5)
    expect ValueError:
      counter.inc(-1)

  test "exceptions":
    proc f(switch: bool) =
      if switch:
        raise newException(ValueError, "exc1")
      else:
        raise newException(IndexError, "exc2")

    expect IndexError:
      counter.countExceptions(ValueError):
        f(false)
    check(counter.value == 0)

    expect ValueError:
      counter.countExceptions(ValueError):
        f(true)
    check(counter.value == 1)

    expect IndexError:
      counter.countExceptions:
        f(false)
    check(counter.value == 2)

    counter.countExceptions:
      discard
    check(counter.value == 2)
    # echo counter.toTextLines().join("\n")

  test "labels":
    declareCounter lcounter, "l help", @["foo", "bar"], registry
    expect KeyError:
      discard lcounter.value

    # you can't access a labelled value before it was initialised
    expect KeyError:
      discard lcounter.value(@["a", "x"])

    let labelValues = @["a", "x \"y\" \n\\z"]
    lcounter.inc(labelValues = labelValues)
    check(lcounter.value(labelValues) == 1)
    # echo registry.toText()

suite "gauge":
  setup:
    var registry = newRegistry()
    declareGauge gauge, "help", registry = registry

  test "basic":
    check(gauge.value == 0)
    gauge.inc()
    check(gauge.value == 1)
    gauge.dec(3)
    check(gauge.value == -2.0) # weird Nim bug if it's "-2"
    gauge.dec(0.1)
    check(gauge.value == -2.1)
    gauge.set(9.5)
    check(gauge.value == 9.5)
    gauge.set(1)
    check(gauge.value == 1)

  test "in progress":
    gauge.trackInProgress:
      check(gauge.value == 1)
    check(gauge.value == 0)

    declareGauge lgauge, "help", @["foobar"], registry = registry
    let labelValues = @["b"]
    lgauge.trackInProgress(labelValues):
      check(lgauge.value(labelValues) == 1)
    check(lgauge.value(labelValues) == 0)
    # echo registry.toText()

  test "timing":
    gauge.time:
      sleep(1000)
      check(gauge.value == 0)
    check(gauge.value == 1)
    # echo registry.toText()

  test "timing with labels":
    declareGauge lgauge, "help", @["foobar"], registry = registry
    let labelValues = @["b"]
    lgauge.time(labelValues):
      sleep(1000)
    check(lgauge.value(labelValues) == 1)

