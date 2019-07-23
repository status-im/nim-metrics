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
    declareCounter myCounter, "help", registry = registry

  test "basic":
    check(myCounter.value == 0)
    myCounter.inc()
    check(myCounter.value == 1)
    myCounter.inc(7)
    check(myCounter.value == 8)
    myCounter.inc(0.5)
    check(myCounter.value == 8.5)
    expect ValueError:
      myCounter.inc(-1)
    # name validation (have to use the internal API to get past Nim's identifier validation)
    when defined(metrics):
      expect ValueError:
        var tmp = newCounter("1337", "invalid name")

  test "alternative API":
    counter("one_off_counter").inc()
    check(counter("one_off_counter").value == 1)
    counter("one_off_counter").inc(0.5)
    check(counter("one_off_counter").value == 1.5)
    # confusing, but allowed
    check gauge("one_off_counter").value == 0

  test "exceptions":
    proc f(switch: bool) =
      if switch:
        raise newException(ValueError, "exc1")
      else:
        raise newException(IndexError, "exc2")

    expect IndexError:
      myCounter.countExceptions(ValueError):
        f(false)
    check(myCounter.value == 0)

    expect ValueError:
      myCounter.countExceptions(ValueError):
        f(true)
    check(myCounter.value == 1)

    expect IndexError:
      myCounter.countExceptions:
        f(false)
    check(myCounter.value == 2)

    myCounter.countExceptions:
      discard
    check(myCounter.value == 2)
    # echo myCounter.toTextLines().join("\n")

  test "labels":
    declareCounter lCounter, "l help", @["foo", "bar"], registry
    expect KeyError:
      discard lCounter.value

    # you can't access a labelled value before it was initialised
    expect KeyError:
      discard lCounter.value(@["a", "x"])

    let labelValues = @["a", "x \"y\" \n\\z"]
    lCounter.inc(labelValues = labelValues)
    check(lCounter.value(labelValues) == 1)
    # echo registry.toText()

    # label validation
    expect ValueError:
      declareCounter invalid1, "invalid", @["123", "foo"]
    expect ValueError:
      declareCounter invalid2, "invalid", @["foo", "123"]
    expect ValueError:
      declareCounter invalid3, "invalid", @["foo", "__bar"]

    # label names: array instead of sequence
    declareCounter lCounter2, "l2 help", ["foo", "bar"], registry
    let labelValues2 = ["a", "x \"y\" \n\\z"]
    lCounter2.inc(labelValues = labelValues2)
    check(lCounter2.value(labelValues2) == 1)

suite "gauge":
  setup:
    var registry = newRegistry()
    declareGauge myGauge, "help", registry = registry

  test "basic":
    check(myGauge.value == 0)
    myGauge.inc()
    check(myGauge.value == 1)
    myGauge.dec(3)
    check(myGauge.value == -2.0) # weird Nim bug if it's "-2"
    myGauge.dec(0.1)
    check(myGauge.value == -2.1)
    myGauge.set(9.5)
    check(myGauge.value == 9.5)
    myGauge.set(1)
    check(myGauge.value == 1)

  test "alternative API":
    gauge("one_off_gauge").set(1)
    check(gauge("one_off_gauge").value == 1)
    gauge("one_off_gauge").inc(0.5)
    check(gauge("one_off_gauge").value == 1.5)

  test "in progress":
    myGauge.trackInProgress:
      check(myGauge.value == 1)
    check(myGauge.value == 0)

    declareGauge lgauge, "help", @["foobar"], registry = registry
    let labelValues = @["b"]
    lgauge.trackInProgress(labelValues):
      check(lgauge.value(labelValues) == 1)
    check(lgauge.value(labelValues) == 0)
    # echo registry.toText()

  test "timing":
    myGauge.time:
      sleep(1000)
      check(myGauge.value == 0)
    check(myGauge.value >= 1) # may be 2 inside a macOS Travis job
    # echo registry.toText()

  test "timing with labels":
    declareGauge lgauge, "help", @["foobar"], registry = registry
    let labelValues = @["b"]
    lgauge.time(labelValues):
      sleep(1000)
    check(lgauge.value(labelValues) >= 1)

