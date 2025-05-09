{.used.}

import unittest2, ../metrics/shseq

suite "ShSeq":
  test "basics":
    var s: ShSeq[int]

    s.add(1)
    s.add(2)
    s.add(4)

    s.insert(0, 0)
    s.insert(3, 3)
    s.insert(5, 5)

    for i in 0 ..< s.len:
      check s[i] == i

  test "init":
    let s = ShSeq.init([0, 1, 2])
    check:
      s.len == 3
      s[1] == 1

  test "cross-thread init/destroy":
    when defined(threads):
      var s: ShSeq[int]

      var t: Thread[ptr ShSeq[int]]

      proc threadFunc(s: ptr ShSeq[int]) {.thread.} =
        s[].add(2)
        s[].add(1)
        s[].add(0)

      createThread(t, threadFunc, addr s)

      t.joinThread()

      check:
        s[0] == 2

      s.destroy()

      check:
        s.len == 0
    else:
      skip()
