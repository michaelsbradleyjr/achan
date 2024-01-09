{.push raises: [].}

import pkg/[achan, chronos]

proc amain() {.async.} =
  let chan = achan[int]()

  await chan.send(123)

  let data = await chan.recv
  echo data

  chan.close

proc main() =
  try:
    echo ""
    waitFor amain()
    echo ""
  except CatchableError as e:
    raise (ref Defect)(msg: e.msg)

when isMainModule:
  main()


# NOTES: while working on achan & examples/tests
# ------------------------------------------------------------------------------
# can append e.g. `.withTimeout(1.seconds)` to a future that otherwise seems
# stuck while working out the details of why that's happening (bug in achan
# library? app's state machine/s need revision?), but in that case will need to
# e.g. `discard await ...`
