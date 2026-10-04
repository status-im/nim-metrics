mode = ScriptMode.Verbose

packageName   = "metrics"
version       = "0.2.3"
author        = "Status Research & Development GmbH"
description   = "Metrics client library supporting Prometheus"
license       = "MIT or Apache License 2.0"
skipDirs      = @["tests", "benchmarks"]

### Dependencies
requires "nim >= 1.6.18",
         "chronos >= 4.0.3",
         "results >= 0.5.0",
         "stew >= 0.5.2",
         "unittest2 >= 0.2.0"

let nimc = getEnv("NIMC", "nim") # Which nim compiler to use
let lang = getEnv("NIMLANG", "c") # Which backend (c/cpp/js)
let flags = getEnv("NIMFLAGS", "") # Extra flags for the compiler
let verbose = getEnv("V", "") notin ["", "0"]
let platform = getEnv("PLATFORM", "")
let testArguments = [
  "",
  "--threads:on",
  "-d:metrics --threads:on",
  "-d:metrics --threads:on -d:useSysAssert -d:useGcAssert",
  "-d:metrics --threads:on -d:nimTypeNames",
]

from std/os import quoteShell

let cfg =
  " --styleCheck:usages --styleCheck:error" &
  (if verbose: "" else: " --verbosity:0") &
  " --skipParentCfg --skipUserCfg --outdir:build -f " &
  quoteShell("--nimcache:build/nimcache/$projectName")

proc build(args, path: string) =
  exec nimc & " " & lang & " " & cfg & " " & flags & " " & args & " " & path

proc run(args, path: string) =
  build args & " -r", path

proc runTests(args: string) =
  # Metric values are only collected with `-d:metrics`
  if "-d:metrics" in args:
    run args, "tests/main_tests"
  else:
    build args, "tests/main_tests"
  run args, "benchmarks/bench_collectors"
  run args, "tests/chronos_server_tests"

task test, "Run all tests":
  for args in testArguments:
    runTests args & " --mm:refc"
    if (NimMajor, NimMinor) > (1, 6):
      runTests args & " --mm:orc"

task test_asan, "Run all tests with ASAN":
  if platform != "x86" and (NimMajor, NimMinor) >= (2, 2):
    try:
      exec "echo '#if __clang_major__ < 20\n#error\n#endif' | clang -E - >/dev/null"
    except OSError:
      return

    # https://clang.llvm.org/docs/AddressSanitizer.html
    putEnv("ASAN_OPTIONS", "detect_leaks=0:detect_stack_use_after_return=1")
    # https://clang.llvm.org/docs/UndefinedBehaviorSanitizer.html
    putEnv("UBSAN_OPTIONS", "print_stacktrace=1")
    let asanArgs =
      " --mm:orc -d:useMalloc --cc:clang --debugger:native" &
      " --passC:-fsanitize=address,undefined" &
      " --passL:-fsanitize=address,undefined" &
      " --passC:-fno-sanitize-recover=undefined" &
      " --passC:-fno-sanitize-merge" &
      " --passC:-fno-omit-frame-pointer"
    for args in testArguments:
      runTests args & asanArgs

when (NimMajor, NimMinor) < (2, 0):
  taskRequires "test_chronicles", "chronicles < 0.12"

task test_chronicles, "Run chronicles tests":
  for args in testArguments:
    run args & " --mm:refc", "tests/chronicles_tests"
    if (NimMajor, NimMinor) > (1, 6):
      run args & " --mm:orc", "tests/chronicles_tests"

task benchmark, "Run benchmarks":
  run "-d:metrics --debuginfo --threads:on -d:release --mm:refc",
    "benchmarks/bench_collectors"
  if (NimMajor, NimMinor) > (1, 6):
    run "-d:metrics --debuginfo --threads:on -d:release --mm:orc",
      "benchmarks/bench_collectors"
