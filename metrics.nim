# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0: http://www.apache.org/licenses/LICENSE-2.0
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# The API is roughly based on the Prometheus client library recommendations:
# https://prometheus.io/docs/instrumenting/writing_clientlibs/
#
# The Prometheus text exposition format is also tightly coupled:
# https://prometheus.io/docs/instrumenting/exposition_formats/#text-based-format

{.push raises: [].}

when defined(metricsTest):
  {.pragma: testOnly.}
else:
  {.pragma: testOnly, deprecated: "slow helpers used for tests only".}

import std/[locks, monotimes, os, sets, tables, times]

when defined(metrics):
  import std/[algorithm, hashes, strutils, sequtils], stew/ptrops, metrics/common

  export tables # for custom collectors that need to work with the "Metrics" type

type
  LabelKey = object
    # Helper type to work around the lack of heterogenous key support in `Table`
    data: seq[string]
    refs: ptr UncheckedArray[string]
    refslen: int

  Metric* = object
    name*: string
    value*: float64
    labels*: seq[string]
    labelValues*: seq[string]
    timestamp*: Time

  MetricHandler* =
    proc(
      name: string,
      value: float64,
      labels: openArray[string] = [],
      labelValues: openArray[string] = [],
      timestamp: Time,
    ) {.gcsafe, raises: [].}

  CollecorHandler* = proc(collector: Collector)

  Collector* = ref object of RootObj
    lock*: Lock
    name*: string
    help*: string
    typ*: string
    labels*: seq[string]
    timestamp*: bool ## Whether or not we're collecting timestamps for this collector
    creationThreadId*: int
    sampleRate*: float # only used by StatsD counters

  SimpleCollector* = ref object of Collector
    metricKeys*: Table[LabelKey, int]
    metrics*: seq[seq[Metric]]

  IgnoredCollector* = object

  Counter* = ref object of SimpleCollector
  Gauge* = ref object of SimpleCollector
  Summary* = ref object of SimpleCollector
  Histogram* = ref object of SimpleCollector # a cumulative histogram, not a regular one
    buckets*: seq[float64]

  Registry* = ref object of RootObj
    lock*: Lock
    collectors*: OrderedSet[Collector]

  RegistrationError* = object of CatchableError

#########
# utils #
#########

when defined(metrics):
  template values(key: LabelKey): openArray[string] =
    if key.refslen > 0:
      key.refs.toOpenArray(0, key.refslen - 1)
    else:
      key.data

  proc hash(key: LabelKey): Hash =
    hash(key.values)

  proc `==`(a, b: LabelKey): bool =
    a.values == b.values

  proc init(T: type LabelKey, values: openArray[string]): T =
    LabelKey(data: @values)

  proc view(T: type LabelKey, values: openArray[string]): T =
    # TODO some day, we might get view types - until then..
    LabelKey(refs: baseAddr(values).makeUncheckedArray(), refslen: values.len())

  proc toMilliseconds*(time: times.Time): int64 =
    convert(Seconds, Milliseconds, time.toUnix()) +
      convert(Nanoseconds, Milliseconds, time.nanosecond())

  template nameOrIdentifier*(identifier: untyped, name: string): string =
    if name.len == 0:
      astToStr(identifier)
    else:
      name

  proc processHelp(name, help: string): string =
    "# HELP " & name & " " & help.multiReplace([("\\", "\\\\"), ("\n", "\\n")]) & "\n"

  proc processType(name, typ: string): string =
    "# TYPE " & name & " " & typ & "\n"

  template processLabelValue(labelValue: string): string =
    labelValue.multiReplace([("\\", "\\\\"), ("\n", "\\n"), ("\"", "\\\"")])

  proc addText(
      res: var string,
      name: string,
      value: float64,
      labels, labelValues: openArray[string],
      timestamp: Time,
  ) =
    # A bit convoluted to mostly avoid pointless memory allocations - there's no
    # (trivial) way however to append a float to an existing string
    res.add name
    if labels.len > 0:
      res.add('{')
      for i in 0..labels.high:
        if i > 0:
          res.add ","
        res.add labels[i]
        res.add "=\""
        if labelValues.len > i:
          res.add labelValues[i]
        res.add "\""
      res.add('}')
    res.add(" ")
    res.add($value)
    if toMilliseconds(timestamp) > 0:
      res.add(" " & $toMilliseconds(timestamp))

  proc addText(res: var string, metric: Metric) =
    addText(
      res,
      metric.name,
      metric.value,
      metric.labels,
      metric.labelValues,
      metric.timestamp,
    )

  proc `$`*(metric: Metric): string =
    addText(result, metric)

  const
    nameRegexStr = r"^[a-zA-Z_:][a-zA-Z0-9_:]*$"
    labelRegexStr = r"^[a-zA-Z_][a-zA-Z0-9_]*$"

    labelStartChars = {'a'..'z', 'A'..'Z', '_'}
    labelChars = labelStartChars + {'0'..'9'}
    nameStartChars = labelStartChars + {':'}
    nameChars = labelChars + {':'}

  template validate(ident: string, startChars, chars: typed): bool =
    ident.len > 0 and ident[0] in startChars and ident.allIt(it in chars)

  proc validateName(name: string) {.raises: [ValueError].} =
    if not validate(name, nameStartChars, nameChars):
      raise newException(
          ValueError,
          "Invalid name: '" & name & "'. It should match the regex: " & nameRegexStr,
        )

  proc validateLabels(
      labels: openArray[string], invalidLabelNames: openArray[string] = []
  ) {.raises: [ValueError].} =
    for label in labels:
      if not validate(label, labelStartChars, labelChars):
        raise newException(
            ValueError,
            "Invalid label: '" & label & "'. It should match the regex: '" &
              labelRegexStr & "'.",
          )
      if label.startsWith("__"):
        raise newException(
            ValueError, "Invalid label: '" & label & "'. It should not start with '__'."
          )
      if label in invalidLabelNames:
        raise newException(
            ValueError,
            "Invalid label: '" & label & "'. It should not be one of: " &
              $invalidLabelNames & ".",
          )

######################
# generic collectors #
######################

when defined(metrics):
  template withLabelValues(
      collector: SimpleCollector,
      labelValues: openArray[string],
      metricSym, body, construct: untyped,
  ) =
    if labelValues.len > 0 and labelValues.len != collector.labels.len:
      printError(
        "The number of label values doesn't match the number of labels: " &
          collector.name
      )
    else:
      withLock(collector.lock):
        collector.metricKeys.withValue(LabelKey.view(labelValues), metricsIdx):
          template metricSym(): untyped =
            collector.metrics[metricsIdx[]]

          body
        do:
          if collector.creationThreadId != getThreadId():
            printError(
              "New label values must be added from same thread as the metric was created from - observation dropped: " &
                collector.name
            )
          else:
            collector.metrics.add construct
            collector.metricKeys[LabelKey.init(labelValues)] = collector.metrics.high
            collector.metricKeys.withValue(LabelKey.view(labelValues), metricsIdx):
              template metricSym(): untyped =
                collector.metrics[metricsIdx[]]

              body

  method hash*(collector: Collector): Hash {.base.} =
    result = result !& collector.name.hash
    for label in collector.labels:
      result = result !& label.hash
    result = !$result

  # `hash` and equals must match
  method `==`*(x, y: Collector): bool {.base.} =
    x.name == y.name and x.labels == y.labels

  proc now*(collector: Collector): Time =
    if collector.timestamp:
      getTime()
    else:
      Time()

  proc call(output: MetricHandler, metric: Metric) =
    output(
      metric.name, metric.value, metric.labels, metric.labelValues, metric.timestamp
    )

  method collect*(collector: Collector, output: MetricHandler) {.base.} =
    discard

  method collect*(collector: SimpleCollector, output: MetricHandler) =
    {.warning[LockLevel]: off.}
    withLock(collector.lock):
      for key, idx in collector.metricKeys:
        for metric in collector.metrics[idx]:
          call(output, metric)

  proc collect*(registry: Registry, output: MetricHandler) =
    withLock registry.lock:
      for collector in registry.collectors:
        collector.collect(output)

  proc addText(res: var string, collector: Collector) =
    res.add collector.help
    res.add collector.typ

    let resPtr = addr res

    proc addMetric(
        name: string,
        value: float64,
        labels, labelValues: openArray[string],
        timestamp: Time,
    ) =
      addText(resPtr[], name, value, labels, labelValues, timestamp)
      resPtr[].add "\n"

    collect(collector, addMetric)

  proc `$`*(collector: Collector): string =
    addText(result, collector)

proc `$`*(collector: type IgnoredCollector): string =
  ""

when defined(metrics):
  proc valueImpl*(
      collector: Collector,
      labelValuesParam: openArray[string] = [],
  ): float64 {.gcsafe, raises: [KeyError].} =
    var res = NaN
    # Don't access the "metrics" field directly, so we can support custom
    # collectors.
    {.gcsafe.}:
      let lv = @labelValuesParam.mapIt(it.processLabelValue())
      proc findMetric(
          name: string,
          value: float64,
          labels, labelValues: openArray[string],
          timestamp: Time) =
        if res != res and labelValues == lv:
          res = value

      collect(collector, findMetric)
      if res != res: # NaN
        raise newException(
            KeyError,
            "No such metric for this collector (label values = " & $(@labelValuesParam) &
              ").",
              )
    res

template value*(
    collector: Collector | type IgnoredCollector,
    labelValuesParam: openArray[string] = [],
): float64 {.testOnly.} =
  when defined(metrics) and collector is not IgnoredCollector:
    {.gcsafe.}:
      valueImpl(collector, labelValuesParam)
  else:
    0.0'f64

proc valueByNameInternal*(
    collector: Collector | type IgnoredCollector,
    metricName: string,
    labelValues: openArray[string] = [],
    extraLabelValues: openArray[string] = [],
): float64 {.raises: [ValueError].} =
  when defined(metrics) and collector is not IgnoredCollector:
    var res = NaN
    let allLabelValues = labelValues.mapIt(it.processLabelValue()) & @extraLabelValues
    proc findMetric(
        name: string,
        value: float64,
        labels, labelValues: openArray[string],
        timestamp: Time,
    ) =
      if res != res and name == metricName and labelValues == allLabelValues:
        res = value

    collect(collector, findMetric)
    if res == res:
      return res

    raise newException(
        KeyError,
        "No such metric name for this collector: '" & metricName & "' (label values = " &
          $allLabelValues & ").",
      )

template valueByName*(
    collector: Collector | type IgnoredCollector,
    metricName: string,
    labelValues: openArray[string] = [],
    extraLabelValues: openArray[string] = [],
): float64 {.testOnly.} =
  {.gcsafe.}:
    valueByNameInternal(collector, metricName, labelValues, extraLabelValues)

############
# registry #
############

proc newRegistry*(): Registry =
  when defined(metrics):
    new(result)
    result.lock.initLock()

# needs to be {.global.} because of the alternative API's usage of {.global.} collector vars
let defaultRegistry* {.global.} = newRegistry()

# We use a generic type here in order to avoid the hidden type casting of
# Collector child types to the parent type.
proc register*[T](
    collector: T, registry = defaultRegistry
) {.raises: [RegistrationError].} =
  when defined(metrics):
    withLock registry.lock:
      if collector in registry.collectors:
        raise newException(
            RegistrationError, "Collector already registered: " & collector.name
          )

      registry.collectors.incl(collector)

proc unregister*[T](
    collector: T, registry = defaultRegistry
) {.raises: [RegistrationError].} =
  when defined(metrics) and collector is not IgnoredCollector:
    withLock registry.lock:
      if collector notin registry.collectors:
        raise newException(RegistrationError, "Collector not registered.")

      registry.collectors.excl(collector)

proc unregister*(collector: type IgnoredCollector, registry = defaultRegistry) =
  discard

proc len(registry: Registry): int =
  when defined(metrics):
    withLock registry.lock:
      return registry.collectors.len()
  else:
    0

proc addText(res: var string, registry: Registry) =
  when defined(metrics):
    withLock registry.lock:
      for collector in registry.collectors:
        res.addText(collector)
        res.add("\n")

proc toText*(registry: Registry): string =
  result = newStringOfCap(registry.len() * 64)
  result.addText(registry)

proc `$`*(registry: Registry): string =
  addText(result, registry)

#####################
# custom collectors #
#####################

when defined(metrics):
  # Used for custom collectors, to shield the API user from having to deal with
  # internal details like lock initialisation.
  # Also used internally, for creating standard collectors, to avoid code
  # duplication.
  proc newCollector*[T](
      typ: typedesc[T],
      name: string,
      help: string,
      labels: openArray[string] = [],
      registry = defaultRegistry,
      standardType = "gauge",
      timestamp = false,
  ): T {.raises: [ValueError, RegistrationError].} =
    validateName(name)
    validateLabels(labels)
    result =
      T(
        name: name,
        help: processHelp(name, help),
        typ: processType(name, standardType),
          # Prometheus does not support a non-standard value here
        labels: @labels,
        creationThreadId: getThreadId(),
        timestamp: timestamp,
      )
    result.lock.initLock()
    result.register(registry)

when defined(metrics):
  proc updateSystemMetrics*() {.gcsafe.} # defined later in this file
  var systemMetricsAutomaticUpdate = true
    # whether to piggy-back on changes of user-defined metrics

  proc getSystemMetricsAutomaticUpdate*(): bool =
    systemMetricsAutomaticUpdate

  proc setSystemMetricsAutomaticUpdate*(value: bool) =
    systemMetricsAutomaticUpdate = value

  proc pushMetrics*(
      name: string,
      value: float64,
      increment = 0.float64,
      metricType: string,
      timestamp: Time,
      sampleRate = 1.float,
      doUpdateSystemMetrics = true,
  ) {.raises: [].} =
    # this may run from different threads
    if systemMetricsAutomaticUpdate and doUpdateSystemMetrics:
      updateSystemMetrics()

###########
# counter #
###########

when defined(metrics):
  proc newCounterMetrics(
      name: string, labels, labelValues: openArray[string]
  ): seq[Metric] =
    let labelValues = labelValues.mapIt(it.processLabelValue())
    @[
      Metric(name: name & "_total", labels: @labels, labelValues: labelValues),
      Metric(
        name: name & "_created",
        labels: @labels,
        labelValues: labelValues,
        value: getTime().toUnix().float64,
      )
    ]

  # don't document this one, even if we're forced to make it public, because it
  # won't work when all (or some) collectors are disabled
  proc newCounter*(
      name: string,
      help: string,
      labels: openArray[string] = [],
      registry = defaultRegistry,
      sampleRate = 1.float,
      timestamp = false,
  ): Counter {.raises: [ValueError, RegistrationError].} =
    result = Counter.newCollector(name, help, labels, registry, "counter", timestamp)
    result.sampleRate = sampleRate
    if labels.len == 0:
      result.metrics.add newCounterMetrics(name, labels, labels)
      result.metricKeys[LabelKey.init(labels)] = result.metrics.high()

  proc incCounter(counter: Counter, amount: float64, labelValues: openArray[string]) =
    if amount < 0:
      printError(
        "Counter.inc() cannot be used with negative amounts: " & $counter.name & "=" &
          $amount
      )
      return

    let timestamp = counter.now()
    withLabelValues(counter, labelValues, valueSym):
      valueSym[0].value += amount
      valueSym[0].timestamp = timestamp

      pushMetrics(
        name = counter.name,
        value = valueSym[0].value,
        increment = amount,
        metricType = "c",
        timestamp = timestamp,
        sampleRate = counter.sampleRate,
      )
    do:
      newCounterMetrics(counter.name, counter.labels, labelValues)

template declareCounter*(
    identifier: untyped,
    help: static string,
    labels: openArray[string] = [],
    registry = defaultRegistry,
    sampleRate = 1.float,
    name = "",
    timestamp = false,
) {.dirty.} =
  # fine-grained collector disabling will go in here, turning disabled
  # collectors into type aliases for IgnoredCollector
  when defined(metrics):
    let
      identifier =
        newCounter(
          nameOrIdentifier(identifier, name),
          help,
          labels,
          registry,
          sampleRate,
          timestamp,
        )
  else:
    type identifier = IgnoredCollector

template declarePublicCounter*(
    identifier: untyped,
    help: static string,
    labels: openArray[string] = [],
    registry = defaultRegistry,
    sampleRate = 1.float,
    name = "",
    timestamp = false,
) {.dirty.} =
  when defined(metrics):
    let
      identifier* =
        newCounter(
          nameOrIdentifier(identifier, name),
          help,
          labels,
          registry,
          sampleRate,
          timestamp,
        )
  else:
    type identifier* = IgnoredCollector

#- alternative API (without support for custom help strings, labels or custom registries)
#- different collector types with the same names are allowed
#- don't mark this proc as {.inline.} because it's incompatible with {.global.}: https://github.com/status-im/nim-metrics/pull/5#discussion_r304687474
when defined(metrics):
  proc counter*(
      name: static string
  ): Counter {.raises: [ValueError, RegistrationError].} =
    # This {.global.} var assignment is lifted from the procedure and placed in a
    # special module init section that's guaranteed to run only once per program.
    # Calls to this proc will just return the globally initialised variable.
    var res {.global.} = newCounter(name, "")
    return res

else:
  template counter*(name: static string): untyped =
    IgnoredCollector

template inc*(
    counter: Counter | type IgnoredCollector,
    amount: int64 | float64 = 1,
    labelValues: openArray[string] = [],
) =
  when defined(metrics) and counter is not IgnoredCollector:
    {.gcsafe.}:
      incCounter(counter, amount.float64, labelValues)

template countExceptions*(
    counter: Counter | type IgnoredCollector,
    typ: typedesc,
    labelValues: openArray[string],
    body: untyped,
) =
  when defined(metrics) and counter is not IgnoredCollector:
    try:
      body
    except typ as exc:
      counter.inc(1, labelValues)
      raise exc
  else:
    body

template countExceptions*(
    counter: Counter | type IgnoredCollector, typ: typedesc, body: untyped
) =
  when defined(metrics) and counter is not IgnoredCollector:
    counter.countExceptions(typ, []):
      body
  else:
    body

template countExceptions*(
    counter: Counter | type IgnoredCollector,
    labelValues: openArray[string],
    body: untyped,
) =
  countExceptions(counter, Exception, labelValues, body)

template countExceptions*(counter: Counter | type IgnoredCollector, body: untyped) =
  when defined(metrics) and counter is not IgnoredCollector:
    counter.countExceptions([]):
      body
  else:
    body

#########
# gauge #
#########

when defined(metrics):
  proc newGaugeMetrics(
      name: string, labels, labelValues: openArray[string]
  ): seq[Metric] =
    let labelValues = labelValues.mapIt(it.processLabelValue())
    result =
      @[
        Metric(name: name, labels: @labels, labelValues: labelValues),
        Metric(
          name: name & "_created",
          labels: @labels,
          labelValues: labelValues,
          value: getTime().toUnix().float64,
        )
      ]

  proc newGauge*(
      name: string,
      help: string,
      labels: openArray[string] = [],
      registry = defaultRegistry,
      timestamp = false,
  ): Gauge {.raises: [ValueError, RegistrationError].} =
    result = Gauge.newCollector(name, help, labels, registry, "gauge", timestamp)
    if labels.len == 0:
      result.metrics.add newGaugeMetrics(name, labels, labels)
      result.metricKeys[LabelKey.init(labels)] = result.metrics.high()

  proc incGauge(gauge: Gauge, amount: float64, labelValues: openArray[string]) =
    let timestamp = gauge.now()

    withLabelValues(gauge, labelValues, valueSym):
      valueSym[0].value += amount
      valueSym[0].timestamp = timestamp
      pushMetrics(
        name = gauge.name,
        value = valueSym[0].value,
        metricType = "g",
        timestamp = timestamp,
      )
    do:
      newGaugeMetrics(gauge.name, gauge.labels, labelValues)

  proc setGauge(
      gauge: Gauge,
      value: float64,
      labelValues: openArray[string],
      doUpdateSystemMetrics: bool,
  ) =
    let timestamp = gauge.now()

    withLabelValues(gauge, labelValues, valueSym):
      valueSym[0].value = value.float64
      if gauge.timestamp:
        valueSym[0].timestamp = getTime()
      pushMetrics(
        name = gauge.name,
        value = value.float64,
        metricType = "g",
        timestamp = timestamp,
        doUpdateSystemMetrics = doUpdateSystemMetrics,
      )
    do:
      newGaugeMetrics(gauge.name, gauge.labels, labelValues)

template declareGauge*(
    identifier: untyped,
    help: static string,
    labels: openArray[string] = [],
    registry = defaultRegistry,
    name = "",
    timestamp = false,
) {.dirty.} =
  when defined(metrics):
    var
      identifier =
        newGauge(nameOrIdentifier(identifier, name), help, labels, registry, timestamp)
  else:
    type identifier = IgnoredCollector

# alternative API
when defined(metrics):
  proc gauge*(name: static string): Gauge {.raises: [ValueError, RegistrationError].} =
    var res {.global.} = newGauge(name, "") # lifted line
    return res

else:
  template gauge*(name: static string): untyped =
    IgnoredCollector

template declarePublicGauge*(
    identifier: untyped,
    help: static string,
    labels: openArray[string] = [],
    registry = defaultRegistry,
    name = "",
    timestamp = false,
) {.dirty.} =
  when defined(metrics):
    var
      identifier* =
        newGauge(nameOrIdentifier(identifier, name), help, labels, registry, timestamp)
  else:
    type identifier* = IgnoredCollector

# the "type IgnoredCollector" case is covered by Counter.inc()
template inc*(
    gauge: Gauge, amount: int64 | float64 = 1, labelValues: openArray[string] = []
) =
  when defined(metrics):
    {.gcsafe.}:
      incGauge(gauge, amount.float64, labelValues)

template dec*(
    gauge: Gauge | type IgnoredCollector,
    amount: int64 | float64 = 1,
    labelValues: openArray[string] = [],
) =
  when defined(metrics) and gauge is not IgnoredCollector:
    inc(gauge, -amount, labelValues)

template set*(
    gauge: Gauge | type IgnoredCollector,
    value: int64 | float64,
    labelValues: openArray[string] = [],
    doUpdateSystemMetrics = true,
) =
  when defined(metrics) and gauge is not IgnoredCollector:
    {.gcsafe.}:
      setGauge(gauge, value.float64, labelValues, doUpdateSystemMetrics)

# in seconds
proc setToCurrentTime*(
    gauge: Gauge | type IgnoredCollector, labelValues: openArray[string] = []
) =
  when defined(metrics) and gauge is not IgnoredCollector:
    gauge.set(getTime().toUnix(), labelValues)

template trackInProgress*(
    gauge: Gauge | type IgnoredCollector, labelValues: openArray[string], body: untyped
) =
  when defined(metrics) and gauge is not IgnoredCollector:
    gauge.inc(1, labelValues)
    body
    gauge.dec(1, labelValues)
  else:
    body

template trackInProgress*(gauge: Gauge | type IgnoredCollector, body: untyped) =
  when defined(metrics) and gauge is not IgnoredCollector:
    gauge.trackInProgress([]):
      body
  else:
    body

# in seconds
template time*(
    gauge: Gauge | type IgnoredCollector, labelValues: openArray[string], body: untyped
) =
  when defined(metrics) and gauge is not IgnoredCollector:
    let start = times.toUnix(getTime())
    body
    gauge.set(times.toUnix(getTime()) - start, labelValues)
  else:
    body

template time*(
    collector: Gauge | Summary | Histogram | type IgnoredCollector, body: untyped
) =
  when defined(metrics) and collector is not IgnoredCollector:
    collector.time([]):
      body
  else:
    body

###########
# summary #
###########

when defined(metrics):
  proc newSummaryMetrics(
      name: string, labels, labelValues: openArray[string]
  ): seq[Metric] =
    let labelValues = labelValues.mapIt(it.processLabelValue())
    @[
      Metric(name: name & "_sum", labels: @labels, labelValues: labelValues),
      Metric(name: name & "_count", labels: @labels, labelValues: labelValues),
      Metric(
        name: name & "_created",
        labels: @labels,
        labelValues: labelValues,
        value: getTime().toUnix().float64,
      )
    ]

  proc newSummary*(
      name: string,
      help: string,
      labels: openArray[string] = [],
      registry = defaultRegistry,
      timestamp = false,
  ): Summary {.raises: [ValueError, RegistrationError].} =
    validateLabels(labels, invalidLabelNames = ["quantile"])
    result = Summary.newCollector(name, help, labels, registry, "summary", timestamp)
    if labels.len == 0:
      result.metrics.add newSummaryMetrics(name, labels, labels)
      result.metricKeys[LabelKey.init(labels)] = result.metrics.high()

  proc observeSummary(summary: Summary, amount: float64, labelValues: openArray[string]) =
    let timestamp = summary.now()

    withLabelValues(summary, labelValues, valueSym):
      valueSym[0].value += amount # _sum
      valueSym[0].timestamp = timestamp
      valueSym[1].value += 1.float64 # _count
      valueSym[1].timestamp = timestamp
    do:
      newSummaryMetrics(summary.name, summary.labels, labelValues)

template declareSummary*(
    identifier: untyped,
    help: static string,
    labels: openArray[string] = [],
    registry = defaultRegistry,
    name = "",
) {.dirty.} =
  when defined(metrics):
    let
      identifier =
        newSummary(nameOrIdentifier(identifier, name), help, labels, registry)
  else:
    type identifier = IgnoredCollector

template declarePublicSummary*(
    identifier: untyped,
    help: static string,
    labels: openArray[string] = [],
    registry = defaultRegistry,
    name = "",
) {.dirty.} =
  when defined(metrics):
    let
      identifier* =
        newSummary(nameOrIdentifier(identifier, name), help, labels, registry)
  else:
    type identifier* = IgnoredCollector

when defined(metrics):
  proc summary*(
      name: static string
  ): Summary {.raises: [ValueError, RegistrationError].} =
    var res {.global.} = newSummary(name, "") # lifted line
    return res

else:
  template summary*(name: static string): untyped =
    IgnoredCollector

template observe*(
    summary: Summary | type IgnoredCollector,
    amount: int64 | float64 = 1,
    labelValues: openArray[string] = [],
) =
  when defined(metrics) and summary is not IgnoredCollector:
    {.gcsafe.}:
      observeSummary(summary, amount.float64, labelValues)

# in seconds
# the "type IgnoredCollector" case and the version without labels are covered by Gauge.time()
template time*(
    collector: Summary | Histogram, labelValues: openArray[string], body: untyped
) =
  when defined(metrics):
    let start = times.toUnix(getTime())
    body
    collector.observe(times.toUnix(getTime()) - start, labelValues)
  else:
    body

#############
# histogram #
#############

const
  defaultHistogramBuckets* = [
    0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0, Inf
  ]
when defined(metrics):
  proc newHistogramMetrics(
      name: string, labels, labelValues: openArray[string], buckets: seq[float64]
  ): seq[Metric] =
    let labelValues = labelValues.mapIt(it.processLabelValue())
    result =
      @[
        Metric(name: name & "_sum", labels: @labels, labelValues: labelValues),
        Metric(name: name & "_count", labels: @labels, labelValues: labelValues),
        Metric(
          name: name & "_created",
          labels: @labels,
          labelValues: labelValues,
          value: getTime().toUnix().float64,
        )
      ]
    var bucketLabels = @labels & "le"
    for bucket in buckets:
      var bucketStr = $bucket
      if bucket == Inf:
        bucketStr = "+Inf"
      result.add(
        Metric(
          name: name & "_bucket",
          labels: bucketLabels,
          labelValues: labelValues & bucketStr,
        )
      )

  proc newHistogram*(
      name: string,
      help: string,
      labels: openArray[string] = [],
      registry = defaultRegistry,
      buckets: openArray[float64] = defaultHistogramBuckets,
      timestamp = false,
  ): Histogram {.raises: [ValueError, RegistrationError].} =
    validateLabels(labels, invalidLabelNames = ["le"])
    var bucketsSeq = @buckets
    if bucketsSeq.len > 0 and bucketsSeq[^1] != Inf:
      bucketsSeq.add(Inf)
    if bucketsSeq.len < 2:
      raise newException(
          ValueError,
          "Invalid buckets list: '" & $bucketsSeq & "'. At least 2 required.",
        )
    if not bucketsSeq.isSorted(system.cmp[float64]):
      raise newException(
          ValueError, "Invalid buckets list: '" & $bucketsSeq & "'. Must be sorted."
        )
    result =
      Histogram.newCollector(name, help, labels, registry, "histogram", timestamp)
    result.buckets = bucketsSeq
    if labels.len == 0:
      result.metrics.add newHistogramMetrics(name, labels, labels, bucketsSeq)
      result.metricKeys[LabelKey.init(labels)] = result.metrics.high()

  proc observeHistogram(
      histogram: Histogram, amount: float64, labelValues: openArray[string]
  ) =
    let timestamp = histogram.now()
    withLabelValues(histogram, labelValues, valueSym):
      valueSym[0].value += amount # _sum
      valueSym[0].timestamp = timestamp
      valueSym[1].value += 1.float64 # _count
      valueSym[1].timestamp = timestamp
      for i, bucket in histogram.buckets:
        if amount.float64 <= bucket:
          #- "le" probably stands for "less or equal"
          #- the same observed value can increase multiple buckets, because this is
          #  a cumulative histogram
          valueSym[i + 3].value += 1.float64 # _bucket{le="<bucket value>"}
          valueSym[i + 3].timestamp = timestamp
    do:
      newHistogramMetrics(
        histogram.name, histogram.labels, labelValues, histogram.buckets
      )

template declareHistogram*(
    identifier: untyped,
    help: static string,
    labels: openArray[string] = [],
    registry = defaultRegistry,
    buckets: openArray[float64] = defaultHistogramBuckets,
    name = "",
    timestamp = false,
) {.dirty.} =
  when defined(metrics):
    let
      identifier =
        newHistogram(
          nameOrIdentifier(identifier, name), help, labels, registry, buckets, timestamp
        )
  else:
    type identifier = IgnoredCollector

template declarePublicHistogram*(
    identifier: untyped,
    help: static string,
    labels: openArray[string] = [],
    registry = defaultRegistry,
    buckets: openArray[float64] = defaultHistogramBuckets,
    name = "",
    timestamp = false,
) {.dirty.} =
  when defined(metrics):
    let
      identifier* =
        newHistogram(
          nameOrIdentifier(identifier, name), help, labels, registry, buckets, timestamp
        )
  else:
    type identifier* = IgnoredCollector

when defined(metrics):
  proc histogram*(
      name: static string
  ): Histogram {.raises: [ValueError, RegistrationError].} =
    let res {.global.} = newHistogram(name, "") # lifted line
    return res

else:
  template histogram*(name: static string): untyped =
    IgnoredCollector

# the "type IgnoredCollector" case is covered by Summary.observe()
template observe*(
    histogram: Histogram,
    amount: int64 | float64 = 1,
    labelValues: openArray[string] = [],
) =
  when defined(metrics):
    {.gcsafe.}:
      observeHistogram(histogram, amount.float64, labelValues)

#########################
# update system metrics #
#########################

when defined(metrics):
  const metrics_max_hooks = 16
  type ThreadMetricsUpdateProc = proc() {.gcsafe, nimcall, raises: [].}
  let mainThreadID = getThreadId()
  var
    threadMetricsUpdateProcs: array[metrics_max_hooks, ThreadMetricsUpdateProc]
    threadMetricsUpdateProcsIndex = 0
    systemMetricsUpdateInterval = initDuration(seconds = 10)
    systemMetricsLastUpdated = getMonoTime()

  proc getSystemMetricsUpdateInterval*(): Duration =
    return systemMetricsUpdateInterval

  proc setSystemMetricsUpdateInterval*(value: Duration) =
    systemMetricsUpdateInterval = value

  proc updateThreadMetrics*() {.gcsafe.} =
    for i in 0..<threadMetricsUpdateProcsIndex:
      threadMetricsUpdateProcs[i]()

  # No longer used for all system metrics, which now are custom collectors, but
  # still used for main-thread metrics.
  proc updateSystemMetrics*() {.gcsafe.} =
    if systemMetricsAutomaticUpdate:
      # Update system metrics if at least systemMetricsUpdateInterval seconds
      # have passed and if we are being called from the main thread.
      if getThreadId() == mainThreadID:
        let currTime = getMonoTime()
        if currTime >= (systemMetricsLastUpdated + systemMetricsUpdateInterval):
          systemMetricsLastUpdated = currTime
          # Update thread metrics, only when automation is on and we're in the
          # main thread.
          updateThreadMetrics()

################
# process info #
################

when defined(metrics) and defined(linux):
  from posix import sysconf, SC_CLK_TCK, SC_PAGESIZE
  var
    btime {.global.}: float64 = 0
    ticks {.global.}: float64 # clock ticks per second
    pagesize {.global.}: float64 # page size in bytes

  if btime == 0:
    try:
      for line in lines("/proc/stat"):
        if line.startsWith("btime"):
          btime = line.split(' ')[1].parseFloat()
    except IOError:
      # /proc not mounted?
      discard
    ticks = sysconf(SC_CLK_TCK).float64
    pagesize = sysconf(SC_PAGESIZE).float64

  type ProcessInfo = ref object of Gauge
  var
    processInfo* {.global.} =
      ProcessInfo.newCollector("process_info", "CPU and memory usage")

  method collect*(collector: ProcessInfo, output: MetricHandler) =
    let timestamp = collector.now()

    try:
      if btime == 0:
        # we couldn't access /proc
        return

      # the content of /proc/self/stat looks like this (the command name may contain spaces):
      #
      # $ cat /proc/self/stat
      # 30494 (cat) R 3022 30494 3022 34830 30494 4210688 98 0 0 0 0 0 0 0 20 0 1 0 73800491 10379264 189 18446744073709551615 94060049248256 94060049282149 140735229395104 0 0 0 0 0 0 0 0 0 17 6 0 0 0 0 0 94060049300560 94060049302112 94060076990464 140735229397011 140735229397031 140735229397031 140735229403119 0
      let selfStat = readFile("/proc/self/stat").split(") ")[^1].split(' ')
      output(
        name = "process_virtual_memory_bytes", # Virtual memory size in bytes.
        value = selfStat[20].parseFloat(),
        timestamp = timestamp,
      )

      output(
        name = "process_resident_memory_bytes", # Resident memory size in bytes.
        value = selfStat[21].parseFloat() * pagesize,
        timestamp = timestamp,
      )
      output(
        name = "process_start_time_seconds",
          # Start time of the process since unix epoch in seconds.
        value = selfStat[19].parseFloat() / ticks + btime,
        timestamp = timestamp,
      )
      output(
        name = "process_cpu_seconds_total",
          # Total user and system CPU time spent in seconds.
        value = (selfStat[11].parseFloat() + selfStat[12].parseFloat()) / ticks,
        timestamp = timestamp,
      )

      for line in lines("/proc/self/limits"):
        if line.startsWith("Max open files"):
          output(
            name = "process_max_fds", # Maximum number of open file descriptors.
            value = line.splitWhitespace()[3].parseFloat(),
              # a simple `split()` does not combine adjacent whitespace
            timestamp = timestamp,
          )
          break

      output(
        name = "process_open_fds", # Number of open file descriptors.
        value = toSeq(walkDir("/proc/self/fd")).len.float64,
        timestamp = timestamp,
      )
    except CatchableError as e:
      printError(e.msg)

####################
# Nim runtime info #
####################

when defined(metrics):
  type NimRuntimeInfo = ref object of Collector
  let
    nimRuntimeInfo* {.global.} =
      NimRuntimeInfo.newCollector("nim_runtime_info", "Nim runtime info")

  method collect*(collector: NimRuntimeInfo, output: MetricHandler) =
    let timestamp = collector.now()
    try:
      when defined(nimTypeNames) and declared(dumpHeapInstances):
        # Too high cardinality causes performance issues in Prometheus.
        const labelsLimit = 10
        var
          # Higher size than in the loop for adding metrics
          # to avoid missing same name metrics far apart with low values.
          heapSizes: array[100, (cstring, int)]
          counter: int
          heapSum: int # total size of all instances
        for data in dumpHeapInstances():
          counter += 1
          heapSum += data.sizes
          var smallest = 0
          var dedupe = false
          for i in 0..<heapSizes.len:
            if heapSizes[i][0] == data.name:
              heapSizes[i][1] += data.sizes
              dedupe = true
              break
            if heapSizes[smallest][1] >= heapSizes[i][1]:
              smallest = i
          if not dedupe and data.sizes > heapSizes[smallest][1]:
            heapSizes[smallest] = (data.name, data.sizes)
        sort(
          heapSizes,
          proc(a, b: auto): auto =
              b[1] - a[1]
            ,
        )
        # Lower the number of metrics to reduce metric cardinality.
        for i in 0..<labelsLimit:
          let (typeName, size) = heapSizes[i]
          output(
            name = "nim_gc_heap_instance_occupied_bytes",
              # total bytes occupied, by instance type (all threads)
            value = size.float64,
            timestamp = timestamp,
            labels = ["type_name"],
            labelValues = [$typeName],
          )

        output(
          name = "nim_gc_heap_instance_occupied_summed_bytes",
            # total bytes occupied by all instance types, in all threads - should be equal to 'sum(nim_gc_mem_occupied_bytes)' when 'updateThreadMetrics()' is being called in all threads, but it's somewhat smaller
          value = heapSum.float64,
          timestamp = timestamp,
        )
    except CatchableError as e:
      printError(e.msg)

  declareGauge nim_gc_mem_bytes,
    "the number of bytes that are owned by a thread's GC", ["thread_id"]
  declareGauge nim_gc_mem_occupied_bytes,
    "the number of bytes that are owned by a thread's GC and hold data", ["thread_id"]

  proc updateNimRuntimeInfoThread() =
    try:
      let threadID = getThreadId()

      when declared(getTotalMem):
        nim_gc_mem_bytes.set(
          getTotalMem().float64,
          labelValues = @[$threadID],
          doUpdateSystemMetrics = false,
        )

      when declared(getOccupiedMem):
        nim_gc_mem_occupied_bytes.set(
          getOccupiedMem().float64,
          labelValues = @[$threadID],
          doUpdateSystemMetrics = false,
        )

        # TODO: parse the output of `GC_getStatistics()` for more stats
    except CatchableError as e:
      printError(e.msg)

  if threadMetricsUpdateProcsIndex < threadMetricsUpdateProcs.len:
    threadMetricsUpdateProcs[threadMetricsUpdateProcsIndex] = updateNimRuntimeInfoThread
    threadMetricsUpdateProcsIndex += 1
