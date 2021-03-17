# Copyright (c) 2019-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0: http://www.apache.org/licenses/LICENSE-2.0
# at your option. This file may not be copied, modified, or distributed except according to those terms.

when defined(posix):
  import os, posix

proc printError*(msg: string) =
  try:
    writeLine(stderr, "metrics error: " & msg)
  except IOError:
    discard

proc ignoreSignalsInThread*() =
  # Block all signals in this thread, so we don't interfere with regular signal
  # handling elsewhere.
  when defined(posix):
    var signalMask, oldSignalMask: Sigset

    # sigprocmask() doesn't work on macOS, for multithreaded programs
    if sigfillset(signalMask) != 0:
      echo osErrorMsg(osLastError())
      quit(QuitFailure)
    when defined(boehmgc):
      # https://www.hboehm.info/gc/debugging.html
      const
        SIGPWR = 30
        SIGXCPU = 24
        SIGSEGV = 11
        SIGBUS = 7
      if sigdelset(signalMask, SIGPWR) != 0 or
        sigdelset(signalMask, SIGXCPU) != 0 or
        sigdelset(signalMask, SIGSEGV) != 0 or
        sigdelset(signalMask, SIGBUS) != 0:
        echo osErrorMsg(osLastError())
        quit(QuitFailure)
    if pthread_sigmask(SIG_BLOCK, signalMask, oldSignalMask) != 0:
      echo osErrorMsg(osLastError())
      quit(QuitFailure)
