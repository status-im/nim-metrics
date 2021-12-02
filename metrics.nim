# Copyright (c) 2019-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0: http://www.apache.org/licenses/LICENSE-2.0
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Exceptions coming out of this library are mostly handled but, due to bugs
# in Nim exception tracking and deficiencies in the standard library, not quite
# all exceptions can be tracked.
#
# When we do manage to catch an unexpected exception, we'll do one of several
# things:
# * Try to print the message to stderr
# * Raise a tracked exception - we use this strategy during collector
#   registration

{.push raises: [Defect].} # Disabled further down for some parts of the code

import locks, net, os, sets, tables, times
when defined(metrics):
  import algorithm, hashes, random, sequtils, strutils,
    metrics/common
  when defined(posix):
    import posix

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
    lock*: Lock
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

  RegistrationError* = object of CatchableError

const CONTENT_TYPE* = "text/plain; version=0.0.4; charset=utf-8"

#########
# utils #
#########

when defined(metrics):
  proc toMilliseconds*(time: times.Time): int64 =
    return convert(Seconds, Milliseconds, time.toUnix()) + convert(Nanoseconds, Milliseconds, time.nanosecond())

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
        try:
          textLabels.add("$#=\"$#\"" % [metric.labels[i], metric.labelValues[i].processLabelValue()])
        except ValueError as e:
          printError(e.msg)
      result.add(textLabels.join(","))
      result.add('}')
    result.add(" " & $metric.value)
    if showTimestamp and metric.timestamp > 0:
      result.add(" " & $metric.timestamp)

  proc `$`*(metric: Metric): string =
    metric.toText()

  const
    nameRegexStr = r"^[a-zA-Z_:][a-zA-Z0-9_:]*$"
    labelRegexStr = r"^[a-zA-Z_][a-zA-Z0-9_]*$"

  when not defined(withoutPCRE):
    import re

    let
      nameRegex {.global.} = re(nameRegexStr)
      labelRegex {.global.} = re(labelRegexStr)

    template validName(name): bool =
      name.contains(nameRegex)

    template validLabel(label): bool =
      label.contains(labelRegex)
  else:
    const
      labelStartChars = {'a'..'z', 'A'..'Z', '_'}
      labelChars = labelStartChars + {'0'..'9'}
      nameStartChars = labelStartChars + {':'}
      nameChars = labelChars + {':'}

    template validate(ident, startChars, chars): bool =
      ident.len > 0 and ident[0] in startChars and @ident.allIt(it in chars)

    template validName(name): bool =
      validate(name, nameStartChars, nameChars)

    template validLabel(label): bool =
      validate(label, labelStartChars, labelChars)

  proc validateName*(name: string) {.raises: [Defect, ValueError].} =
    if not validName(name):
      raise newException(ValueError, "Invalid name: '" & name & "'. It should match the regex: " & nameRegexStr)

  proc validateLabels(labels: LabelsParam, invalidLabelNames: openArray[string] = []) {.raises: [Defect, ValueError].} =
    for label in labels:
      if not validLabel(label):
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

  proc validateLabelValues*(collector: Collector, labelValues: LabelsParam): Labels {.raises: [Defect, ValueError].} =
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

  # Hash-based data types like OrderedSet don't just compare hashes to determine
  # if a key is present, but also compare the keys themselves, so we need to
  # override the `==` operator.
  method `==`*(x, y: Collector): bool {.base.} =
    x.name == y.name and x.labels == y.labels

  method collect*(collector: Collector): Metrics {.base.} =
    return collector.metrics

  proc toTextLines*(collector: Collector, metricsTable: Metrics, showTimestamp = true): seq[string] =
    try:
      result = @[
        "# HELP $# $#" % [collector.name, collector.help.processHelp()],
        "# TYPE $# $#" % [collector.name, collector.typ],
      ]
      for labelValues, metrics in metricsTable:
        for metric in metrics:
          result.add(metric.toText(showTimestamp))
    except ValueError as e:
      printError(e.msg)
      result = @[""]

  proc toText*(collector: Collector, showTimestamp = true): string =
    collector.toTextLines(collector.metrics, showTimestamp).join("\n")

  proc `$`*(collector: Collector): string =
    collector.toText()

proc `$`*(collector: type IgnoredCollector): string = ""

# for testing
template value*(collector: Collector | type IgnoredCollector, labelValues: LabelsParam = @[]): float64 =
  when defined(metrics) and collector is not IgnoredCollector:
    {.gcsafe.}:
      collector.metrics[@labelValues][0].value
  else:
    0.0

# for testing
proc valueByName*(collector: Collector | type IgnoredCollector,
                  metricName: string,
                  labelValues: LabelsParam = @[],
                  extraLabelValues: LabelsParam = @[]): float64 {.raises: [Defect, ValueError].} =
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

# needs to be {.global.} because of the alternative API's usage of {.global.} collector vars
var defaultRegistry* {.global.} = newRegistry()

# We use a generic type here in order to avoid the hidden type casting of
# Collector child types to the parent type.
proc register* [T] (collector: T, registry = defaultRegistry) {.raises: [Defect, RegistrationError].} =
  when defined(metrics):
    withLock registry.lock:
      if collector in registry.collectors:
        raise newException(RegistrationError, "Collector already registered: " & collector.name)

      registry.collectors.incl(collector)

proc unregister* [T] (collector: T, registry = defaultRegistry) {.raises: [Defect, RegistrationError].} =
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
        withLock collector.lock:
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

  proc updateSystemMetrics*() {.gcsafe.} # defined later in this file
  var systemMetricsAutomaticUpdate = true # whether to piggy-back on changes of user-defined metrics

  proc getSystemMetricsAutomaticUpdate*(): bool =
    return systemMetricsAutomaticUpdate

  proc setSystemMetricsAutomaticUpdate*(value: bool) =
    systemMetricsAutomaticUpdate = value

  proc pushMetrics*(name: string, value: float64, increment = 0.float64, metricType: string,
    timestamp: int64, sampleRate = 1.float, doUpdateSystemMetrics = true) {.raises: [Defect].} =
    # this may run from different threads

    if systemMetricsAutomaticUpdate and doUpdateSystemMetrics:
      updateSystemMetrics()

    if len(exportBackends) == 0:
      # no backends configured
      return

    # Send a new metric to the thread handling the networking.
    # Silently drop it if the channel's buffer is full.
    try:
      discard exportChan.trySend(ExportedMetric(
                                  name: name,
                                  value: value,
                                  increment: increment,
                                  metricType: metricType,
                                  timestamp: timestamp,
                                  sampleRate: sampleRate
                                ))
    except Exception as e:
      printError(e.msg)

  # connect or reconnect the socket at position i in `sockets`
  proc reconnectSocket(i: int, backend: ExportBackend) {.raises: [Defect, OSError].} =
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
    ignoreSignalsInThread()

    var
      data: ExportedMetric # received from the channel
      payload: string
      finalValue: float64
      sampleString: string

    # seed the simple PRNG we're using for sample rates
    randomize()

    # No custom cleanup needed here, so let this thread be killed, the sockets
    # closed, etc., by the OS.
    try:
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
              except OSError:
                reconnectSocket(i, backend)
    except Exception as e: # std lib raises lots of these
      printError(e.msg)

  exportThread.createThread(pushMetricsWorker)

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

  proc validateCounterLabelValues(counter: Counter, labelValues: LabelsParam): Labels {.raises: [Defect, ValueError].} =
    result = validateLabelValues(counter, labelValues)
    if result notin counter.metrics:
      counter.metrics[result] = newCounterMetrics(counter.name, counter.labels, result)

  # don't document this one, even if we're forced to make it public, because it
  # won't work when all (or some) collectors are disabled
  proc newCounter*(name: string, help: string, labels: LabelsParam = @[], registry = defaultRegistry, sampleRate = 1.float): Counter  {.raises: [Defect, ValueError, RegistrationError].} =
    validateName(name)
    validateLabels(labels)
    result = Counter(name: name,
                    help: help,
                    typ: "counter",
                    labels: @labels,
                    metrics: initOrderedTable[Labels, seq[Metric]](),
                    creationThreadId: getThreadId(),
                    sampleRate: sampleRate)
    result.lock.initLock()
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
  proc counter*(name: static string): Counter {.raises: [Defect, ValueError, RegistrationError].} =
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
    try:
      var timestamp = getTime().toMilliseconds()

      if amount < 0:
        raise newException(ValueError, "Counter.inc() cannot be used with negative amounts.")

      withLock counter.lock:
        let labelValuesCopy = validateCounterLabelValues(counter, labelValues)
        counter.metrics[labelValuesCopy][0].value += amount.float64
        counter.metrics[labelValuesCopy][0].timestamp = timestamp
        pushMetrics(name = counter.name,
                    value = counter.metrics[labelValuesCopy][0].value,
                    increment = amount.float64,
                    metricType = "c",
                    timestamp = timestamp,
                    sampleRate = counter.sampleRate)
    except Exception as e:
      printError(e.msg)

template inc*(counter: Counter | type IgnoredCollector, amount: int64|float64 = 1, labelValues: LabelsParam = @[]) =
  when defined(metrics) and counter is not IgnoredCollector:
    {.gcsafe.}: incCounter(counter, amount, labelValues)

template countExceptions*(counter: Counter | type IgnoredCollector, typ: typedesc, labelValues: LabelsParam, body: untyped) =
  when defined(metrics) and counter is not IgnoredCollector:
    try:
      body
    except typ as exc:
      counter.inc(1, labelValues)
      raise exc
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

  proc validateGaugeLabelValues(gauge: Gauge, labelValues: LabelsParam): Labels  {.raises: [Defect, ValueError].} =
    result = validateLabelValues(gauge, labelValues)
    if result notin gauge.metrics:
      gauge.metrics[result] = newGaugeMetrics(gauge.name, gauge.labels, result)

  proc newGauge*(name: string, help: string, labels: LabelsParam = @[], registry = defaultRegistry): Gauge {.raises: [Defect, ValueError, RegistrationError].} =
    validateName(name)
    validateLabels(labels)
    result = Gauge(name: name,
                  help: help,
                  typ: "gauge",
                  labels: @labels,
                  metrics: initOrderedTable[Labels, seq[Metric]](),
                  creationThreadId: getThreadId())
    result.lock.initLock()
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
  proc gauge*(name: static string): Gauge {.raises: [Defect, ValueError, RegistrationError].} =
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
    try:
      var timestamp = getTime().toMilliseconds()

      withLock gauge.lock:
        let labelValuesCopy = validateGaugeLabelValues(gauge, labelValues)
        gauge.metrics[labelValuesCopy][0].value += amount.float64
        gauge.metrics[labelValuesCopy][0].timestamp = timestamp
        pushMetrics(name = gauge.name,
                    value = gauge.metrics[labelValuesCopy][0].value,
                    metricType = "g",
                    timestamp = timestamp)
    except Exception as e:
      printError(e.msg)

proc decGauge(gauge: Gauge, amount: int64|float64 = 1, labelValues: LabelsParam = @[]) =
  when defined(metrics):
    gauge.inc((-amount).float64, labelValues)

proc setGauge(gauge: Gauge, value: int64|float64, labelValues: LabelsParam = @[], doUpdateSystemMetrics: bool) =
  when defined(metrics):
    try:
      var timestamp = getTime().toMilliseconds()

      withLock gauge.lock:
        let labelValuesCopy = validateGaugeLabelValues(gauge, labelValues)
        gauge.metrics[labelValuesCopy][0].value = value.float64
        gauge.metrics[labelValuesCopy][0].timestamp = timestamp
        pushMetrics(name = gauge.name,
                    value = value.float64,
                    metricType = "g",
                    timestamp = timestamp,
                    doUpdateSystemMetrics = doUpdateSystemMetrics)
    except Exception as e:
      printError(e.msg)

# the "type IgnoredCollector" case is covered by Counter.inc()
template inc*(gauge: Gauge, amount: int64|float64 = 1, labelValues: LabelsParam = @[]) =
  when defined(metrics):
    {.gcsafe.}: incGauge(gauge, amount, labelValues)

template dec*(gauge: Gauge | type IgnoredCollector, amount: int64|float64 = 1, labelValues: LabelsParam = @[]) =
  when defined(metrics) and gauge is not IgnoredCollector:
    {.gcsafe.}: decGauge(gauge, amount, labelValues)

template set*(gauge: Gauge | type IgnoredCollector, value: int64|float64, labelValues: LabelsParam = @[], doUpdateSystemMetrics = true) =
  when defined(metrics) and gauge is not IgnoredCollector:
    {.gcsafe.}: setGauge(gauge, value, labelValues, doUpdateSystemMetrics)

# in seconds
proc setToCurrentTime*(gauge: Gauge | type IgnoredCollector, labelValues: LabelsParam = @[]) =
  when defined(metrics) and gauge is not IgnoredCollector:
    gauge.set(getTime().toUnix(), labelValues)

template trackInProgress*(gauge: Gauge | type IgnoredCollector, labelValues: LabelsParam, body: untyped) =
  when defined(metrics) and gauge is not IgnoredCollector:
    gauge.inc(1, labelValues)
    body
    gauge.dec(1, labelValues)
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
    gauge.set(times.toUnix(getTime()) - start, labelValues)
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

  proc validateSummaryLabelValues(summary: Summary, labelValues: LabelsParam): Labels {.raises: [Defect, ValueError].} =
    result = validateLabelValues(summary, labelValues)
    if result notin summary.metrics:
      summary.metrics[result] = newSummaryMetrics(summary.name, summary.labels, result)

  proc newSummary*(name: string, help: string, labels: LabelsParam = @[], registry = defaultRegistry): Summary {.raises: [Defect, ValueError, RegistrationError].} =
    validateName(name)
    validateLabels(labels, invalidLabelNames = ["quantile"])
    result = Summary(name: name,
                    help: help,
                    typ: "summary",
                    labels: @labels,
                    metrics: initOrderedTable[Labels, seq[Metric]](),
                    creationThreadId: getThreadId())
    result.lock.initLock()
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
  proc summary*(name: static string): Summary {.raises: [Defect, ValueError, RegistrationError].} =
    var res {.global.} = newSummary(name, "") # lifted line
    return res
else:
  template summary*(name: static string): untyped =
    IgnoredCollector

proc observeSummary(summary: Summary, amount: int64|float64, labelValues: LabelsParam = @[]) =
  when defined(metrics):
    try:
      var timestamp = getTime().toMilliseconds()

      withLock summary.lock:
        let labelValuesCopy = validateSummaryLabelValues(summary, labelValues)
        summary.metrics[labelValuesCopy][0].value += amount.float64 # _sum
        summary.metrics[labelValuesCopy][0].timestamp = timestamp
        summary.metrics[labelValuesCopy][1].value += 1.float64 # _count
        summary.metrics[labelValuesCopy][1].timestamp = timestamp
    except Exception as e:
      printError(e.msg)

template observe*(summary: Summary | type IgnoredCollector, amount: int64|float64 = 1, labelValues: LabelsParam = @[]) =
  when defined(metrics) and summary is not IgnoredCollector:
    {.gcsafe.}: observeSummary(summary, amount, labelValues)

# in seconds
# the "type IgnoredCollector" case and the version without labels are covered by Gauge.time()
template time*(collector: Summary | Histogram, labelValues: LabelsParam, body: untyped) =
  when defined(metrics):
    let start = times.toUnix(getTime())
    body
    collector.observe(times.toUnix(getTime()) - start, labelValues)
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

  proc validateHistogramLabelValues(histogram: Histogram, labelValues: LabelsParam): Labels {.raises: [Defect, ValueError].} =
    result = validateLabelValues(histogram, labelValues)
    if result notin histogram.metrics:
      histogram.metrics[result] = newHistogramMetrics(histogram.name, histogram.labels, result, histogram.buckets)

  proc newHistogram*(name: string,
                    help: string,
                    labels: LabelsParam = @[],
                    registry = defaultRegistry,
                    buckets: openArray[float64] = defaultHistogramBuckets): Histogram {.raises: [Defect, ValueError, RegistrationError].} =
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
    result.lock.initLock()
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
  proc histogram*(name: static string): Histogram {.raises: [Defect, ValueError, RegistrationError].} =
    var res {.global.} = newHistogram(name, "") # lifted line
    return res
else:
  template histogram*(name: static string): untyped =
    IgnoredCollector

proc observeHistogram(histogram: Histogram, amount: int64|float64, labelValues: LabelsParam = @[]) =
  when defined(metrics):
    try:
      var timestamp = getTime().toMilliseconds()

      withLock histogram.lock:
        let labelValuesCopy = validateHistogramLabelValues(histogram, labelValues)
        histogram.metrics[labelValuesCopy][0].value += amount.float64 # _sum
        histogram.metrics[labelValuesCopy][0].timestamp = timestamp
        histogram.metrics[labelValuesCopy][1].value += 1.float64 # _count
        histogram.metrics[labelValuesCopy][1].timestamp = timestamp
        for i, bucket in histogram.buckets:
          if amount.float64 <= bucket:
            #- "le" probably stands for "less or equal"
            #- the same observed value can increase multiple buckets, because this is
            #  a cumulative histogram
            histogram.metrics[labelValuesCopy][i + 3].value += 1.float64 # _bucket{le="<bucket value>"}
            histogram.metrics[labelValuesCopy][i + 3].timestamp = timestamp
    except Exception as e:
      printError(e.msg)

# the "type IgnoredCollector" case is covered by Summary.observe()
template observe*(histogram: Histogram, amount: int64|float64 = 1, labelValues: LabelsParam = @[]) =
  when defined(metrics):
    {.gcsafe.}: observeHistogram(histogram, amount, labelValues)

#########################
# update system metrics #
#########################

when defined(metrics):
  const metrics_max_hooks = 16
  type
    SystemMetricsUpdateProc = proc() {.gcsafe, nimcall.}
    ThreadMetricsUpdateProc = proc() {.gcsafe, nimcall.}
  let mainThreadID = getThreadId()
  var
    systemMetricsUpdateProcs: array[metrics_max_hooks, SystemMetricsUpdateProc]
    systemMetricsUpdateProcsIndex = 0
    threadMetricsUpdateProcs: array[metrics_max_hooks, ThreadMetricsUpdateProc]
    threadMetricsUpdateProcsIndex = 0
    systemMetricsUpdateInterval = initDuration(seconds = 10)
    systemMetricsLastUpdated = now()

  proc getSystemMetricsUpdateInterval*(): Duration =
    return systemMetricsUpdateInterval

  proc setSystemMetricsUpdateInterval*(value: Duration) =
    systemMetricsUpdateInterval = value

  proc updateThreadMetrics*() {.gcsafe.} =
    for i in 0 ..< threadMetricsUpdateProcsIndex:
      try:
        threadMetricsUpdateProcs[i]()
      except CatchableError as e:
        printError(e.msg)
      except Exception as e:
        raise newException(Defect, e.msg)

  proc updateSystemMetrics*() {.gcsafe.} =
    var doUpdate = false

    if systemMetricsAutomaticUpdate:
      # Update system metrics if at least systemMetricsUpdateInterval seconds
      # have passed and if we are being called from the main thread.
      if getThreadId() == mainThreadID:
        let currTime = now()
        if currTime >= (systemMetricsLastUpdated + systemMetricsUpdateInterval):
          systemMetricsLastUpdated = currTime
          doUpdate = true
          # Update thread metrics, only when automation is on and we're in the
          # main thread.
          updateThreadMetrics()
    else:
      # We're being called directly by the API user, so don't introduce any conditions.
      doUpdate = true

    if doUpdate:
      for i in 0 ..< systemMetricsUpdateProcsIndex:
        try:
          systemMetricsUpdateProcs[i]()
        except CatchableError as e:
          printError(e.msg)
        except Exception as e:
          raise newException(Defect, e.msg)

################
# process info #
################

when defined(metrics) and defined(linux):
  import posix

  declareGauge process_virtual_memory_bytes, "virtual memory size in bytes"
  declareGauge process_resident_memory_bytes, "resident memory size in bytes"
  declareGauge process_start_time_seconds, "start time of the process since unix epoch in seconds"
  declareGauge process_cpu_seconds_total, "total user and system CPU time spent in seconds"
  declareGauge process_max_fds, "maximum number of open file descriptors"
  declareGauge process_open_fds, "number of open file descriptors"

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
    pagesize = sysconf(SC_PAGE_SIZE).float64

  proc updateProcessInfo() =
    try:
      if btime == 0:
        # we couldn't access /proc
        return

      # the content of /proc/self/stat looks like this (the command name may contain spaces):
      #
      # $ cat /proc/self/stat
      # 30494 (cat) R 3022 30494 3022 34830 30494 4210688 98 0 0 0 0 0 0 0 20 0 1 0 73800491 10379264 189 18446744073709551615 94060049248256 94060049282149 140735229395104 0 0 0 0 0 0 0 0 0 17 6 0 0 0 0 0 94060049300560 94060049302112 94060076990464 140735229397011 140735229397031 140735229397031 140735229403119 0
      let selfStat = readFile("/proc/self/stat").split(") ")[^1].split(' ')

      process_virtual_memory_bytes.set(selfStat[20].parseFloat(), doUpdateSystemMetrics = false)
      process_resident_memory_bytes.set(selfStat[21].parseFloat() * pagesize, doUpdateSystemMetrics = false)
      process_start_time_seconds.set(selfStat[19].parseFloat() / ticks + btime, doUpdateSystemMetrics = false)
      process_cpu_seconds_total.set((selfStat[11].parseFloat() + selfStat[12].parseFloat()) / ticks, doUpdateSystemMetrics = false)

      for line in lines("/proc/self/limits"):
        if line.startsWith("Max open files"):
          process_max_fds.set(line.splitWhiteSpace()[3].parseFloat(), doUpdateSystemMetrics = false) # a simple `split()` does not combine adjacent whitespace
          break

      process_open_fds.set(toSeq(walkDir("/proc/self/fd")).len.float64, doUpdateSystemMetrics = false)
    except CatchableError as e:
      printError(e.msg)

  systemMetricsUpdateProcs[systemMetricsUpdateProcsIndex] = updateProcessInfo
  systemMetricsUpdateProcsIndex += 1

####################
# Nim runtime info #
####################

when defined(metrics):
  declareGauge nim_gc_mem_bytes, "the number of bytes that are owned by a thread's GC", ["thread_id"]
  declareGauge nim_gc_mem_occupied_bytes, "the number of bytes that are owned by a thread's GC and hold data", ["thread_id"]
  declareGauge nim_gc_heap_instance_occupied_bytes, "total bytes occupied, by instance type (all threads)", ["type_name"]
  declareGauge nim_gc_heap_instance_occupied_summed_bytes, "total bytes occupied by all instance types, in all threads - should be equal to 'sum(nim_gc_mem_occupied_bytes)' when 'updateThreadMetrics()' is being called in all threads, but it's somewhat smaller"

  proc updateNimRuntimeInfoGlobal() =
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
        sort(heapSizes, proc(a, b: auto): auto = b[1] - a[1])
        # Lower the number of metrics to reduce metric cardinality.
        for i in 0..<labelsLimit:
          let (typeName, size) = heapSizes[i]
          nim_gc_heap_instance_occupied_bytes.set(size.float64, labelValues = @[$typeName], doUpdateSystemMetrics = false)
        nim_gc_heap_instance_occupied_summed_bytes.set(heapSum.float64, doUpdateSystemMetrics = false)
    except CatchableError as e:
      printError(e.msg)

  systemMetricsUpdateProcs[systemMetricsUpdateProcsIndex] = updateNimRuntimeInfoGlobal
  systemMetricsUpdateProcsIndex += 1

  proc updateNimRuntimeInfoThread() =
    try:
      let threadID = getThreadId()

      when declared(getTotalMem):
        nim_gc_mem_bytes.set(getTotalMem().float64, labelValues = @[$threadID], doUpdateSystemMetrics = false)

      when declared(getOccupiedMem):
        nim_gc_mem_occupied_bytes.set(getOccupiedMem().float64, labelValues = @[$threadID], doUpdateSystemMetrics = false)

      # TODO: parse the output of `GC_getStatistics()` for more stats
    except CatchableError as e:
      printError(e.msg)

  threadMetricsUpdateProcs[threadMetricsUpdateProcsIndex] = updateNimRuntimeInfoThread
  threadMetricsUpdateProcsIndex += 1
