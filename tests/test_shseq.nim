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
