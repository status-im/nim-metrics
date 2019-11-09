mode = ScriptMode.Verbose

packageName   = "metrics"
version       = "0.0.1"
author        = "Status Research & Development GmbH"
description   = "Metrics client library supporting Prometheus"
license       = "MIT or Apache License 2.0"
skipDirs      = @["tests", "benchmarks"]

### Dependencies
requires "nim >= 0.18.0"

### Helper functions
proc buildBinary(name: string, srcDir = "./", params = "", lang = "c") =
  if not dirExists "build":
    mkDir "build"
  var extra_params = params
  if paramStr(1) != "e":
    # we're under Nim, not Nimble
    for i in 2..<paramCount():
      extra_params &= " " & paramStr(i)
  exec "nim " & lang & " --out:./build/" & name & " -f --skipParentCfg " & extra_params & " " & srcDir & name & ".nim"

proc test(name: string) =
  buildBinary name, "tests/", "-r -d:metrics --threads:on"

proc bench(name: string) =
  buildBinary name, "benchmarks/", "-r -d:metrics --threads:on -d:release"

### tasks
task test, "Main tests":
  # build it with metrics disabled, first
  buildBinary "main_tests", "tests/"
  buildBinary "main_tests", "tests/", "--threads:on"
  test "main_tests"
  buildBinary "bench_collectors", "benchmarks/"
  buildBinary "bench_collectors", "benchmarks/", "-d:metrics --threads:on"

task test_chronicles, "Chronicles tests":
  buildBinary "chronicles_tests", "tests/"
  test "chronicles_tests"

task benchmark, "Run benchmarks":
  bench "bench_collectors"

