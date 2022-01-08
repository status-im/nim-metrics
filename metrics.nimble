mode = ScriptMode.Verbose

packageName   = "metrics"
version       = "0.0.1"
author        = "Status Research & Development GmbH"
description   = "Metrics client library supporting Prometheus"
license       = "MIT or Apache License 2.0"
skipDirs      = @["tests", "benchmarks"]

### Dependencies
requires "nim >= 1.2.0",
         "chronos >= 2.6.0"

### Helper functions
proc buildBinary(name: string, srcDir = "./", params = "") =
  if not dirExists "build":
    mkDir "build"
  var extra_params = params
  if paramStr(1) != "e":
    # we're under Nim, not Nimble
    for i in 2..<paramCount():
      extra_params &= " " & paramStr(i)
  exec "nim " & getEnv("TEST_LANG", "c") & " " & getEnv("NIMFLAGS") & " --out:./build/" & name & " -f --skipParentCfg --hints:off " & extra_params & " " & srcDir & name & ".nim"

### tasks
task test, "Main tests":
  # build it with metrics disabled, first
  buildBinary "main_tests", "tests/"
  buildBinary "main_tests", "tests/", "--threads:on"
  buildBinary "main_tests", "tests/", "-r -d:metrics --threads:on"
  buildBinary "bench_collectors", "benchmarks/"
  buildBinary "bench_collectors", "benchmarks/", "-r -d:metrics --threads:on"
  buildBinary "stdlib_server_tests", "tests/", "-r"
  buildBinary "stdlib_server_tests", "tests/", "-r -d:metrics --threads:on"
  buildBinary "chronos_server_tests", "tests/", "-r"
  buildBinary "chronos_server_tests", "tests/", "-r -d:metrics --threads:on"

task test_chronicles, "Chronicles tests":
  buildBinary "chronicles_tests", "tests/"
  buildBinary "chronicles_tests", "tests/", "-r -d:metrics --threads:on"

task benchmark, "Run benchmarks":
  buildBinary "bench_collectors", "benchmarks/", "-r -d:metrics --threads:on -d:release"

