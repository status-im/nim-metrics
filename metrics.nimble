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

let nimc = getEnv("NIMC", "nim") # Which nim compiler to use
let lang = getEnv("NIMLANG", "c") # Which backend (c/cpp/js)
let flags = getEnv("NIMFLAGS", "") # Extra flags for the compiler
let verbose = getEnv("V", "") notin ["", "0"]

let styleCheckStyle = if (NimMajor, NimMinor) < (1, 6): "hint" else: "error"
let cfg =
  " --styleCheck:usages --styleCheck:" & styleCheckStyle &
  (if verbose: "" else: " --verbosity:0 --hints:off") &
  " --skipUserCfg --outdir:build --nimcache:build/nimcache -f"

proc build(args, path: string) =
  exec nimc & " " & lang & " " & cfg & " " & flags & " " & args & " " & path

proc run(args, path: string) =
  build args & " -r", path
  if (NimMajor, NimMinor) > (1, 6):
    build args & " --mm:refc -r", path

### tasks
task test, "Main tests":
  # build it with metrics disabled, first
  build "", "tests/main_tests"
  build "--threads:on", "tests/main_tests"
  run "-d:metrics --threads:on", "tests/main_tests"

  build "", "benchmarks/bench_collectors"
  run "-d:metrics --threads:on", "benchmarks/bench_collectors"

  run "", "tests/stdlib_server_tests"
  run "-d:metrics --threads:on", "tests/stdlib_server_tests"
  run "", "tests/chronos_server_tests"
  run "-d:metrics --threads:on", "tests/chronos_server_tests"

task test_chronicles, "Chronicles tests":
  build "", "tests/chronicles_tests"
  run "-d:metrics --threads:on", "tests/chronicles_tests"

task benchmark, "Run benchmarks":
  run "-d:metrics --threads:on -d:release", "benchmarks/bench_collectors"
