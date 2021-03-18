# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0: http://www.apache.org/licenses/LICENSE-2.0
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import ../metrics, ../metrics/chronos_httpserver,
  os, osproc

startMetricsHttpServer()
sleep(1000)
when defined(metrics):
  doAssert execCmd("curl http://127.0.0.1:8000/metrics") == 0

