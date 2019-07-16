# Copyright (c) 2019 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import hashes, locks, sequtils, sets, strutils, tables, times

type
  Labels* = seq[string]

  Metric* = ref object of RootObj
    name*: string
    value*: float64
    timestamp*: int64 # UTC, in ms
    labels*: Labels
    labelValues*: Labels

  Metrics* = OrderedTable[Labels, seq[Metric]]

  Collector* = ref object of RootObj
    name*: string
    help*: string
    typ*: string
    labels*: Labels
    metrics*: Metrics

  IgnoredCollector* = object

  Counter* = ref object of Collector
  Gauge* = ref object of Collector

  Registry* = ref object of RootObj
    lock*: Lock
    collectors*: OrderedSet[Collector]

  RegistrationError* = object of Exception

const CONTENT_TYPE* = "text/plain; version=0.0.4; charset=utf-8"

#########
# utils #
#########

when defined(metrics):
  proc toMilliseconds*(time: Time): int64 =
    return convert(Seconds, Milliseconds, time.toUnix()) + convert(Nanoseconds, Milliseconds, time.nanosecond())

  proc atomicAdd*(dest: ptr float64, amount: float64) =
    var oldVal, newVal: float64

    # we need two atomic operations for floats, so do the CAS in a loop until we're
    # sure we're incrementing the latest value
    while true:
      atomicLoad(cast[ptr int64](dest), cast[ptr int64](oldVal.addr), ATOMIC_SEQ_CST)
      newVal = oldVal + amount
      if atomicCompareExchange(cast[ptr int64](dest), cast[ptr int64](oldVal.addr), cast[ptr int64](newVal.addr), false, ATOMIC_SEQ_CST, ATOMIC_SEQ_CST):
        break

  template processHelp*(help: string): string =
    help.multireplace([("\\", "\\\\"), ("\n", "\\n")])

  template processLabelValue*(labelValue: string): string =
    labelValue.multireplace([("\\", "\\\\"), ("\n", "\\n"), ("\"", "\\\"")])

  proc toText*(metric: Metric, showTimestamp = true): string =
    result = metric.name
    if metric.labels.len > 0:
      result.add('{')
      var textLabels: seq[string] = @[]
      for i in 0..metric.labels.high:
        textLabels.add("$#=\"$#\"" % [metric.labels[i], metric.labelValues[i].processLabelValue()])
      result.add(textLabels.join(","))
      result.add('}')
    result.add(" " & $metric.value)
    if showTimestamp and metric.timestamp > 0:
      result.add(" " & $metric.timestamp)

######################
# generic collectors #
######################

when defined(metrics):
  template getEmptyLabelValues*(collector: Collector): Labels =
    sequtils.repeat("", len(collector.labels))

  proc validateLabelValues*(collector: Collector, labelValues: Labels): Labels =
    if labelValues == @[]:
      result = collector.getEmptyLabelValues()
    elif len(labelValues) != len(collector.labels):
      raise newException(ValueError, "number of label values doesn't match number of labels")
    else:
      result = labelValues

  method hash*(collector: Collector): Hash {.base.} =
    result = result !& collector.name.hash
    for label in collector.labels:
      result = result !& label.hash
    result = !$result

  method collect*(collector: Collector): Metrics {.base.} =
    return collector.metrics

  proc toTextLines*(collector: Collector, metricsTable: Metrics): seq[string] =
    result = @[
      "# HELP $# $#" % [collector.name, collector.help.processHelp()],
      "# TYPE $# $#" % [collector.name, collector.typ],
    ]
    for labelValues, metrics in metricsTable:
      for metric in metrics:
        result.add(metric.toText())

template value*(collector: Collector | type IgnoredCollector, labelValues: Labels = @[]): float64 =
  when defined(metrics) and collector is not IgnoredCollector:
    collector.metrics[labelValues][0].value
  else:
    0.0

############
# registry #
############

proc newRegistry*(): Registry =
  when defined(metrics):
    new(result)
    result.lock.initLock()
    # TODO: remove this set initialisation after porting to Nim-0.20.x
    result.collectors.init()

var defaultRegistry* = newRegistry()

proc register*(collector: Collector, registry = defaultRegistry) =
  when defined(metrics):
    withLock registry.lock:
      if collector in registry.collectors:
        raise newException(RegistrationError, "Collector already registered.")

      registry.collectors.incl(collector)

proc unregister*(collector: Collector, registry = defaultRegistry) =
  when defined(metrics):
    withLock registry.lock:
      if collector notin registry.collectors:
        raise newException(RegistrationError, "Collector not registered.")

      registry.collectors.excl(collector)

proc collect*(registry: Registry): OrderedTable[Collector, Metrics] =
  when defined(metrics):
    result = initOrderedTable[Collector, Metrics]()
    withLock registry.lock:
      for collector in registry.collectors:
        var collectorCopy: Collector
        deepCopy(collectorCopy, collector)
        result[collectorCopy] = collectorCopy.collect()

proc toText*(registry: Registry): string =
  when defined(metrics):
    var res: seq[string] = @[]
    for collector, metricsTable in registry.collect():
      res.add(collector.toTextLines(metricsTable))
      res.add("")
    return res.join("\n")

###########
# counter #
###########

when defined(metrics):
  proc newCounterMetrics(name: string, labels, labelValues: Labels): seq[Metric] =
    result = @[
      Metric(name: name,
            labels: labels,
            labelValues: labelValues),
      Metric(name: name & "_created",
            labels: labels,
            labelValues: labelValues,
            value: getTime().toMilliseconds().float64),
    ]

  proc validateCounterLabelValues(counter: Counter, labelValues: Labels): Labels =
    result = validateLabelValues(counter, labelValues)
    if result notin counter.metrics:
      counter.metrics[result] = newCounterMetrics(counter.name, counter.labels, result)

  # don't document this one, even if we're forced to make it public, because it
  # won't work when all (or some) collectors are disabled
  proc newCounter*(name: string, help: string, labels: Labels = @[], registry = defaultRegistry): Counter =
    result = Counter(name: name,
                    help: help,
                    typ: "counter",
                    labels: labels,
                    metrics: initOrderedTable[Labels, seq[Metric]]())
    if labels.len == 0:
      result.metrics[labels] = newCounterMetrics(name, labels, labels)
    result.register(registry)

template declareCounter*(identifier: untyped,
                        help: static string,
                        labels: Labels = @[],
                        registry = defaultRegistry) {.dirty.} =
  # fine-grained collector disabling will go in here, turning disabled
  # collectors into type aliases for IgnoredCollector
  when defined(metrics):
    var identifier = newCounter(astToStr(identifier), help, labels, registry)
  else:
    type identifier = IgnoredCollector

template declarePublicCounter*(identifier: untyped,
                               help: static string,
                               labels: Labels = @[],
                               registry = defaultRegistry) {.dirty.} =
  when defined(metrics):
    var identifier* = newCounter(astToStr(identifier), help, labels, registry)
  else:
    type identifier* = IgnoredCollector

proc incCounter(counter: Counter, amount: int64|float64 = 1, labelValues: Labels = @[]) =
  when defined(metrics):
    var timestamp = getTime().toMilliseconds()

    if amount < 0:
      raise newException(ValueError, "inc() cannot be used with negative amounts")

    let labelValuesCopy = validateCounterLabelValues(counter, labelValues)

    atomicAdd(counter.metrics[labelValuesCopy][0].value.addr, amount.float64)
    atomicStore(cast[ptr int64](counter.metrics[labelValuesCopy][0].timestamp.addr), timestamp.addr, ATOMIC_SEQ_CST)

template inc*(counter: Counter | type IgnoredCollector, amount: int64|float64 = 1, labelValues: Labels = @[]) =
  when defined(metrics) and counter is not IgnoredCollector:
    {.gcsafe.}: incCounter(counter, amount, labelValues)

template countExceptions*(counter: Counter | type IgnoredCollector, typ: typedesc, labelValues: Labels, body: untyped) =
  when defined(metrics) and counter is not IgnoredCollector:
    try:
      body
    except typ:
      counter.inc(labelValues = labelValues)
      raise
  else:
    body

template countExceptions*(counter: Counter | type IgnoredCollector, typ: typedesc, body: untyped) =
  when defined(metrics) and counter is not IgnoredCollector:
    let labelValues: Labels = @[]
    counter.countExceptions(typ, labelValues):
      body
  else:
    body

template countExceptions*(counter: Counter | type IgnoredCollector, labelValues: Labels, body: untyped) =
  countExceptions(counter, Exception, labelValues, body)

template countExceptions*(counter: Counter | type IgnoredCollector, body: untyped) =
  when defined(metrics) and counter is not IgnoredCollector:
    let labelValues: Labels = @[]
    counter.countExceptions(labelValues):
      body
  else:
    body

#########
# gauge #
#########

when defined(metrics):
  proc newGaugeMetrics(name: string, labels, labelValues: Labels): seq[Metric] =
    result = @[
      Metric(name: name,
            labels: labels,
            labelValues: labelValues),
    ]

  proc validateGaugeLabelValues(gauge: Gauge, labelValues: Labels): Labels =
    result = validateLabelValues(gauge, labelValues)
    if result notin gauge.metrics:
      gauge.metrics[result] = newGaugeMetrics(gauge.name, gauge.labels, result)

  proc newGauge*(name: string, help: string, labels: Labels = @[], registry = defaultRegistry): Gauge =
    result = Gauge(name: name,
                  help: help,
                  typ: "gauge",
                  labels: labels,
                  metrics: initOrderedTable[Labels, seq[Metric]]())
    if labels.len == 0:
      result.metrics[labels] = newGaugeMetrics(name, labels, labels)
    result.register(registry)

template declareGauge*(identifier: untyped,
                      help: static string,
                      labels: Labels = @[],
                      registry = defaultRegistry) {.dirty.} =
  when defined(metrics):
    var identifier = newGauge(astToStr(identifier), help, labels, registry)
  else:
    type identifier = IgnoredCollector

template declarePublicGauge*(identifier: untyped,
                            help: static string,
                            labels: Labels = @[],
                            registry = defaultRegistry) {.dirty.} =
  when defined(metrics):
    var identifier* = newGauge(astToStr(identifier), help, labels, registry)
  else:
    type identifier* = IgnoredCollector

proc incGauge(gauge: Gauge, amount: int64|float64 = 1, labelValues: Labels = @[]) =
  when defined(metrics):
    var timestamp = getTime().toMilliseconds()

    let labelValuesCopy = validateGaugeLabelValues(gauge, labelValues)

    atomicAdd(gauge.metrics[labelValuesCopy][0].value.addr, amount.float64)
    atomicStore(cast[ptr int64](gauge.metrics[labelValuesCopy][0].timestamp.addr), timestamp.addr, ATOMIC_SEQ_CST)

proc decGauge(gauge: Gauge, amount: int64|float64 = 1, labelValues: Labels = @[]) =
  when defined(metrics):
    gauge.inc((-amount).float64, labelValues)

proc setGauge(gauge: Gauge, value: int64|float64, labelValues: Labels = @[]) =
  when defined(metrics):
    var timestamp = getTime().toMilliseconds()

    let labelValuesCopy = validateGaugeLabelValues(gauge, labelValues)

    atomicStoreN(cast[ptr int64](gauge.metrics[labelValuesCopy][0].value.addr), cast[int64](value.float64), ATOMIC_SEQ_CST)
    atomicStore(cast[ptr int64](gauge.metrics[labelValuesCopy][0].timestamp.addr), timestamp.addr, ATOMIC_SEQ_CST)

template inc*(gauge: Gauge, amount: int64|float64 = 1, labelValues: Labels = @[]) =
  when defined(metrics):
    {.gcsafe.}: incGauge(gauge, amount, labelValues)

template dec*(gauge: Gauge | type IgnoredCollector, amount: int64|float64 = 1, labelValues: Labels = @[]) =
  when defined(metrics) and gauge is not IgnoredCollector:
    {.gcsafe.}: decGauge(gauge, amount, labelValues)

template set*(gauge: Gauge | type IgnoredCollector, value: int64|float64, labelValues: Labels = @[]) =
  when defined(metrics) and gauge is not IgnoredCollector:
    {.gcsafe.}: setGauge(gauge, value, labelValues)

# in seconds
proc setToCurrentTime*(gauge: Gauge | type IgnoredCollector, labelValues: Labels = @[]) =
  when defined(metrics) and gauge is not IgnoredCollector:
    gauge.set(getTime().toUnix(), labelValues)

template trackInProgress*(gauge: Gauge | type IgnoredCollector, labelValues: Labels, body: untyped) =
  when defined(metrics) and gauge is not IgnoredCollector:
    gauge.inc(labelValues = labelValues)
    body
    gauge.dec(labelValues = labelValues)
  else:
    body

template trackInProgress*(gauge: Gauge | type IgnoredCollector, body: untyped) =
  when defined(metrics) and gauge is not IgnoredCollector:
    let labelValues: Labels = @[]
    gauge.trackInProgress(labelValues):
      body
  else:
    body

# in seconds
template time*(gauge: Gauge | type IgnoredCollector, labelValues: Labels, body: untyped) =
  when defined(metrics) and gauge is not IgnoredCollector:
    let start = times.toUnix(getTime())
    body
    gauge.set(times.toUnix(getTime()) - start, labelValues = labelValues)
  else:
    body

template time*(gauge: Gauge | type IgnoredCollector, body: untyped) =
  when defined(metrics) and gauge is not IgnoredCollector:
    let labelValues: Labels = @[]
    gauge.time(labelValues):
      body
  else:
    body

###############
# HTTP server #
###############

import asynchttpserver, asyncdispatch

type HttpServerArgs = tuple[address: string, port: Port]
var httpServerThread: Thread[HttpServerArgs]

proc httpServer(args: HttpServerArgs) {.thread.} =
  let (address, port) = args
  var server = newAsyncHttpServer()

  proc cb(req: Request) {.async.} =
    if req.url.path == "/metrics":
      {.gcsafe.}:
        await req.respond(Http200, defaultRegistry.toText(), newHttpHeaders([("Content-Type", CONTENT_TYPE)]))
    else:
      await req.respond(Http404, "Try /metrics")

  waitFor server.serve(port, cb, address)

proc startHttpServer*(address = "127.0.0.1", port = Port(9093)) =
  when defined(metrics):
    httpServerThread.createThread(httpServer, (address, port))

