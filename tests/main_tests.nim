# nim-metrics
# Copyright (c) 2019 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import net, os, strutils, unittest,
      ../metrics

metricExports.add(MetricExportType(
  metricProtocol: STATSD,
  netProtocol: UDP,
  address: "127.0.0.1",
  port: Port(8125)
))
metricExports.add(MetricExportType(
  metricProtocol: CARBON,
  netProtocol: TCP,
  address: "127.0.0.1",
  port: Port(2003)
))

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
    check myCounter.value == 0
    myCounter.inc()
    check myCounter.value == 1
    myCounter.inc(7)
    check myCounter.value == 8
    myCounter.inc(0.5)
    check myCounter.value == 8.5
    expect ValueError:
      myCounter.inc(-1)
    # name validation (have to use the internal API to get past Nim's identifier validation)
    when defined(metrics):
      expect ValueError:
        var tmp = newCounter("1337", "invalid name")

  test "alternative API":
    counter("one_off_counter").inc()
    check counter("one_off_counter").value == 1
    counter("one_off_counter").inc(0.5)
    check counter("one_off_counter").value == 1.5
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
    check myCounter.value == 0

    expect ValueError:
      myCounter.countExceptions(ValueError):
        f(true)
    check myCounter.value == 1

    expect IndexError:
      myCounter.countExceptions:
        f(false)
    check myCounter.value == 2

    myCounter.countExceptions:
      discard
    check myCounter.value == 2
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
    check lCounter.value(labelValues) == 1
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
    check lCounter2.value(labelValues2) == 1

suite "gauge":
  setup:
    var registry = newRegistry()
    declareGauge myGauge, "help", registry = registry

  test "basic":
    check myGauge.value == 0
    myGauge.inc()
    check myGauge.value == 1
    myGauge.dec(3)
    check myGauge.value == -2.0 # weird Nim bug if it's "-2"
    myGauge.dec(0.1)
    check myGauge.value == -2.1
    myGauge.set(9.5)
    check myGauge.value == 9.5
    myGauge.set(1)
    check myGauge.value == 1

  test "alternative API":
    gauge("one_off_gauge").set(1)
    check gauge("one_off_gauge").value == 1
    gauge("one_off_gauge").inc(0.5)
    check gauge("one_off_gauge").value == 1.5

  test "in progress":
    myGauge.trackInProgress:
      check myGauge.value == 1
    check myGauge.value == 0

    declareGauge lgauge, "help", @["foobar"], registry = registry
    let labelValues = @["b"]
    lgauge.trackInProgress(labelValues):
      check lgauge.value(labelValues) == 1
    check lgauge.value(labelValues) == 0
    # echo registry.toText()

  test "timing":
    myGauge.time:
      sleep(1000)
      check myGauge.value == 0
    check myGauge.value >= 1 # may be 2 inside a macOS Travis job
    # echo registry.toText()

  test "timing with labels":
    declareGauge lgauge, "help", @["foobar"], registry = registry
    let labelValues = @["b"]
    lgauge.time(labelValues):
      sleep(1000)
    check lgauge.value(labelValues) >= 1

suite "summary":
  setup:
    var registry = newRegistry()
    declareSummary mySummary, "help", registry = registry

  test "basic":
    check mySummary.valueByName("mySummary_count") == 0
    check mySummary.valueByName("mySummary_sum") == 0
    mySummary.observe(10)
    check mySummary.valueByName("mySummary_count") == 1
    check mySummary.valueByName("mySummary_sum") == 10
    mySummary.observe(0.5)
    check mySummary.valueByName("mySummary_count") == 2
    check mySummary.valueByName("mySummary_sum") == 10.5

  test "alternative API":
    summary("one_off_summary").observe(10)
    check summary("one_off_summary").valueByName("one_off_summary_count") == 1
    check summary("one_off_summary").valueByName("one_off_summary_sum") == 10

  test "timing":
    mySummary.time:
      sleep(1000)
      check mySummary.valueByName("mySummary_sum") == 0
    check mySummary.valueByName("mySummary_sum") >= 1

  test "timing with labels":
    declareSummary lsummary, "help", ["foobar"], registry = registry
    let labelValues = ["b"]
    lsummary.time(labelValues):
      sleep(1000)
    check lsummary.valueByName("lsummary_sum", labelValues) >= 1

suite "histogram":
  setup:
    var registry = newRegistry()
    declareHistogram myHistogram, "help", registry = registry

  test "basic":
    check myHistogram.valueByName("myHistogram_bucket", [], ["1.0"]) == 0
    check myHistogram.valueByName("myHistogram_bucket", [], ["2.5"]) == 0
    check myHistogram.valueByName("myHistogram_bucket", [], ["5.0"]) == 0
    check myHistogram.valueByName("myHistogram_bucket", [], ["+Inf"]) == 0
    check myHistogram.valueByName("myHistogram_count") == 0
    check myHistogram.valueByName("myHistogram_sum") == 0

    myHistogram.observe(2)
    check myHistogram.valueByName("myHistogram_bucket", [], ["1.0"]) == 0
    check myHistogram.valueByName("myHistogram_bucket", [], ["2.5"]) == 1
    check myHistogram.valueByName("myHistogram_bucket", [], ["5.0"]) == 1
    check myHistogram.valueByName("myHistogram_bucket", [], ["+Inf"]) == 1
    check myHistogram.valueByName("myHistogram_count") == 1
    check myHistogram.valueByName("myHistogram_sum") == 2

    myHistogram.observe(2.5)
    check myHistogram.valueByName("myHistogram_bucket", [], ["1.0"]) == 0
    check myHistogram.valueByName("myHistogram_bucket", [], ["2.5"]) == 2
    check myHistogram.valueByName("myHistogram_bucket", [], ["5.0"]) == 2
    check myHistogram.valueByName("myHistogram_bucket", [], ["+Inf"]) == 2
    check myHistogram.valueByName("myHistogram_count") == 2
    check myHistogram.valueByName("myHistogram_sum") == 4.5

    myHistogram.observe(Inf)
    check myHistogram.valueByName("myHistogram_bucket", [], ["1.0"]) == 0
    check myHistogram.valueByName("myHistogram_bucket", [], ["2.5"]) == 2
    check myHistogram.valueByName("myHistogram_bucket", [], ["5.0"]) == 2
    check myHistogram.valueByName("myHistogram_bucket", [], ["+Inf"]) == 3
    check myHistogram.valueByName("myHistogram_count") == 3
    check myHistogram.valueByName("myHistogram_sum") == Inf

    declareHistogram h1, "help", registry = registry, buckets = [0.0, 1.0, 2.0]
    check h1.valueByName("h1_bucket", [], ["0.0"]) == 0
    check h1.valueByName("h1_bucket", [], ["1.0"]) == 0
    check h1.valueByName("h1_bucket", [], ["2.0"]) == 0
    check h1.valueByName("h1_bucket", [], ["+Inf"]) == 0

    declareHistogram h2, "help", registry = registry, buckets = [0.0, 1.0, 2.0, Inf]
    check h2.valueByName("h2_bucket", [], ["0.0"]) == 0
    check h2.valueByName("h2_bucket", [], ["1.0"]) == 0
    check h2.valueByName("h2_bucket", [], ["2.0"]) == 0
    check h2.valueByName("h2_bucket", [], ["+Inf"]) == 0

    expect ValueError:
      declareHistogram h3, "help", registry = registry, buckets = []
    expect ValueError:
      declareHistogram h3, "help", registry = registry, buckets = [Inf]
    expect ValueError:
      declareHistogram h3, "help", registry = registry, buckets = [3.0, 1.0]

  test "alternative API":
    histogram("one_off_histogram").observe(2)
    check histogram("one_off_histogram").valueByName("one_off_histogram_bucket", [], ["1.0"]) == 0
    check histogram("one_off_histogram").valueByName("one_off_histogram_bucket", [], ["2.5"]) == 1
    check histogram("one_off_histogram").valueByName("one_off_histogram_bucket", [], ["5.0"]) == 1
    check histogram("one_off_histogram").valueByName("one_off_histogram_bucket", [], ["+Inf"]) == 1
    check histogram("one_off_histogram").valueByName("one_off_histogram_count") == 1
    check histogram("one_off_histogram").valueByName("one_off_histogram_sum") == 2

  test "timing":
    myHistogram.time:
      sleep(1000)
      check myHistogram.valueByName("myHistogram_sum") == 0
    check myHistogram.valueByName("myHistogram_sum") >= 1
    check myHistogram.valueByName("myHistogram_count") == 1
    check myHistogram.valueByName("myHistogram_bucket", [], ["+Inf"]) == 1

  test "timing with labels":
    declareHistogram lhistogram, "help", ["foobar"], registry = registry
    let labelValues = ["b"]
    lhistogram.time(labelValues):
      sleep(1000)
    check lhistogram.valueByName("lhistogram_sum", labelValues) >= 1
    check lhistogram.valueByName("lhistogram_count", labelValues) == 1
    check lhistogram.valueByName("lhistogram_bucket", labelValues, ["+Inf"]) == 1

