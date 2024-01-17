{.push raises: [].}

import pkg/[achan, chronos]

type
  XKinds = enum
    xkA, xkB, xkC

  X = ref object
    case kind: XKinds
    of xkA:
      a: string
    of xkB:
      b: int
    of xkC:
      c: Y

  Y = object
    s: string

proc recvX(c: AsyncChannel[X]) {.async.} =
  let rdata = await c.recv
  case rdata.kind
  of xkA:
    echo "string: " & rdata.a
  of xkB:
    echo "int: " & $rdata.b
  else:
    echo "rdata: " & $rdata[]

proc sendX[T](c: AsyncChannel[X], val: T) {.async.} =
  when T is string:
    await c.send(X(kind: xkA, a: val))
  elif T is int:
    await c.send(X(kind: xkB, b: val))
  elif T is Y:
    await c.send(X(kind: xkC, c: val))
  else:
    {.error: "unsupported type '" & $typeof(T) & "' for sendX()".}

proc amain() {.async.} =
  let chan = achan[X]()

  discard chan.recvX
  await chan.sendX("abc")

  await chan.sendX(123)
  await chan.recvX

  await chan.sendX(Y(s: "def"))
  await chan.recvX

  chan.close

proc main() =
  try:
    waitFor amain()
  except CatchableError as e:
    raise (ref Defect)(msg: e.msg)

when isMainModule:
  echo ""
  main()
  echo ""


# NOTES: while working on achan & examples/tests
# ------------------------------------------------------------------------------
# can append e.g. `.withTimeout(1.seconds)` to a future that otherwise seems
# stuck while working out the details of why that's happening (bug in achan
# library? app's state machine/s need revision?), but in that case will need to
# e.g. `discard await ...`
