import
  ./bench_common, ../metrics

proc main(nb_samples: Natural) =
  warmup()

  bench("create a counter and increment it 3 times with different values", 0):
    declareCounter counter1, "help"
    counter1.inc()
    counter1.inc(2)
    counter1.inc(2.1)
    counter1.unregister()

  let labelValues = @["a", "b"]
  bench("create a counter with 2 labels and increment it 3 times with different values", 0):
    declareCounter counter2, "help", @["foo", "bar"]
    counter2.inc(labelValues = labelValues)
    counter2.inc(2, labelValues)
    counter2.inc(2.1, labelValues)
    counter2.unregister()

when isMainModule:
  main(10000)
