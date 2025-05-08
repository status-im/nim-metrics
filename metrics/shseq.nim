# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0: http://www.apache.org/licenses/LICENSE-2.0
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import std/typetraits

type ShSeq*[T] = object
  # Sequence whose elements reside in shared memory - only works for copyMem:able types
  items: ptr UncheckedArray[T]
  capacity, len: int

proc grow(s: var ShSeq, size: int) =
  type T = typeof(s).T

  static:
    doAssert supportsCopyMem(T)

  if size <= s.capacity:
    return

  var tmp = cast[ptr UncheckedArray[T]](createU(T, size))
  if s.len > 0:
    copyMem(addr tmp[0], addr s.items[0], s.len * sizeof(T))
  s.capacity = size
  s.items = tmp

proc destroy*(s: var ShSeq) =
  if not isNil(s.items):
    deallocShared(s.items)
    reset(s)

proc init*[T](_: type ShSeq, v: openArray[T]): ShSeq[T] =
  var s: ShSeq[T]
  if v.len > 0:
    s.grow(v.len)
    copyMem(addr s.items[0], unsafeAddr v[0], v.len * sizeof(T))
    s.len = v.len

  s

proc add*(s: var ShSeq, v: auto) =
  if s.len == s.capacity:
    s.grow(max(64, s.len + s.len div 2))
  s.items[s.len] = v
  s.len += 1

func `[]`*(s: ShSeq, i: int): lent s.T =
  doAssert i >= 0 and i < s.len, "Bounds check"
  s.items[i]

func `[]`*(s: var ShSeq, i: int): var s.T =
  doAssert i >= 0 and i < s.len, "Bounds check"
  s.items[i]

proc insert*(s: var ShSeq, v: auto, pos: int) =
  type T = typeof(s).T

  doAssert pos >= 0 and pos <= s.len, "Bounds check"

  if s.len == s.capacity:
    s.grow(max(64, s.len + s.len div 2))

  if pos < s.len:
    moveMem(addr s.items[pos + 1], addr s.items[pos], (s.len - pos) * sizeof(T))

  s.items[pos] = v
  s.len += 1

template len*(s: ShSeq): int =
  s.len

template data*(s: ShSeq): openArray =
  s.items.toOpenArray(0, s.len - 1)

iterator items*(s: ShSeq): lent s.T =
  for i in 0 ..< s.len:
    yield s[i]
