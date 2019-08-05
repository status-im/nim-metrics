# Copyright (c) 2019 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import algorithm, hashes, locks, re, sequtils, sets, strutils, tables, times

type
  Labels* = seq[string]
  LabelsParam* = openArray[string]

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
    creationThreadId*: int

  IgnoredCollector* = object

  Counter* = ref object of Collector
  Gauge* = ref object of Collector
  Summary* = ref object of Collector
  Histogram* = ref object of Collector # a cumulative histogram, not a regular one
    buckets*: seq[float64]

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

  proc `$`*(metric: Metric): string =
    metric.toText()

  let
    # these have to be {.global.} for the validation to work with the alternative API
    nameRegexStr {.global.} = r"^[a-zA-Z_:][a-zA-Z0-9_:]*$"
    nameRegex {.global.} = re(nameRegexStr)
    labelRegexStr {.global.} = r"^[a-zA-Z_][a-zA-Z0-9_]*$"
    labelRegex {.global.} = re(labelRegexStr)

  proc validateName(name: string) =
    if not name.contains(nameRegex):
      raise newException(ValueError, "Invalid name: '" & name & "'. It should match the regex: " & nameRegexStr)

  proc validateLabels(labels: LabelsParam, invalidLabelNames: openArray[string] = []) =
    for label in labels:
      if not label.contains(labelRegex):
        raise newException(ValueError, "Invalid label: '" & label & "'. It should match the regex: '" & labelRegexStr & "'.")
      if label.startsWith("__"):
        raise newException(ValueError, "Invalid label: '" & label & "'. It should not start with '__'.")
      if label in invalidLabelNames:
        raise newException(ValueError, "Invalid label: '" & label & "'. It should not be one of: " & $invalidLabelNames & ".")

######################
# generic collectors #
######################

when defined(metrics):
  template getEmptyLabelValues*(collector: Collector): Labels =
    sequtils.repeat("", len(collector.labels))

  proc validateLabelValues*(collector: Collector, labelValues: LabelsParam): Labels =
    if labelValues.len == 0:
      result = collector.getEmptyLabelValues()
    elif labelValues.len != collector.labels.len:
      raise newException(ValueError, "The number of label values doesn't match the number of labels.")
    else:
      result = @labelValues

    # avoid having to change another thread's heap
    if result notin collector.metrics and collector.creationThreadId != getThreadId():
      raise newException(AccessViolationError, "Adding a new combination of label values from another thread than the one in which the collector was created is not allowed.")

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

  proc `$`*(collector: Collector): string =
    collector.toTextLines(collector.metrics).join("\n")

proc `$`*(collector: type IgnoredCollector): string = ""

# for testing
template value*(collector: Collector | type IgnoredCollector, labelValues: LabelsParam = @[]): float64 =
  when defined(metrics) and collector is not IgnoredCollector:
    collector.metrics[@labelValues][0].value
  else:
    0.0

# for testing
proc valueByName*(collector: Collector | type IgnoredCollector,
                  metricName: string,
                  labelValues: LabelsParam = @[],
                  extraLabelValues: LabelsParam = @[]): float64 =
  when defined(metrics) and collector is not IgnoredCollector:
    let allLabelValues = @labelValues & @extraLabelValues
    for metric in collector.metrics[@labelValues]:
      if metric.name == metricName and metric.labelValues == allLabelValues:
        return metric.value
    raise newException(KeyError, "No such metric name for this collector: '" & metricName & "' (label values = " & $allLabelValues & ").")

############
# registry #
############

proc newRegistry*(): Registry =
  when defined(metrics):
    new(result)
    result.lock.initLock()
    # TODO: remove this set initialisation after porting to Nim-0.20.x
    result.collectors.init()

# needs to be {.global.} because of the alternative API's usage of {.global.} collector vars
var defaultRegistry* {.global.} = newRegistry()

proc register*(collector: Collector, registry = defaultRegistry) =
  when defined(metrics):
    withLock registry.lock:
      if collector in registry.collectors:
        raise newException(RegistrationError, "Collector already registered.")

      registry.collectors.incl(collector)

proc unregister*(collector: Collector | type IgnoredCollector, registry = defaultRegistry) =
  when defined(metrics) and collector is not IgnoredCollector:
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
  proc newCounterMetrics(name: string, labels, labelValues: LabelsParam): seq[Metric] =
    result = @[
      Metric(name: name,
            labels: @labels,
            labelValues: @labelValues),
      Metric(name: name & "_created",
            labels: @labels,
            labelValues: @labelValues,
            value: getTime().toMilliseconds().float64),
    ]

  proc validateCounterLabelValues(counter: Counter, labelValues: LabelsParam): Labels =
    result = validateLabelValues(counter, labelValues)
    if result notin counter.metrics:
      counter.metrics[result] = newCounterMetrics(counter.name, counter.labels, result)

  # don't document this one, even if we're forced to make it public, because it
  # won't work when all (or some) collectors are disabled
  proc newCounter*(name: string, help: string, labels: LabelsParam = @[], registry = defaultRegistry): Counter =
    validateName(name)
    validateLabels(labels)
    result = Counter(name: name,
                    help: help,
                    typ: "counter",
                    labels: @labels,
                    metrics: initOrderedTable[Labels, seq[Metric]](),
                    creationThreadId: getThreadId())
    if labels.len == 0:
      result.metrics[@labels] = newCounterMetrics(name, labels, labels)
    result.register(registry)

template declareCounter*(identifier: untyped,
                        help: static string,
                        labels: LabelsParam = @[],
                        registry = defaultRegistry) {.dirty.} =
  # fine-grained collector disabling will go in here, turning disabled
  # collectors into type aliases for IgnoredCollector
  when defined(metrics):
    var identifier = newCounter(astToStr(identifier), help, labels, registry)
  else:
    type identifier = IgnoredCollector

template declarePublicCounter*(identifier: untyped,
                               help: static string,
                               labels: LabelsParam = @[],
                               registry = defaultRegistry) {.dirty.} =
  when defined(metrics):
    var identifier* = newCounter(astToStr(identifier), help, labels, registry)
  else:
    type identifier* = IgnoredCollector

#- alternative API (without support for custom help strings, labels or custom registries)
#- different collector types with the same names are allowed
#- don't mark this proc as {.inline.} because it's incompatible with {.global.}: https://github.com/status-im/nim-metrics/pull/5#discussion_r304687474
when defined(metrics):
  proc counter*(name: static string): Counter =
    # This {.global.} var assignment is lifted from the procedure and placed in a
    # special module init section that's guaranteed to run only once per program.
    # Calls to this proc will just return the globally initialised variable.
    var res {.global.} = newCounter(name, "")
    return res
else:
  template counter*(name: static string): untyped =
    IgnoredCollector

proc incCounter(counter: Counter, amount: int64|float64 = 1, labelValues: LabelsParam = @[]) =
  when defined(metrics):
    var timestamp = getTime().toMilliseconds()

    if amount < 0:
      raise newException(ValueError, "Counter.inc() cannot be used with negative amounts.")

    let labelValuesCopy = validateCounterLabelValues(counter, labelValues)

    atomicAdd(counter.metrics[labelValuesCopy][0].value.addr, amount.float64)
    atomicStore(cast[ptr int64](counter.metrics[labelValuesCopy][0].timestamp.addr), timestamp.addr, ATOMIC_SEQ_CST)

template inc*(counter: Counter | type IgnoredCollector, amount: int64|float64 = 1, labelValues: LabelsParam = @[]) =
  when defined(metrics) and counter is not IgnoredCollector:
    {.gcsafe.}: incCounter(counter, amount, labelValues)

template countExceptions*(counter: Counter | type IgnoredCollector, typ: typedesc, labelValues: LabelsParam, body: untyped) =
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

template countExceptions*(counter: Counter | type IgnoredCollector, labelValues: LabelsParam, body: untyped) =
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
  proc newGaugeMetrics(name: string, labels, labelValues: LabelsParam): seq[Metric] =
    result = @[
      Metric(name: name,
            labels: @labels,
            labelValues: @labelValues),
    ]

  proc validateGaugeLabelValues(gauge: Gauge, labelValues: LabelsParam): Labels =
    result = validateLabelValues(gauge, labelValues)
    if result notin gauge.metrics:
      gauge.metrics[result] = newGaugeMetrics(gauge.name, gauge.labels, result)

  proc newGauge*(name: string, help: string, labels: LabelsParam = @[], registry = defaultRegistry): Gauge =
    validateName(name)
    validateLabels(labels)
    result = Gauge(name: name,
                  help: help,
                  typ: "gauge",
                  labels: @labels,
                  metrics: initOrderedTable[Labels, seq[Metric]](),
                  creationThreadId: getThreadId())
    if labels.len == 0:
      result.metrics[@labels] = newGaugeMetrics(name, labels, labels)
    result.register(registry)

template declareGauge*(identifier: untyped,
                      help: static string,
                      labels: LabelsParam = @[],
                      registry = defaultRegistry) {.dirty.} =
  when defined(metrics):
    var identifier = newGauge(astToStr(identifier), help, labels, registry)
  else:
    type identifier = IgnoredCollector

# alternative API
when defined(metrics):
  proc gauge*(name: static string): Gauge =
    var res {.global.} = newGauge(name, "") # lifted line
    return res
else:
  template gauge*(name: static string): untyped =
    IgnoredCollector

template declarePublicGauge*(identifier: untyped,
                            help: static string,
                            labels: LabelsParam = @[],
                            registry = defaultRegistry) {.dirty.} =
  when defined(metrics):
    var identifier* = newGauge(astToStr(identifier), help, labels, registry)
  else:
    type identifier* = IgnoredCollector

proc incGauge(gauge: Gauge, amount: int64|float64 = 1, labelValues: LabelsParam = @[]) =
  when defined(metrics):
    var timestamp = getTime().toMilliseconds()

    let labelValuesCopy = validateGaugeLabelValues(gauge, labelValues)

    atomicAdd(gauge.metrics[labelValuesCopy][0].value.addr, amount.float64)
    atomicStore(cast[ptr int64](gauge.metrics[labelValuesCopy][0].timestamp.addr), timestamp.addr, ATOMIC_SEQ_CST)

proc decGauge(gauge: Gauge, amount: int64|float64 = 1, labelValues: LabelsParam = @[]) =
  when defined(metrics):
    gauge.inc((-amount).float64, labelValues)

proc setGauge(gauge: Gauge, value: int64|float64, labelValues: LabelsParam = @[]) =
  when defined(metrics):
    var timestamp = getTime().toMilliseconds()

    let labelValuesCopy = validateGaugeLabelValues(gauge, labelValues)

    atomicStoreN(cast[ptr int64](gauge.metrics[labelValuesCopy][0].value.addr), cast[int64](value.float64), ATOMIC_SEQ_CST)
    atomicStore(cast[ptr int64](gauge.metrics[labelValuesCopy][0].timestamp.addr), timestamp.addr, ATOMIC_SEQ_CST)

template inc*(gauge: Gauge, amount: int64|float64 = 1, labelValues: LabelsParam = @[]) =
  when defined(metrics):
    {.gcsafe.}: incGauge(gauge, amount, labelValues)

template dec*(gauge: Gauge | type IgnoredCollector, amount: int64|float64 = 1, labelValues: LabelsParam = @[]) =
  when defined(metrics) and gauge is not IgnoredCollector:
    {.gcsafe.}: decGauge(gauge, amount, labelValues)

template set*(gauge: Gauge | type IgnoredCollector, value: int64|float64, labelValues: LabelsParam = @[]) =
  when defined(metrics) and gauge is not IgnoredCollector:
    {.gcsafe.}: setGauge(gauge, value, labelValues)

# in seconds
proc setToCurrentTime*(gauge: Gauge | type IgnoredCollector, labelValues: LabelsParam = @[]) =
  when defined(metrics) and gauge is not IgnoredCollector:
    gauge.set(getTime().toUnix(), labelValues)

template trackInProgress*(gauge: Gauge | type IgnoredCollector, labelValues: LabelsParam, body: untyped) =
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
template time*(gauge: Gauge | type IgnoredCollector, labelValues: LabelsParam, body: untyped) =
  when defined(metrics) and gauge is not IgnoredCollector:
    let start = times.toUnix(getTime())
    body
    gauge.set(times.toUnix(getTime()) - start, labelValues = labelValues)
  else:
    body

template time*(collector: Gauge | Summary | Histogram | type IgnoredCollector, body: untyped) =
  when defined(metrics) and collector is not IgnoredCollector:
    let labelValues: Labels = @[]
    collector.time(labelValues):
      body
  else:
    body

###########
# summary #
###########

when defined(metrics):
  proc newSummaryMetrics(name: string, labels, labelValues: LabelsParam): seq[Metric] =
    result = @[
      Metric(name: name & "_sum",
            labels: @labels,
            labelValues: @labelValues),
      Metric(name: name & "_count",
            labels: @labels,
            labelValues: @labelValues),
      Metric(name: name & "_created",
            labels: @labels,
            labelValues: @labelValues,
            value: getTime().toMilliseconds().float64),
    ]

  proc validateSummaryLabelValues(summary: Summary, labelValues: LabelsParam): Labels =
    result = validateLabelValues(summary, labelValues)
    if result notin summary.metrics:
      summary.metrics[result] = newSummaryMetrics(summary.name, summary.labels, result)

  proc newSummary*(name: string, help: string, labels: LabelsParam = @[], registry = defaultRegistry): Summary =
    validateName(name)
    validateLabels(labels, invalidLabelNames = ["quantile"])
    result = Summary(name: name,
                    help: help,
                    typ: "summary",
                    labels: @labels,
                    metrics: initOrderedTable[Labels, seq[Metric]](),
                    creationThreadId: getThreadId())
    if labels.len == 0:
      result.metrics[@labels] = newSummaryMetrics(name, labels, labels)
    result.register(registry)

template declareSummary*(identifier: untyped,
                        help: static string,
                        labels: LabelsParam = @[],
                        registry = defaultRegistry) {.dirty.} =
  when defined(metrics):
    var identifier = newSummary(astToStr(identifier), help, labels, registry)
  else:
    type identifier = IgnoredCollector

template declarePublicSummary*(identifier: untyped,
                               help: static string,
                               labels: LabelsParam = @[],
                               registry = defaultRegistry) {.dirty.} =
  when defined(metrics):
    var identifier* = newSummary(astToStr(identifier), help, labels, registry)
  else:
    type identifier* = IgnoredCollector

when defined(metrics):
  proc summary*(name: static string): Summary =
    var res {.global.} = newSummary(name, "") # lifted line
    return res
else:
  template summary*(name: static string): untyped =
    IgnoredCollector

proc observeSummary(summary: Summary, amount: int64|float64, labelValues: LabelsParam = @[]) =
  when defined(metrics):
    var timestamp = getTime().toMilliseconds()

    let labelValuesCopy = validateSummaryLabelValues(summary, labelValues)

    atomicAdd(summary.metrics[labelValuesCopy][0].value.addr, amount.float64) # _sum
    atomicStore(cast[ptr int64](summary.metrics[labelValuesCopy][0].timestamp.addr), timestamp.addr, ATOMIC_SEQ_CST)
    atomicAdd(summary.metrics[labelValuesCopy][1].value.addr, 1.float64) # _count
    atomicStore(cast[ptr int64](summary.metrics[labelValuesCopy][1].timestamp.addr), timestamp.addr, ATOMIC_SEQ_CST)

template observe*(summary: Summary | type IgnoredCollector, amount: int64|float64 = 1, labelValues: LabelsParam = @[]) =
  when defined(metrics) and summary is not IgnoredCollector:
    {.gcsafe.}: observeSummary(summary, amount, labelValues)

# in seconds
# the "type IgnoredCollector" case is covered by Gauge.time()
template time*(collector: Summary | Histogram, labelValues: LabelsParam, body: untyped) =
  when defined(metrics):
    let start = times.toUnix(getTime())
    body
    collector.observe(times.toUnix(getTime()) - start, labelValues = labelValues)
  else:
    body

#############
# histogram #
#############

let defaultHistogramBuckets* {.global.} = [0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0, Inf]
when defined(metrics):
  proc newHistogramMetrics(name: string, labels, labelValues: LabelsParam, buckets: seq[float64]): seq[Metric] =
    result = @[
      Metric(name: name & "_sum",
            labels: @labels,
            labelValues: @labelValues),
      Metric(name: name & "_count",
            labels: @labels,
            labelValues: @labelValues),
      Metric(name: name & "_created",
            labels: @labels,
            labelValues: @labelValues,
            value: getTime().toMilliseconds().float64),
    ]
    var bucketLabels = @labels & "le"
    for bucket in buckets:
      var bucketStr = $bucket
      if bucket == Inf:
        bucketStr = "+Inf"
      result.add(
        Metric(name: name & "_bucket",
              labels: bucketLabels,
              labelValues: @labelValues & bucketStr)
      )

  proc validateHistogramLabelValues(histogram: Histogram, labelValues: LabelsParam): Labels =
    result = validateLabelValues(histogram, labelValues)
    if result notin histogram.metrics:
      histogram.metrics[result] = newHistogramMetrics(histogram.name, histogram.labels, result, histogram.buckets)

  proc newHistogram*(name: string,
                    help: string,
                    labels: LabelsParam = @[],
                    registry = defaultRegistry,
                    buckets: openArray[float64] = defaultHistogramBuckets): Histogram =
    validateName(name)
    validateLabels(labels, invalidLabelNames = ["le"])
    var bucketsSeq = @buckets
    if bucketsSeq.len > 0 and bucketsSeq[^1] != Inf:
      bucketsSeq.add(Inf)
    if bucketsSeq.len < 2:
      raise newException(ValueError, "Invalid buckets list: '" & $bucketsSeq & "'. At least 2 required.")
    if not bucketsSeq.isSorted(system.cmp[float64]):
      raise newException(ValueError, "Invalid buckets list: '" & $bucketsSeq & "'. Must be sorted.")
    result = Histogram(name: name,
                    help: help,
                    typ: "histogram",
                    labels: @labels,
                    metrics: initOrderedTable[Labels, seq[Metric]](),
                    creationThreadId: getThreadId(),
                    buckets: bucketsSeq)
    if labels.len == 0:
      result.metrics[@labels] = newHistogramMetrics(name, labels, labels, bucketsSeq)
    result.register(registry)

template declareHistogram*(identifier: untyped,
                        help: static string,
                        labels: LabelsParam = @[],
                        registry = defaultRegistry,
                        buckets: openArray[float64] = defaultHistogramBuckets) {.dirty.} =
  when defined(metrics):
    var identifier = newHistogram(astToStr(identifier), help, labels, registry, buckets)
  else:
    type identifier = IgnoredCollector

template declarePublicHistogram*(identifier: untyped,
                               help: static string,
                               labels: LabelsParam = @[],
                               registry = defaultRegistry,
                               buckets: openArray[float64] = defaultHistogramBuckets) {.dirty.} =
  when defined(metrics):
    var identifier* = newHistogram(astToStr(identifier), help, labels, registry, buckets)
  else:
    type identifier* = IgnoredCollector

when defined(metrics):
  proc histogram*(name: static string): Histogram =
    var res {.global.} = newHistogram(name, "") # lifted line
    return res
else:
  template histogram*(name: static string): untyped =
    IgnoredCollector

proc observeHistogram(histogram: Histogram, amount: int64|float64, labelValues: LabelsParam = @[]) =
  when defined(metrics):
    var timestamp = getTime().toMilliseconds()

    let labelValuesCopy = validateHistogramLabelValues(histogram, labelValues)

    atomicAdd(histogram.metrics[labelValuesCopy][0].value.addr, amount.float64) # _sum
    atomicStore(cast[ptr int64](histogram.metrics[labelValuesCopy][0].timestamp.addr), timestamp.addr, ATOMIC_SEQ_CST)
    atomicAdd(histogram.metrics[labelValuesCopy][1].value.addr, 1.float64) # _count
    atomicStore(cast[ptr int64](histogram.metrics[labelValuesCopy][1].timestamp.addr), timestamp.addr, ATOMIC_SEQ_CST)
    for i, bucket in histogram.buckets:
      if amount.float64 <= bucket:
        #- "le" probably stands for "less or equal"
        #- the same observed value can increase multiple buckets, because this is
        #  a cumulative histogram
        atomicAdd(histogram.metrics[labelValuesCopy][i + 3].value.addr, 1.float64) # _bucket{le="<bucket value>"}
        atomicStore(cast[ptr int64](histogram.metrics[labelValuesCopy][i + 3].timestamp.addr), timestamp.addr, ATOMIC_SEQ_CST)

# the "type IgnoredCollector" case is covered by Summary.observe()
template observe*(histogram: Histogram, amount: int64|float64 = 1, labelValues: LabelsParam = @[]) =
  when defined(metrics):
    {.gcsafe.}: observeHistogram(histogram, amount, labelValues)

###############
# HTTP server #
###############

import asynchttpserver, asyncdispatch

when defined(metrics):
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

