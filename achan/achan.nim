{.push raises: [].}

import std/[isolation, lists, sequtils, strutils]
import pkg/[chronos, threading/channels]

# The meaning of "park/ed/s" in names and comments below is in reference to
# uncompleted futures returned by recv() and send()

const
  maxParkedRecv* {.intdefine.}: int = 1024
  maxParkedSend* {.intdefine.}: int = 1024

  MaxParkedRecv = Positive(maxParkedRecv)
  MaxParkedSend = Natural(maxParkedSend)

type
  AsyncChannelImpl[T] = object
    buffer: Buffer[T]
    closed: bool
    name: string
    parkedRecv: DoublyLinkedList[Future[T]]
    parkedSend: DoublyLinkedList[tuple[fut: Future[T]; src: Isolated[T]]]
    unreceived: bool

  AsyncChannel*[T] = ref AsyncChannelImpl[T]

  # Regardless of buffer kind, AsyncChannel instances have limits imposed by
  # maxParkedRecv and maxParkedSend (tunable at compile-time); if those limits
  # are exceeded at runtime then there is an effective (and probably
  # unanticipated) mismatch between rates of data production and consumption
  # that must be addressed by this library's user, e.g. backpressure may need
  # to be better communicated via `await`, and in any case the app-specific
  # state machines written by the user (the app's developer) will need to be
  # reconsidered, by that user! If the library user chooses buffer kind
  # 'bkUnbounded' then unacceptable memory consumption is a likely outcome, but
  # that *is* a choice the user can make.
  BufferKinds* = enum
    # `bkUnbuffered` recv() parks if no data has been sent since previous recv()
    #                send() parks if previously sent data is unreceived
    # `bkFixed`      recv() parks if buffer is empty
    #                send() parks if buffer is full
    # `bkDropping`   recv() parks if buffer is empty
    #                send() never parks, drops newest value in buffer if full
    # `bkSliding`    recv() parks if buffer is empty
    #                send() never parks, drops oldest value in buffer if full
    # `bkUnbounded`  recv() parks if buffer is empty
    #                send() never parks, buffer growth is unbounded!
    #                suitable for exploration of concepts
    #                *maybe* suitable for prototypes
    #                **not** generally suitable for development or production,
    #                don't be a buffoon
    bkUnbuffered, bkFixed, bkDropping, bkSliding, bkUnbounded

  Buffer[T] = object
    case kind: BufferKinds
    of bkUnbuffered:
      unbufData: Isolated[T]
    of bkFixed:
      buffiData: DoublyLinkedList[Isolated[T]]
      buffiSize: TwoPlus
    of bkDropping, bkSliding: # *wi*ndowed kinds
      bufwiData: DoublyLinkedList[Isolated[T]]
      bufwiSize: Positive
    of bkUnbounded:
      bufunData: DoublyLinkedList[Isolated[T]]

  ClosedDefect = object of Defect

  ParkedLimitDefect = object of Defect

  TwoPlus = range[2..high(int)]

template joinLines(s: string): string =
  s.split("\n").mapIt(it.strip).join(" ")

func msgBufSizeTooSmall(kind: BufferKinds; min: Positive): string =
  let
    clause1 = "'bufSize' for kind '" & $kind & "' must be >= " & $min
    clause2 =
      if kind == bkFixed:
        ", else use '" & $bkUnbuffered & "'"
      else:
        ""
  clause1 & clause2

func msgClosedBeforeRecvAndEmpty(name: string): string =
  try:
    let clause =
      if name == "":
        "instance"
      else:
        "instance '$#'" % [name]
    ("""
     AsyncChannel $# was closed before recv() and the channel holds no
     unreceived data, guard with isClosed() and hasUnreceived()
     """ % [clause]).joinLines
  except ValueError as e:
    raise (ref Defect)(msg: e.msg)

func msgClosedBeforeSend(name: string): string =
  try:
    let clause =
      if name == "":
        "instance"
      else:
        "instance '$#'" % [name]
    ("""
     AsyncChannel $# was closed before send(), guard with isClosed()
     """ % [clause]).joinLines
  except ValueError as e:
    raise (ref Defect)(msg: e.msg)

func msgBufSizeNotSupported(kind: BufferKinds): string =
  "'bufSize' not supported for kind '" & $kind & "'"

func msgBufSizeRequired(kind: BufferKinds): string =
  "'bufSize' required for kind '" & $kind & "'"

func msgParkedLimitRecv(name: string): string =
  try:
    let
      clause1 =
        if MaxParkedRecv == 1:
          "is"
        else:
          "are"
      clause2 =
        if name == "":
          "an AsyncChannel instance"
        else:
          "AsyncChannel instance '$#'" % [name]
    ("""
     No more than $# parked recv() $# allowed on $#, consider using a windowed
     buffer kind: 'bkDropping', 'bkSliding'; or adjust the limit with
     compile-time option `-d:maxParkedRecv=N`
     """ % [$MaxParkedRecv, clause1, clause2]).joinLines
  except ValueError as e:
    raise (ref Defect)(msg: e.msg)

func msgParkedLimitSend(name: string): string =
  try:
    let
      clause1 =
        if MaxParkedSend == 0:
          "No"
        else:
          "No more than $#" % [$MaxParkedSend]
      clause2 =
        if MaxParkedSend == 1:
          "is"
        else:
          "are"
      clause3 =
        if name == "":
          "an AsyncChannel instance"
        else:
          "AsyncChannel instance '$#'" % [name]
    ("""
     $# parked send() $# allowed on $#, consider using a windowed buffer kind:
     'bkDropping', 'bkSliding'; or adjust the limit with compile-time option
     `-d:maxParkedSend=N`
     """ % [clause1, clause2, clause3]).joinLines
  except ValueError as e:
    raise (ref Defect)(msg: e.msg)

func new[T](
    U: typedesc[AsyncChannel[T]]; buffer: sink Buffer[T]; name: string): U =
  U(buffer: buffer, name: name)

func achan*[T](name: string = ""): AsyncChannel[T] =
  AsyncChannel[T].new(Buffer[T](kind: bkUnbuffered), name)

func achan*[T](kind: BufferKinds; name = ""): AsyncChannel[T] =
  case kind
  of bkUnbuffered:
    AsyncChannel[T].new(Buffer[T](kind: bkUnbuffered), name)
  of bkUnbounded:
    AsyncChannel[T].new(Buffer[T](kind: bkUnbounded), name)
  of bkFixed, bkDropping, bkSliding:
    raise (ref AssertionDefect)(msg: msgBufSizeRequired(kind))

func achan*[T](bufSize: int; name: string = ""): AsyncChannel[T] =
  const minSize = low(Buffer[int].buffiSize)
  if bufSize < minSize:
    raise (ref AssertionDefect)(msg: msgBufSizeTooSmall(bkFixed, minSize))
  AsyncChannel[T].new(Buffer[T](kind: bkFixed, buffiSize: bufSize), name)

func achan*[T](kind: BufferKinds; bufSize: int; name: string = ""):
    AsyncChannel[T] =
  case kind
  of bkFixed:
    const minSize = low(Buffer[int].buffiSize)
    if bufSize < minSize:
      raise (ref AssertionDefect)(msg: msgBufSizeTooSmall(bkFixed, minSize))
    AsyncChannel[T].new(Buffer[T](kind: bkFixed, buffiSize: bufSize), name)
  of bkDropping:
    const minSize = low(Buffer[int].bufwiSize)
    if bufSize < minSize:
      raise (ref AssertionDefect)(msg: msgBufSizeTooSmall(bkDropping, minSize))
    AsyncChannel[T].new(Buffer[T](kind: bkDropping, bufwiSize: bufSize), name)
  of bkSliding:
    const minSize = low(Buffer[int].bufwiSize)
    if bufSize < minSize:
      raise (ref AssertionDefect)(msg: msgBufSizeTooSmall(bkSliding, minSize))
    AsyncChannel[T].new(Buffer[T](kind: bkSliding, bufwiSize: bufSize), name)
  else:
    raise (ref AssertionDefect)(msg: msgBufSizeNotSupported(kind))

func bufKind*(c: AsyncChannel): BufferKinds =
  c.buffer.kind

func bufSize*(c: AsyncChannel): int =
  let kind = c.buffer.kind
  case kind
  of bkFixed:
    c.buffer.buffiSize.int
  of bkDropping, bkSliding:
    c.buffer.bufwiSize.int
  else:
    raise (ref Defect)(msg:
      "bufSize() not supported for kind '" & $kind & "', guard with bufKind()")

proc close*(c: AsyncChannel) =
  c.closed = true

func hasUnreceived*(c: AsyncChannel): bool =
  c.unreceived

func isClosed*(c: AsyncChannel): bool =
  c.closed

func name*(c: AsyncChannel): string =
  c.name

proc recv*[T](c: AsyncChannel[T]): Future[T] {.async: (raw: true).} =
  let fut = newFuture[T]("recv")
  if c.closed and not c.unreceived:
    raise (ref Defect)(msg: msgClosedBeforeRecvAndEmpty(c.name))
  case c.buffer.kind
  of bkUnbuffered:
    if c.unreceived:
      # WIP: need logic such that if parkedSend is not empty then process the
      # next one, i.e. it's not as simple as the 2 lines I have below presently
      fut.complete(c.buffer.unbufData.extract)
      c.unreceived = false
    else:
      c.parkedRecv.add newDoublyLinkedNode[Future[T]](fut)
    fut
  # of bkFixed:
  #   # WIP ... state machine re: buffer
  #   fut
  # of bkDropping:
  #   # WIP ... state machine re: buffer
  #   fut
  # of bkSliding:
  #   # WIP ... state machine re: buffer
  #   fut
  # of bkUnbounded:
  #   # WIP ... state machine re: buffer
  #   fut
  else:
    # get rid of this once all cases implemented
    raise (ref AssertionDefect)(msg: "not yet implemented!")

proc send*[T](c: AsyncChannel[T]; src: sink Isolated[T]):
    Future[void] {.async: (raw: true).} =
  let fut = newFuture[void]("send")
  if c.closed:
    raise (ref Defect)(msg: msgClosedBeforeSend(c.name))
  else:
    case c.buffer.kind
    of bkUnbuffered:
      # if c.unreceived:
      #   # add to parkedSend
      #   ...
      # else:
      #   if ...:
      #
      #   else:
      #     # c.buffer.unbufData = src
      #     # c.unreceived = true
      c.buffer.unbufData = src # wip
      c.unreceived = true # wip
      fut.complete
      fut
    # of bkFixed:
    #   # WIP ... state machine re: buffer
    #   fut
    # of bkDropping:
    #   # WIP ... state machine re: buffer
    #   fut.complete
    #   fut
    # of bkSliding:
    #   # WIP ... state machine re: buffer
    #   fut.complete
    #   fut
    # of bkUnbounded:
    #   # WIP ... append buffer
    #   fut.complete
    #   fut
    else:
      # get rid of this once all cases implemented
      raise (ref AssertionDefect)(msg: "not yet implemented!")

template send*[T](c: AsyncChannel[T]; src: T): Future[void] =
  send(c, isolate(src))
