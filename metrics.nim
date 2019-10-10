# Copyright (c) 2019 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

when defined(arm):
  # ARMv6 workaround - TODO upstream to Nim atomics
  {.passl:"-latomic".}

import algorithm, hashes, locks, net, os, random, re, sequtils, sets, strutils, tables, times

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
    sampleRate*: float # only used by StatsD counters

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

  proc toTextLines*(collector: Collector, metricsTable: Metrics, showTimestamp = true): seq[string] =
    result = @[
      "# HELP $# $#" % [collector.name, collector.help.processHelp()],
      "# TYPE $# $#" % [collector.name, collector.typ],
    ]
    for labelValues, metrics in metricsTable:
      for metric in metrics:
        result.add(metric.toText(showTimestamp))

  proc toText*(collector: Collector, showTimestamp = true): string =
    collector.toTextLines(collector.metrics, showTimestamp).join("\n")

  proc `$`*(collector: Collector): string =
    collector.toText()

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

# We use a generic type here in order to avoid the hidden type casting of
# Collector child types to the parent type.
proc register* [T] (collector: T, registry = defaultRegistry) =
  when defined(metrics):
    withLock registry.lock:
      if collector in registry.collectors:
        raise newException(RegistrationError, "Collector already registered.")

      registry.collectors.incl(collector)

proc unregister* [T] (collector: T, registry = defaultRegistry) =
  when defined(metrics) and collector is not IgnoredCollector:
    withLock registry.lock:
      if collector notin registry.collectors:
        raise newException(RegistrationError, "Collector not registered.")

      registry.collectors.excl(collector)

proc unregister* (collector: type IgnoredCollector, registry = defaultRegistry) = discard

proc collect*(registry: Registry): OrderedTable[Collector, Metrics] =
  when defined(metrics):
    result = initOrderedTable[Collector, Metrics]()
    withLock registry.lock:
      for collector in registry.collectors:
        var collectorCopy: Collector
        deepCopy(collectorCopy, collector)
        result[collectorCopy] = collectorCopy.collect()

proc toText*(registry: Registry, showTimestamp = true): string =
  when defined(metrics):
    var res: seq[string] = @[]
    for collector, metricsTable in registry.collect():
      res.add(collector.toTextLines(metricsTable, showTimestamp))
      res.add("")
    return res.join("\n")

proc `$`*(registry: Registry): string =
  registry.toText()

###########
# counter #
###########

when defined(metrics):
  proc newCounterMetrics(name: string, labels, labelValues: LabelsParam): seq[Metric] =
    result = @[
      Metric(name: name & "_total",
            labels: @labels,
            labelValues: @labelValues),
      Metric(name: name & "_created",
            labels: @labels,
            labelValues: @labelValues,
            value: getTime().toUnix().float64),
    ]

  proc validateCounterLabelValues(counter: Counter, labelValues: LabelsParam): Labels =
    result = validateLabelValues(counter, labelValues)
    if result notin counter.metrics:
      counter.metrics[result] = newCounterMetrics(counter.name, counter.labels, result)

  # don't document this one, even if we're forced to make it public, because it
  # won't work when all (or some) collectors are disabled
  proc newCounter*(name: string, help: string, labels: LabelsParam = @[], registry = defaultRegistry, sampleRate = 1.float): Counter =
    validateName(name)
    validateLabels(labels)
    result = Counter(name: name,
                    help: help,
                    typ: "counter",
                    labels: @labels,
                    metrics: initOrderedTable[Labels, seq[Metric]](),
                    creationThreadId: getThreadId(),
                    sampleRate: sampleRate)
    if labels.len == 0:
      result.metrics[@labels] = newCounterMetrics(name, labels, labels)
    result.register(registry)

template declareCounter*(identifier: untyped,
                        help: static string,
                        labels: LabelsParam = @[],
                        registry = defaultRegistry,
                        sampleRate = 1.float,
                        name = "") {.dirty.} =
  # fine-grained collector disabling will go in here, turning disabled
  # collectors into type aliases for IgnoredCollector
  when defined(metrics):
    var identifier = newCounter(if name != "": name else: astToStr(identifier), help, labels, registry, sampleRate)
  else:
    type identifier = IgnoredCollector

template declarePublicCounter*(identifier: untyped,
                               help: static string,
                               labels: LabelsParam = @[],
                               registry = defaultRegistry,
                               sampleRate = 1.float,
                               name = "") {.dirty.} =
  when defined(metrics):
    var identifier* = newCounter(if name != "": name else: astToStr(identifier), help, labels, registry, sampleRate)
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

    pushMetrics(name = counter.name,
                value = counter.metrics[labelValuesCopy][0].value,
                increment = amount.float64,
                metricType = "c",
                timestamp = timestamp,
                sampleRate = counter.sampleRate)

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
      Metric(name: name & "_created",
            labels: @labels,
            labelValues: @labelValues,
            value: getTime().toUnix().float64),
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
                      registry = defaultRegistry,
                      name = "") {.dirty.} =
  when defined(metrics):
    var identifier = newGauge(if name != "": name else: astToStr(identifier), help, labels, registry)
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
                            registry = defaultRegistry,
                            name = "") {.dirty.} =
  when defined(metrics):
    var identifier* = newGauge(if name != "": name else: astToStr(identifier), help, labels, registry)
  else:
    type identifier* = IgnoredCollector

proc incGauge(gauge: Gauge, amount: int64|float64 = 1, labelValues: LabelsParam = @[]) =
  when defined(metrics):
    var timestamp = getTime().toMilliseconds()

    let labelValuesCopy = validateGaugeLabelValues(gauge, labelValues)

    atomicAdd(gauge.metrics[labelValuesCopy][0].value.addr, amount.float64)
    atomicStore(cast[ptr int64](gauge.metrics[labelValuesCopy][0].timestamp.addr), timestamp.addr, ATOMIC_SEQ_CST)

    pushMetrics(name = gauge.name,
                value = gauge.metrics[labelValuesCopy][0].value,
                metricType = "g",
                timestamp = timestamp)

proc decGauge(gauge: Gauge, amount: int64|float64 = 1, labelValues: LabelsParam = @[]) =
  when defined(metrics):
    gauge.inc((-amount).float64, labelValues)

proc setGauge(gauge: Gauge, value: int64|float64, labelValues: LabelsParam = @[]) =
  when defined(metrics):
    var timestamp = getTime().toMilliseconds()

    let labelValuesCopy = validateGaugeLabelValues(gauge, labelValues)

    atomicStoreN(cast[ptr int64](gauge.metrics[labelValuesCopy][0].value.addr), cast[int64](value.float64), ATOMIC_SEQ_CST)
    atomicStore(cast[ptr int64](gauge.metrics[labelValuesCopy][0].timestamp.addr), timestamp.addr, ATOMIC_SEQ_CST)

    pushMetrics(name = gauge.name,
                value = value.float64,
                metricType = "g",
                timestamp = timestamp)

# the "type IgnoredCollector" case is covered by Counter.inc()
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
            value: getTime().toUnix().float64),
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
                        registry = defaultRegistry,
                        name = "") {.dirty.} =
  when defined(metrics):
    var identifier = newSummary(if name != "": name else: astToStr(identifier), help, labels, registry)
  else:
    type identifier = IgnoredCollector

template declarePublicSummary*(identifier: untyped,
                               help: static string,
                               labels: LabelsParam = @[],
                               registry = defaultRegistry,
                               name = "") {.dirty.} =
  when defined(metrics):
    var identifier* = newSummary(if name != "": name else: astToStr(identifier), help, labels, registry)
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
# the "type IgnoredCollector" case and the version without labels are covered by Gauge.time()
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
            value: getTime().toUnix().float64),
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
                        buckets: openArray[float64] = defaultHistogramBuckets,
                        name = "") {.dirty.} =
  when defined(metrics):
    var identifier = newHistogram(if name != "": name else: astToStr(identifier), help, labels, registry, buckets)
  else:
    type identifier = IgnoredCollector

template declarePublicHistogram*(identifier: untyped,
                               help: static string,
                               labels: LabelsParam = @[],
                               registry = defaultRegistry,
                               buckets: openArray[float64] = defaultHistogramBuckets,
                               name = "") {.dirty.} =
  when defined(metrics):
    var identifier* = newHistogram(if name != "": name else: astToStr(identifier), help, labels, registry, buckets)
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

################
# process info #
################

when defined(metrics) and defined(linux):
  import posix

  type ProcessInfo = ref object of Gauge

  proc newProcessInfo*(name: string, help: string, registry = defaultRegistry): ProcessInfo =
    validateName(name)
    result = ProcessInfo(name: name,
                        help: help,
                        typ: "gauge", # Prometheus won't allow fantasy types in here
                        creationThreadId: getThreadId())
    result.register(registry)

  var
    processInfo* {.global.} = newProcessInfo("process_info", "CPU and memory usage")
    btime {.global.}: float64 = 0
    ticks {.global.}: float64 # clock ticks per second
    pagesize {.global.}: float64 # page size in bytes
    whitespaceRegex {.global.} = re(r"\s+")

  if btime == 0:
    try:
      for line in lines("/proc/stat"):
        if line.startsWith("btime"):
          btime = line.split(' ')[1].parseFloat()
    except IOError:
      # /proc not mounted?
      discard
    ticks = sysconf(SC_CLK_TCK).float64
    pagesize = sysconf(SC_PAGE_SIZE).float64

  method collect*(collector: ProcessInfo): Metrics =
    result = initOrderedTable[Labels, seq[Metric]]()
    result[@[]] = @[]
    if btime == 0:
      # we couldn't access /proc
      return

    var timestamp = getTime().toMilliseconds()
    # the content of /proc/self/stat looks like this (the command name may contain spaces):
    #
    # $ cat /proc/self/stat
    # 30494 (cat) R 3022 30494 3022 34830 30494 4210688 98 0 0 0 0 0 0 0 20 0 1 0 73800491 10379264 189 18446744073709551615 94060049248256 94060049282149 140735229395104 0 0 0 0 0 0 0 0 0 17 6 0 0 0 0 0 94060049300560 94060049302112 94060076990464 140735229397011 140735229397031 140735229397031 140735229403119 0
    let selfStat = readFile("/proc/self/stat").split(") ")[^1].split(' ')
    result[@[]] = @[
      Metric(
        name: "process_virtual_memory_bytes", # Virtual memory size in bytes.
        value: selfStat[20].parseFloat(),
        timestamp: timestamp,
      ),
      Metric(
        name: "process_resident_memory_bytes", # Resident memory size in bytes.
        value: selfStat[21].parseFloat() * pagesize,
        timestamp: timestamp,
      ),
      Metric(
        name: "process_start_time_seconds", # Start time of the process since unix epoch in seconds.
        value: selfStat[19].parseFloat() / ticks + btime,
        timestamp: timestamp,
      ),
      Metric(
        name: "process_cpu_seconds_total", # Total user and system CPU time spent in seconds.
        value: (selfStat[11].parseFloat() + selfStat[12].parseFloat()) / ticks,
        timestamp: timestamp,
      ),
    ]

    for line in lines("/proc/self/limits"):
      if line.startsWith("Max open files"):
        result[@[]].add(
          Metric(
            name: "process_max_fds", # Maximum number of open file descriptors.
            value: line.split(whitespaceRegex)[3].parseFloat(), # a simple `split()` does not combine adjacent whitespace
            timestamp: timestamp,
          )
        )
        break

    result[@[]].add(
      Metric(
        name: "process_open_fds", # Number of open file descriptors.
        value: toSeq(walkDir("/proc/self/fd")).len.float64,
        timestamp: timestamp,
      )
    )

####################
# Nim runtime info #
####################

when defined(metrics):
  type RuntimeInfo = ref object of Gauge

  proc newRuntimeInfo*(name: string, help: string, registry = defaultRegistry): RuntimeInfo =
    validateName(name)
    result = RuntimeInfo(name: name,
                        help: help,
                        typ: "gauge",
                        creationThreadId: getThreadId())
    result.register(registry)

  var
    runtimeInfo* {.global.} = newRuntimeInfo("nim_runtime_info", "Nim runtime info")

  method collect*(collector: RuntimeInfo): Metrics =
    result = initOrderedTable[Labels, seq[Metric]]()
    var timestamp = getTime().toMilliseconds()

    result[@[]] = @[
      Metric(
        name: "nim_gc_mem_bytes", # the number of bytes that are owned by the process
        value: getTotalMem().float64,
        timestamp: timestamp,
      ),
      Metric(
        name: "nim_gc_mem_occupied_bytes", # the number of bytes that are owned by the process and hold data
        value: getOccupiedMem().float64,
        timestamp: timestamp,
      ),
    ]
    # TODO: parse the output of `GC_getStatistics()` for more stats

################################
# HTTP server (for Prometheus) #
################################

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
          # Prometheus will drop our metrics in surprising ways if we give it
          # timestamps, so we don't.
          await req.respond(Http200,
                            defaultRegistry.toText(showTimestamp = false),
                            newHttpHeaders([("Content-Type", CONTENT_TYPE)]))
      else:
        await req.respond(Http404, "Try /metrics")

    waitFor server.serve(port, cb, address)

proc startHttpServer*(address = "127.0.0.1", port = Port(8000)) =
  when defined(metrics):
    httpServerThread.createThread(httpServer, (address, port))

#######################################
# export metrics to StatsD and Carbon #
#######################################

when defined(metrics):
  type
    MetricProtocol* = enum
      STATSD
      CARBON

    NetProtocol* = enum
      TCP
      UDP

    ExportBackend* = object
      metricProtocol*: MetricProtocol
      netProtocol*: NetProtocol
      address*: string
      port*: Port

    ExportedMetric = object
      name: string
      value: float64
      increment: float64
      metricType: string
      timestamp: int64
      sampleRate: float # only used by StatsD

  const
    METRIC_EXPORT_BUFER_SIZE = 1024 # used by exportChan
    CONNECT_TIMEOUT_MS = 100 # in milliseconds
    RECONNECT_INTERVAL = initDuration(seconds = 10)

  var
    exportBackends*: seq[ExportBackend] = @[]
    exportBackendsLock*: Lock
    exportChan: Channel[ExportedMetric]
    exportThread: Thread[void]
    sockets: seq[Socket] = @[] # we maintain one socket per backend
    lastConnectionTime: seq[times.Time] = @[] # last time we tried to connect the corresponding socket
    epochStart = initTime(0, 0)

  initLock(exportBackendsLock)
  exportChan.open(maxItems = METRIC_EXPORT_BUFER_SIZE)

  proc addExportBackend*(metricProtocol: MetricProtocol, netProtocol: NetProtocol, address: string, port: Port) =
    withLock(exportBackendsLock):
      exportBackends.add(ExportBackend(
                          metricProtocol: metricProtocol,
                          netProtocol: netProtocol,
                          address: address,
                          port: port
                        ))

  proc pushMetrics*(name: string, value: float64, increment = 0.float64, metricType: string, timestamp: int64, sampleRate = 1.float) =
    # this may run from different threads

    if len(exportBackends) == 0:
      # no backends configured
      return

    # Send a new metric to the thread handling the networking.
    # Silently drop it if the channel's buffer is full.
    discard exportChan.trySend(ExportedMetric(
                                name: name,
                                value: value,
                                increment: increment,
                                metricType: metricType,
                                timestamp: timestamp,
                                sampleRate: sampleRate
                              ))

  # connect or reconnect the socket at position i in `sockets`
  proc reconnectSocket(i: int, backend: ExportBackend) =
    # Throttle it.
    # We don't expect enough backends to worry about the thundering herd problem.
    if getTime() - lastConnectionTime[i] < RECONNECT_INTERVAL:
      sleep(100) # silly optimisation for an artificial benchmark where we try to
                 # export as many metric updates as possible with a missing backend
      return

    # try to close any existing socket, first
    if sockets[i] != nil:
      try:
        sockets[i].close()
      except:
        discard
      sockets[i] = nil # we use this as a flag to avoid sends without a connection

    # create a new socket
    case backend.netProtocol:
      of UDP:
        sockets[i] = newSocket(Domain.AF_INET, SockType.SOCK_DGRAM, Protocol.IPPROTO_UDP)
      of TCP:
        sockets[i] = newSocket()

    # try to connect
    lastConnectionTime[i] = getTime()
    try:
      sockets[i].connect(backend.address, backend.port, timeout = CONNECT_TIMEOUT_MS)
    except:
      try:
        sockets[i].close()
      except:
        discard
      sockets[i] = nil

  proc pushMetricsWorker() {.thread.} =
    var
      data: ExportedMetric # received from the channel
      payload: string
      i: int
      backend: ExportBackend
      finalValue: float64
      sampleString: string

    # seed the simple PRNG we're using for sample rates
    randomize()

    # No custom cleanup needed here, so let this thread be killed, the sockets
    # closed, etc., by the OS.
    while true:
      data = exportChan.recv() # blocking read
      withLock(exportBackendsLock):
        {.gcsafe.}:
          # Account for backends added after this thread is launched. We don't
          # support backend deletion.
          if len(sockets) < len(exportBackends):
            sockets.setLen(len(exportBackends))
          if len(lastConnectionTime) < len(exportBackends):
            lastConnectionTime.setLen(len(exportBackends))

          # send the metrics
          for i, backend in exportBackends:
            case backend.metricProtocol:
              of STATSD:
                finalValue = data.value
                sampleString = ""

                if data.metricType == "c":
                  # StatsD wants only the counter's increment, while Carbon wants the cumulated value
                  finalValue = data.increment

                  # If the sample rate was set, throw the dice here.
                  if data.sampleRate > 0 and data.sampleRate < 1.float:
                    if rand(max = 1.float) > data.sampleRate:
                      # skip it
                      continue
                    sampleString = "|@" & $data.sampleRate
                payload = "$#:$#|$#$#\n" % [data.name, $finalValue, data.metricType, sampleString]
              of CARBON:
                # Carbon wants a 32-bit timestamp in seconds.
                payload = "$# $# $#\n" % [data.name, $data.value, $(data.timestamp div 1000).int32]

            if sockets[i] == nil:
              reconnectSocket(i, backend)
              if sockets[i] == nil:
                # we're in the waiting period
                continue

            try:
              sockets[i].send(payload, flags = {}) # the default flags would not raise an exception on a broken connection
            except:
              reconnectSocket(i, backend)
              # No need to try and resend the data. We can afford to lose it.

  exportThread.createThread(pushMetricsWorker)

