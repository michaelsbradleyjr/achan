{.push raises: [].}

import pkg/[achan, chronos]

proc amain() {.async.} =
  let chan = achan[int]()

  # discard await chan.send(123).withTimeout(1.seconds)
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
