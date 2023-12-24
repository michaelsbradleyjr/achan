{.push raises: [].}

import std/[isolation, lists, sequtils, strutils]
import pkg/[chronos, threading/channels]

type
  AsyncChannelImpl[T] = object
    buffer: Buffer[T]
    closed: bool
    futsRecv: DoublyLinkedList[Future[T]]
    futsSend: DoublyLinkedList[tuple[fut: Future[T]; src: Isolated[T]]]
    name: string
    unreceived: bool

  AsyncChannel*[T] = ref AsyncChannelImpl[T]

  # Regardless of buffer kind, AsyncChannel instances have limits imposed by
  # MaxPendingRecv and MaxPendingSend (tunable at compile-time); if those
  # limits are exceeded at runtime then there is a mismatch between rates of
  # data production and consumption that must be addressed by this library's
  # user, e.g. backpressure may need to be better communicated via `await`, and
  # in any case the app-specific state machines written by the user will need
  # to be reconsidered, by that user! If the library user chooses kind
  # 'bkUnbounded' there will inevitably be unacceptable memory consumption, but
  # that *is* a choice the user can make.
  BufferKind* = enum
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
    #                **not** suitable for general development and production
    bkUnbuffered, bkFixed, bkDropping, bkSliding, bkUnbounded

  Buffer*[T] = object
    case kind: BufferKind
    of bkUnbuffered:
      unbufData: Isolated[T]
    of bkFixed, bkDropping, bkSliding:
      bufCount: int
      bufData: DoublyLinkedList[Isolated[T]]
      bufSize: int
    of bkUnbounded:
      bufunCount: int
      bufunData: DoublyLinkedList[Isolated[T]]

  ClosedDefect* = object of Defect

  PendingLimitDefect* = object of Defect

const
  maxPendingRecv* {.intdefine.}: int = 1024
  maxPendingSend* {.intdefine.}: int = 1024

  MaxPendingRecv = Natural(maxPendingRecv)
  MaxPendingSend = Natural(maxPendingSend)

  msgBufferSizeTooSmall = "'bufSize' must be > 0"

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
     """ % [clause]).split("\n").mapIt(it.strip).join(" ")
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
     """ % [clause]).split("\n").mapIt(it.strip).join(" ")
  except ValueError as e:
    raise (ref Defect)(msg: e.msg)

func msgBufferSizeNotSupported(kind: BufferKind): string =
  "'bufSize' required for kind '" & $kind & "'"

func msgBufferSizeRequired(kind: BufferKind): string =
  "'bufSize' required for kind '" & $kind & "'"

func msgPendingLimitRecv(name: string): string =
  try:
    let
      clause1 =
        if MaxPendingRecv == 0:
          "No"
        else:
          "No more than $#" % [$MaxPendingRecv]
      clause2 =
        if name == "":
          "an AsyncChannel instance"
        else:
          "AsyncChannel instance '$#'" % [name]
    ("""
     $# pending recv() are allowed on $#, consider using a
     windowed buffer kind: 'bkDropping', 'bkSliding'; or adjust the limit with
     compile-time option `-d:maxPendingRecv=N`
     """ % [clause1, clause2]).split("\n").mapIt(it.strip).join(" ")
  except ValueError as e:
    raise (ref Defect)(msg: e.msg)

func msgPendingLimitSend(name: string): string =
  try:
    let
      clause1 =
        if MaxPendingSend == 0:
          "No"
        else:
          "No more than $#" % [$MaxPendingSend]
      clause2 =
        if name == "":
          "an AsyncChannel instance"
        else:
          "AsyncChannel instance '$#'" % [name]
    ("""
     $# pending send() are allowed on $#, consider using a
     windowed buffer kind: 'bkDropping', 'bkSliding'; or adjust the limit with
     compile-time option `-d:maxPendingSend=N`
     """ % [clause1, clause2]).split("\n").mapIt(it.strip).join(" ")
  except ValueError as e:
    raise (ref Defect)(msg: e.msg)

func new*[T](
    U: typedesc[AsyncChannel[T]]; buffer: sink Buffer[T];
    name: string = ""): U =
  U(buffer: buffer, name: name)

func achan*[T](name: string = ""): AsyncChannel[T] =
  AsyncChannel[T].new(Buffer[T](kind: bkUnbuffered), name)

func achan*[T](kind: BufferKind; name = ""): AsyncChannel[T] =
  case kind
  of bkUnbuffered:
    AsyncChannel[T].new(Buffer[T](kind: kind), name)
  of bkUnbounded:
    AsyncChannel[T].new(Buffer[T](kind: kind), name)
  of bkFixed, bkDropping, bkSliding:
    raise (ref AssertionDefect)(msg: msgBufferSizeRequired(kind))

func achan*[T](bufSize: int; name: string = ""): AsyncChannel[T] =
  if bufSize < 1:
    raise (ref AssertionDefect)(msg: msgBufferSizeTooSmall)
  AsyncChannel[T].new(Buffer[T](kind: bkFixed, bufSize: bufSize), name)

func achan*[T](
    kind: BufferKind; bufSize: int; name: string = ""): AsyncChannel[T] =
  case kind
  of bkFixed, bkDropping, bkSliding:
    if bufSize < 1:
      raise (ref AssertionDefect)(msg: msgBufferSizeTooSmall)
    AsyncChannel[T].new(Buffer[T](kind: kind, bufSize: bufSize), name)
  else:
    raise (ref AssertionDefect)(msg: msgBufferSizeNotSupported(kind))

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
      # WIP: need logic such that if futsSend is not empty then process the
      # next one, i.e. it's not as simple as the 2 lines I have below presently
      fut.complete(c.buffer.unbufData.extract)
      c.unreceived = false
    else:
      c.futsRecv.add newDoublyLinkedNode[Future[T]](fut)
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
      #   # add to futsSend
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
