{.push raises: [].}

import std/[isolation, lists, sequtils, strutils]
import pkg/[chronos, threading/channels]

# The meaning of "park/ed/s" in names and comments below is in reference to
# uncompleted futures returned by recv() and send()

const
  maxParkedRecv* {.intdefine.}: int = 1024
  maxParkedSend* {.intdefine.}: int = 1024

  MaxParkedRecv = Positive(maxParkedRecv)
  MaxParkedSend = Positive(maxParkedSend)

type
  AsyncChannelImpl[T] = object
    buffer: Buffer[T]
    closed: bool
    name: string
    parkedRecv: DoublyLinkedList[Future[T]]
    parkedRecvCount: Natural
    parkedSend: DoublyLinkedList[tuple[fut: Future[T]; src: Isolated[T]]]
    parkedSendCount: Natural
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
      buffiCount: Natural
      buffiData: DoublyLinkedList[Isolated[T]]
      buffiSize: TwoPlus
    of bkDropping, bkSliding: # *wi*ndowed
      bufwiCount: Natural
      bufwiData: DoublyLinkedList[Isolated[T]]
      bufwiSize: Positive
    of bkUnbounded:
      bufunCount: Natural
      bufunData: DoublyLinkedList[Isolated[T]]

  BufferKindDefect = object of Defect

  ClosedDefect = object of Defect

  ParkedLimitDefect = object of Defect

  TwoPlus* = range[2..high(int)]

template joinLines(s: string): string =
  s.split("\n").mapIt(it.strip).join(" ")

template raiseValueErrorAsDefect(body: untyped): untyped =
  try:
    body
  except ValueError as e:
    raise (ref Defect)(msg: e.msg)

func msgBufSizeTooSmall(bufKind: BufferKinds; minSize: int): string =
  raiseValueErrorAsDefect:
    let clause = "'bufSize' for kind '$#' must be >= $#" % [$bufKind, $minSize]
    if bufKind == bkFixed:
      "$#, else use '$#'" % [clause, $bkUnbuffered]
    else:
      clause

func msgClosedAlready(name: string): string =
  raiseValueErrorAsDefect:
    let clause =
      if name == "":
        "instance"
      else:
        "instance '$#'" % [name]
    "AsyncChannel $# was already closed, guard with isClosed()" % [clause]

func msgClosedBeforeRecvAndEmpty(name: string): string =
  raiseValueErrorAsDefect:
    let clause =
      if name == "":
        "instance"
      else:
        "instance '$#'" % [name]
    ("""
     AsyncChannel $# was closed before recv() and holds no unreceived data,
     guard with isClosed() and hasUnreceived()
     """ % [clause]).joinLines

func msgClosedBeforeSend(name: string): string =
  raiseValueErrorAsDefect:
    let clause =
      if name == "":
        "instance"
      else:
        "instance '$#'" % [name]
    "AsyncChannel $# was closed before send(), guard with isClosed()" % [clause]

func msgBufSizeNotSupported(bufKind: BufferKinds): string =
  raiseValueErrorAsDefect:
    "'bufSize' not supported for kind '$#'" % [$bufKind]

func msgBufSizeRequired(bufKind: BufferKinds): string =
  raiseValueErrorAsDefect:
    "'bufSize' required for kind '$#'" % [$bufKind]

func msgParkedLimitRecv(name: string): string =
  raiseValueErrorAsDefect:
    let clause =
      if name == "":
        "an AsyncChannel instance"
      else:
        "AsyncChannel instance '$#'" % [name]
    ("""
     No more than $# parked recv() allowed on $#, consider using a windowed
     buffer kind: 'bkDropping', 'bkSliding'; or adjust the limit with
     compile-time option `-d:maxParkedRecv=N`
     """ % [$MaxParkedRecv, clause]).joinLines

func msgParkedLimitSend(name: string): string =
  raiseValueErrorAsDefect:
    let clause =
      if name == "":
        "an AsyncChannel instance"
      else:
        "AsyncChannel instance '$#'" % [name]
    ("""
     No more than $# parked send() allowed on $#, consider using a windowed
     buffer kind: 'bkDropping', 'bkSliding'; or adjust the limit with
     compile-time option `-d:maxParkedSend=N`
     """ % [$MaxParkedSend, clause]).joinLines

func new[T](
    U: typedesc[AsyncChannel[T]]; buffer: sink Buffer[T]; name: string): U =
  U(buffer: buffer, name: name)

func achan*[T](name: string = ""): AsyncChannel[T] =
  AsyncChannel[T].new(Buffer[T](kind: bkUnbuffered), name)

func achan*[T](bufKind: BufferKinds; name = ""): AsyncChannel[T] =
  case bufKind
  of bkUnbuffered:
    AsyncChannel[T].new(Buffer[T](kind: bkUnbuffered), name)
  of bkUnbounded:
    AsyncChannel[T].new(Buffer[T](kind: bkUnbounded), name)
  of bkFixed, bkDropping, bkSliding:
    raise (ref BufferKindDefect)(msg: msgBufSizeRequired(bufKind))

func achan*[T](bufSize: TwoPlus; name: string = ""): AsyncChannel[T] =
  AsyncChannel[T].new(Buffer[T](kind: bkFixed, buffiSize: bufSize), name)

func achan*[T](bufKind: BufferKinds; bufSize: Positive; name: string = ""):
    AsyncChannel[T] =
  case bufKind
  of bkFixed:
    const minSize = low(Buffer[int].buffiSize)
    if bufSize < minSize:
      raise (ref BufferKindDefect)(msg: msgBufSizeTooSmall(bufKind, minSize))
    AsyncChannel[T].new(Buffer[T](kind: bkFixed, buffiSize: bufSize), name)
  of bkDropping:
    AsyncChannel[T].new(Buffer[T](kind: bkDropping, bufwiSize: bufSize), name)
  of bkSliding:
    AsyncChannel[T].new(Buffer[T](kind: bkSliding, bufwiSize: bufSize), name)
  else:
    raise (ref BufferKindDefect)(msg: msgBufSizeNotSupported(bufKind))

func bufCount*(c: AsyncChannel): int =
  raiseValueErrorAsDefect:
    let bufKind = c.buffer.kind
    case bufKind
    of bkFixed:
      c.buffer.buffiCount
    of bkDropping, bkSliding:
      c.buffer.bufwiCount
    of bkUnbounded:
      c.buffer.bufunCount
    else:
      raise (ref BufferKindDefect)(msg:
        "bufCount() not supported for kind '$#', guard with bufKind()" %
        [$bufKind])

func bufKind*(c: AsyncChannel): BufferKinds =
  c.buffer.kind

func bufSize*(c: AsyncChannel): int =
  raiseValueErrorAsDefect:
    let bufKind = c.buffer.kind
    case bufKind
    of bkFixed:
      c.buffer.buffiSize
    of bkDropping, bkSliding:
      c.buffer.bufwiSize
    else:
      raise (ref BufferKindDefect)(msg:
        "bufSize() not supported for kind '$#', guard with bufKind()" %
        [$bufKind])

# need to consider cancellation (? cancelSoon) upon close when number of
# pending recv is greater than bufCount

proc close*(c: AsyncChannel) =
  if c.closed:
    raise (ref ClosedDefect)(msg: msgClosedAlready(c.name))
  else:
    c.closed = true

func hasUnreceived*(c: AsyncChannel): bool =
  c.unreceived

func hasEnoughUnreceived*(c: AsyncChannel): bool =
  false # fix me!
  # will need case logic here to handle the different buffer kinds, i.e. should
  # work for bkUnbuffered as well as the others, though for bkUnbuffered case
  # can fallback to hasUnreceived()
  #
  # always true if channel is not closed? or should that be a Defect? should
  # probably be a Defect with message suggesting to guard with isClosed()

func isClosed*(c: AsyncChannel): bool =
  c.closed

func name*(c: AsyncChannel): string =
  c.name

func parkedRecvCount*(c: AsyncChannel): int =
  c.parkedRecvCount

func parkedSendCount*(c: AsyncChannel): int =
  c.parkedSendCount

proc recv*[T](c: AsyncChannel[T]): Future[T] {.async: (raw: true).} =
  let fut = newFuture[T]("recv")
  if c.closed and not c.unreceived:
    # need to consider a cancelSoon() approach instead, or probably a hybrid
    raise (ref ClosedDefect)(msg: msgClosedBeforeRecvAndEmpty(c.name))
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
    raise (ref Defect)(msg: "not yet implemented!")

proc send*[T](c: AsyncChannel[T]; src: sink Isolated[T]):
    Future[void] {.async: (raw: true).} =
  let fut = newFuture[void]("send")
  if c.closed:
    # need to consider a cancelSoon() approach instead
    raise (ref ClosedDefect)(msg: msgClosedBeforeSend(c.name))
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
      raise (ref Defect)(msg: "not yet implemented!")

template send*[T](c: AsyncChannel[T]; src: T): Future[void] =
  send(c, isolate(src))
