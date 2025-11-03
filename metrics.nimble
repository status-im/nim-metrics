mode = ScriptMode.Verbose

packageName = "metrics"
version = "0.2.0"
author = "Status Research & Development GmbH"
description = "Metrics client library supporting Prometheus"
license = "MIT or Apache License 2.0"
skipDirs = @["tests", "benchmarks"]

### Dependencies
requires "nim >= 1.6.14", "chronos >= 4.0.3", "results", "stew"

let nimc = getEnv("NIMC", "nim") # Which nim compiler to use
let lang = getEnv("NIMLANG", "c") # Which backend (c/cpp/js)
let flags = getEnv("NIMFLAGS", "") # Extra flags for the compiler
let verbose = getEnv("V", "") notin ["", "0"]

from os import quoteShell

let cfg =
  " --styleCheck:usages --styleCheck:error" &
  (if verbose: "" else: " --verbosity:0 --hints:off") &
  " --skipParentCfg --skipUserCfg --outdir:build " &
  quoteShell("--nimcache:build/nimcache/$projectName") & " -d:metricsTest"

proc build(args, path: string) =
  exec nimc & " " & lang & " " & cfg & " " & flags & " " & args & " " & path

proc run(args, path: string) =
  build args & " --mm:refc -r", path
  if (NimMajor, NimMinor) > (1, 6):
    build args & " --mm:orc -r", path

### tasks
task test, "Main tests":
  # build it with metrics disabled, first
  build "", "tests/main_tests"
  build "--threads:on", "tests/main_tests"
  run "-d:metrics --threads:on -d:useSysAssert -d:useGcAssert", "tests/main_tests"

  build "", "benchmarks/bench_collectors"
  run "-d:metrics --threads:on", "benchmarks/bench_collectors"

  run "", "tests/chronos_server_tests"
  run "-d:metrics --threads:on -d:nimTypeNames", "tests/chronos_server_tests"

when (NimMajor, NimMinor) < (2, 0):
  taskRequires "test_chronicles", "chronicles < 0.12"

task test_chronicles, "Chronicles tests":
  build "", "tests/chronicles_tests"
  run "-d:metrics --threads:on", "tests/chronicles_tests"

task benchmark, "Run benchmarks":
  run "-d:metrics --debuginfo --threads:on -d:release", "benchmarks/bench_collectors"
