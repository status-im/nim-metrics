import
  ./bench_common, ../metrics

proc main(nb_samples: Natural) =
  warmup()

  var res: float64

  bench("create a counter and increment it 3 times with different values", res):
    declareCounter counter1, "help"
    counter1.inc()
    counter1.inc(2)
    counter1.inc(2.1)
    res = counter1.value
    counter1.unregister()

  let labelValues = @["a", "b"]
  bench("create a counter with 2 labels and increment it 3 times with different values", res):
    declareCounter counter2, "help", @["foo", "bar"]
    counter2.inc(labelValues = labelValues)
    counter2.inc(2, labelValues)
    counter2.inc(2.1, labelValues)
    res = counter2.value(labelValues)
    counter2.unregister()

when isMainModule:
  main(10000)
