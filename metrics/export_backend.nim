#######################################
# export metrics to StatsD and Carbon #
#######################################

when defined(metrics):
  import std/[locks, net, os, random, times, strutils]

  import ../metrics, ./common

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
    lastConnectionTime: seq[times.Time] = @[]
        # last time we tried to connect the corresponding socket

  initLock(exportBackendsLock)

  proc exportMetrics(
      name: string,
      value: float64,
      increment = 0.float64,
      metricType: string,
      timestamp: Time,
      sampleRate = 1.float,
  ) {.gcsafe, raises: [].} =
    # this may run from different threads
    when defined(nimHasWarnBareExcept):
      {.push warning[BareExcept]: off.}

    # Send a new metric to the thread handling the networking.
    # Silently drop it if the channel's buffer is full.
    try:
      discard exportChan.trySend(
          ExportedMetric(
            name: name,
            value: value,
            increment: increment,
            metricType: metricType,
            timestamp: timestamp.toMilliseconds(),
            sampleRate: sampleRate,
          )
        )
    except Exception as e:
      printError(e.msg)

    when defined(nimHasWarnBareExcept):
      {.pop.}

  # connect or reconnect the socket at position i in `sockets`
  proc reconnectSocket(i: int, backend: ExportBackend) {.raises: [OSError].} =
    # Throttle it.
    # We don't expect enough backends to worry about the thundering herd problem.
    if getTime() - lastConnectionTime[i] < RECONNECT_INTERVAL:
      sleep(100)
        # silly optimisation for an artificial benchmark where we try to
        # export as many metric updates as possible with a missing backend
      return

    when defined(nimHasWarnBareExcept):
      {.push warning[BareExcept]: off.}

    # try to close any existing socket, first
    if sockets[i] != nil:
      try:
        sockets[i].close()
      except:
        discard
      sockets[i] = nil # we use this as a flag to avoid sends without a connection

    # create a new socket
    case backend.netProtocol
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

    when defined(nimHasWarnBareExcept):
      {.pop.}

  proc pushMetricsWorker() {.thread.} =
    ignoreSignalsInThread()

    var
      data: ExportedMetric # received from the channel
      payload: string
      finalValue: float64
      sampleString: string

    # seed the simple PRNG we're using for sample rates
    randomize()

    when defined(nimHasWarnBareExcept):
      {.push warning[BareExcept]: off.}

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
              case backend.metricProtocol
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
                payload =
                  "$#:$#|$#$#\n" % [
                    data.name, $finalValue, data.metricType, sampleString
                  ]
              of CARBON:
                # Carbon wants a 32-bit timestamp in seconds.
                payload =
                  "$# $# $#\n" % [
                    data.name, $data.value, $(data.timestamp div 1000).int32
                  ]

              if sockets[i] == nil:
                reconnectSocket(i, backend)
                if sockets[i] == nil:
                  # we're in the waiting period
                  continue

              try:
                sockets[i].send(payload, flags = {})
                  # the default flags would not raise an exception on a broken connection
              except OSError:
                reconnectSocket(i, backend)
    except Exception as e: # std lib raises lots of these
      printError(e.msg)

    when defined(nimHasWarnBareExcept):
      {.pop.}

  proc addExportBackend*(
      metricProtocol: MetricProtocol,
      netProtocol: NetProtocol,
      address: string,
      port: Port,
  ) =
    withLock(exportBackendsLock):
      exportBackends.add(
        ExportBackend(
          metricProtocol: metricProtocol,
          netProtocol: netProtocol,
          address: address,
          port: port,
        )
      )
      if exportBackends.len == 1:
        metricsExportHook = exportMetrics
        exportChan.open(maxItems = METRIC_EXPORT_BUFER_SIZE)
        exportThread.createThread(pushMetricsWorker)

else:
  # Importing the backend has side effects - avoid warning when compiling
  # without metrics
  {.used.}
