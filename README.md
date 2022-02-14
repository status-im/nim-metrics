# nim-metrics

[![CI](https://github.com/status-im/nim-metrics/actions/workflows/ci.yml/badge.svg)](https://github.com/status-im/nim-metrics/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![License: Apache](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)

## Introduction

Nim metrics client library supporting the [Prometheus](https://prometheus.io/)
monitoring toolkit, [StatsD](https://github.com/statsd/statsd/wiki) and
[Carbon](https://graphite.readthedocs.io/en/latest/feeding-carbon.html).
Designed to be thread-safe and efficient, it's disabled by default so libraries
can use it without any overhead for those library users not interested in
metrics.

## Installation

You can install the development version of the library through Nimble with the
following command:
```
nimble install https://github.com/status-im/nim-metrics@#master
```

## Usage

To enable metrics, compile your code with `-d:metrics --threads:on`.

To avoid depending on PCRE, compile with `-d:withoutPCRE`.

## Architectural overview

`Collector` objects holding various `Metric` objects are registered in one or
more `Registry` objects. There is a default registry being used for the most
common case.

Metric values are `float64`, but the API also accepts `int64` parameters which
are then cast to `float64`.

By starting an HTTP server, custom metrics (and some default ones) can be
pulled by Prometheus. By specifying backends, those same custom metrics will be
pushed to StatsD or Carbon servers, as soon as they are modified. They can also
be serialised to strings for some quick and dirty logging. Integration with the
[Chronicles](https://github.com/status-im/nim-chronicles) logging library is
available in a separate module.

That HTTP server used for pulling is running in its own thread. Metric pushing
also uses a dedicated thread for networking, in order to minimise the overhead.

## Collector types

### Counter

A counter's value can only be incremented.

```nim
# Declare a variable `myCounter` holding a `Counter` object with a `Metric`
# having the same name as the variable. The help string is mandatory. The initial
# value is 0 and it's automatically added to `defaultRegistry`.
declareCounter myCounter, "an example counter"

# increment it by 1
myCounter.inc()

# increment it by 10
myCounter.inc(10)

# count all exceptions in a block
someCounter.countExceptions:
  foo()

# or just an exception type
otherCounter.countExceptions(ValueError):
  bar()

# do you need a variable that's being exported from the module?
declarePublicCounter seenPeers, "number of seen peers"
# it's the equivalent of `var seenPeers* = ...`

# want to avoid declaring a variable, giving it a help string, or anything else for that matter?
counter("one_off_counter").inc()
# What this does is generate a {.global.} var, so as long as you use the same
# string, you're using the same counter. Using strings instead of identifiers
# skips any compiler protection in case of typos, so this API is not recommended
# for serious use.
```

### Gauge

Gauges can be incremented, decremented or set to a given value.

```nim
declareGauge myGauge, "an example gauge" # or `declarePublicGauge` to export it
myGauge.inc(4.5)
myGauge.dec(2)
myGauge.set(10)

myGauge.setToCurrentTime() # Unix timestamp in seconds

myGauge.trackInProgress:
  # myGauge is incremented at the start of the block (a `myGauge.inc()` is being inserted here)
  foo()
  # and decremented at the end (`myGauge.dec()`)

# set the gauge to the runtime of a block, in seconds
myGauge.time:
  bar()

# alternative, unrecommended API
gauge("one_off_gauge").set(42)
```

### Summary

Summaries sample observations and provide a total count and the sum of all observed values.

```nim
declareSummary mySummary, "an example summary" # or `declarePublicSummary` to export it
mySummary.observe(10)
mySummary.observe(0.5)
echo mySummary
```

This will print out:

```text
# HELP mySummary an example summary
# TYPE mySummary summary
mySummary_sum 10.5 1569332171696
mySummary_count 2.0 1569332171696
mySummary_created 1569332171.0
```

```nim
# observe the execution duration of a block, in seconds
mySummary.time:
  foo()

# alternative, unrecommended API
summary("one_off_summary").observe(10)
```

### Histogram

These cumulative histograms store the count and total sum of observed values,
just like summaries. Further more, they place the observed values in
configurable buckets and provide per-bucket counts.

Note that an observed value will be counted in all buckets that have a size greater or equal to it.

```nim
declareHistogram myHistogram, "an example histogram" # or `declarePublicHistogram` to export it
# This uses the default bucket sizes: [0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0,
# 2.5, 5.0, 7.5, 10.0, Inf]

# You can customise the buckets:
declareHistogram withCustomBuckets, "custom buckets", buckets = [0.0, 1.0, 2.0]
# if you leave out the "Inf" bucket, it's added for you
withCustomBuckets.observe(0.5)
withCustomBuckets.observe(1)
withCustomBuckets.observe(1.5)
withCustomBuckets.observe(3.7)
echo withCustomBuckets
```

This will print out:

```text
# HELP withCustomBuckets custom buckets
# TYPE withCustomBuckets histogram
withCustomBuckets_sum 6.7 1569334493506
withCustomBuckets_count 4.0 1569334493506
withCustomBuckets_created 1569334493.0
withCustomBuckets_bucket{le="0.0"} 0.0
withCustomBuckets_bucket{le="1.0"} 2.0 1569334493506
withCustomBuckets_bucket{le="2.0"} 3.0 1569334493506
withCustomBuckets_bucket{le="+Inf"} 4.0 1569334493506
```

```nim
# observe the execution duration of a block, in seconds
myHistogram.time:
  foo()

# alternative, unrecommended API
histogram("one_off_histogram").observe(10)
```

## Labels

Metric labels are supported for the Prometheus backend, as a way to add extra
dimensions corresponding to each combination of metric name and label values.
This can quickly get out of hand, as you can guess, so don't go overboard with
this feature. (See also the [relevant warnings in Prometheus' docs](https://prometheus.io/docs/practices/instrumentation/#do-not-overuse-labels).)

You declare label names when defining the collector and label values each time
you update it:

```nim
declareCounter lCounter, "example counter with labels", ["foo", "bar"]
lCounter.inc(labelValues = ["1", "a"]) # the label values must be strings
lCounter.inc(labelValues = ["2", "b"])
# How many metrics are now in this collector? Two, because we used two sets of label values:
echo lCounter
```

```text
# HELP lCounter example counter with labels
# TYPE lCounter counter
lCounter_total{foo="1",bar="a"} 1.0 1569340503703
lCounter_created{foo="1",bar="a"} 1569340503.0
lCounter_total{foo="2",bar="b"} 1.0 1569340503703
lCounter_created{foo="2",bar="b"} 1569340503.0
```

(OK, there are four metrics in total, because each one gets a `*_created` buddy.)

So if you must use labels, make sure there's a finite and small number of
possible label values being set.

## Metric name and label name validation

We use Prometheus standards for that, so metric names must comply with the
`^[a-zA-Z_:][a-zA-Z0-9_:]*$` regex while label names have to comply with
`^[a-zA-Z_][a-zA-Z0-9_]*$`.

In the examples you've seen so far, all collectors declared with
`declare<CollectorType>` had more stringent naming rules, since their names were
also identifiers for Nim variables - which can't have colons in them.

To overcome this, without relying on the discouraged alternative API, use the `name` parameter:

```nim
declareCounter cCounter, "counter with colons in name", name = "foo:bar:baz"
cCounter.inc()
echo cCounter
```

```text
# HELP foo:bar:baz counter with colons in name
# TYPE foo:bar:baz counter
foo:bar:baz_total 1.0 1569341756504
foo:bar:baz_created 1569341756.0
```

## Logging

Metrics are not logs, but you might want to log them nonetheless. The `$`
procedure is defined for collectors and registries, so you can just use the
built-in string serialisation to print them:

```nim
echo myCounter, myGauge
echo defaultRegistry
```

Integration with [Chronicles](https://github.com/status-im/nim-chronicles) is available in a separate module:

```nim
import chronicles, metrics, metrics/chronicles_support

# ...

info "myCounter", myCounter
debug "default registry", defaultRegistry
```

## Testing

When testing, you might want to isolate some collectors by registering them
into a custom registry:

```nim
var myRegistry = newRegistry()
declareCounter myCounter, "help", registry = myRegistry
echo myRegistry

# this means that `myCounter` is no longer registered in `defaultRegistry`
echo defaultRegistry
```

These unoptimised (read "very inefficient") `value()` and `valueByName()`
procedures for accessing metric values should only be used inside test suites:

```nim
suite "counter":
  test "basic":
    declareCounter myCounter, "help"
    check myCounter.value == 0
    myCounter.inc()
    check myCounter.value == 1

    declareSummary cSummary, "summary with colons in name", name = "foo:bar:baz"
    cSummary.observe(10)
    check cSummary.valueByName("foo:bar:baz_count") == 1
    check cSummary.valueByName("foo:bar:baz_sum") == 10
```

## Prometheus endpoint

First, you need to choose the HTTP server implementation.

### Standard library

Using [asynchttpserver](https://nim-lang.org/docs/asynchttpserver.html) which is based on [asyncdispatch](https://nim-lang.org/docs/asyncdispatch.html) from the Nim standard library:

```nim
import metrics, metrics/stdlib_httpserver
```

### Chronos

Using [Chronos](https://github.com/status-im/nim-chronos/) - an asyncdispatch alternative:

```nim
import metrics, metrics/chronos_httpserver
```

### Starting the HTTP server

Start an HTTP server listening on `127.0.0.1:8000` from which the Prometheus
daemon can pull the metrics from all collectors in `defaultRegistry` (plus the
default metrics):

```nim
startMetricsHttpServer()
```

Or set your own address and port to listen to:

```nim
import net

startMetricsHttpServer("127.0.0.1", Port(8000))
```

The HTTP server will run in its own thread. It will expose two endpoints:

* http://127.0.0.1:8000/metrics - Returns the metrics consumed by Prometheus.
* http://127.0.0.1:8000/health - Healthcheck that returns `OK` string and 200 code.

### System metrics

Default metrics available (see also [the relevant Prometheus docs](https://prometheus.io/docs/instrumenting/writing_clientlibs/#standard-and-runtime-collectors)):

```text
process_cpu_seconds_total
process_open_fds
process_max_fds
process_virtual_memory_bytes
process_resident_memory_bytes
process_start_time_seconds
nim_gc_mem_bytes[thread_id]
nim_gc_mem_occupied_bytes[thread_id]
nim_gc_heap_instance_occupied_bytes[type_name]
nim_gc_heap_instance_occupied_summed_bytes
```

The `process_*` metrics are only available on Linux, for now.

`nim_gc_heap_instance_occupied_bytes` is only available when compiling with
`-d:nimTypeNames` and holds the top 10 instance types, in reverse order of
their total heap usage (from all threads), at the time the metric is created.
Since this set changes with time, you'll see more than 10 types in Grafana.

The thread-specific metrics are being updated automatically when a user-defined metric
is changed in the main thread, but only if a minimal interval has passed since
the last update (defaults to 10 second). All other system metrics are custom
collectors which are updated at collection time.

```nim
import times
when defined(metrics):
  # get the default minimal update interval
  echo getSystemMetricsUpdateInterval()
  # you can change it
  setSystemMetricsUpdateInterval(initDuration(seconds = 2))
```

You can also disable this automated piggy-backing on user-defined metric value
changes, if you need more regularity, and take charge of updating system
metrics yourself.

```nim
# disable automatic updates
setSystemMetricsAutomaticUpdate(false)
# somewhere in your event loop, at an interval of your choice
updateThreadMetrics()
```

Those metrics with with a "thread\_id" label are thread-specific metrics. The
automatic update only covers thread metrics for the main thread. You'll have to
call `updateThreadMetrics()` by yourself for any other thread you care about.

Screenshot of [Grafana showing data from Prometheus that pulls it from Nimbus which uses nim-metrics](https://github.com/status-im/nimbus-eth1/#metric-visualisation):

![Grafana screenshot](https://i.imgur.com/AdtavDA.png)

## StatsD

Add a [StatsD](https://github.com/statsd/statsd/wiki) export backend where
metric updates will be pushed as soon as they are created:

```nim
import metrics, net

when defined(metrics):
  addExportBackend(
    metricProtocol = STATSD,
    netProtocol = UDP,
    address = "127.0.0.1",
    port = Port(8125)
  )

declareCounter myCounter, "some counter"
myCounter.inc()

# When we incremented the counter, the corresponding data was sent over the wire to the StatsD daemon.
```

The only supported collector types are counters and gauges. There's a dedicated
thread that does the networking part. When you update these collectors, data is
sent over a channel to that thread. If the channel's buffer is full, the data
is silently dropped. Same for an unreachable backend or any other networking
error. Reconnections are tried automatically and there's one socket per backend
being reused.

All the complexity is hidden from the API user and additional latency is kept
to a minimum. Exported metrics are treated like disposable data and dropped at
the first sign of trouble.

Counters support an additional parameter just for StatsD: `sampleRate`. This
allows sending just a percentage of the increments to the StatsD daemon.
Nothing else changes on the client side.

```nim
declareCounter sCounter, "counter with a sample rate set", sampleRate = 0.1
sCounter.inc()

# Now only 10% (on average) of this counter's updates will be sent over the
# wire. We throw a dice when the time comes, using a simple PRNG. We also
# inform the StatsD daemon about this rate, so it can adjust its estimated value
# accordingly.
```

## Carbon

Add a [Carbon](https://graphite.readthedocs.io/en/latest/feeding-carbon.html)
export backend where metric updates will be pushed as soon as they are created:

```nim
import metrics, net

when defined(metrics):
  addExportBackend(
    metricProtocol = CARBON,
    netProtocol = TCP,
    address = "127.0.0.1",
    port = Port(2003)
  )
```

The implementation is very similar to the StatsD metric exporting described above.

You may add as many export backends as you want, but deleting them from the
`exportBackends` global variable is unsupported.

## Contributing

When submitting pull requests, please add test cases for any new features or
fixes and make sure `nimble test` is still able to execute the entire test
suite successfully.

## License

Licensed and distributed under either of

* MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT
* Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)

at your option. These files may not be copied, modified, or distributed except according to those terms.

