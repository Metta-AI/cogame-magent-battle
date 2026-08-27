## The replay codec. `COWLDMAG` = magic + format version + game name/version +
## the RESOLVED CONFIG JSON + a record stream + one `gameHash` per frame.
##
## The bytes are SELF-SUFFICIENT: seat names, aliases, policy kinds, the seed,
## every upstream constant, every order the commanders gave and the full
## results document all ride in the file, so the static wasm viewer re-derives
## the episode with no server in the loop (S3 for the file, nothing else).
##
## Everything is little-endian and length-prefixed. Strings are written as
## u32 length + UTF-8 bytes, and every string that reaches here was already
## truncated on a RUNE boundary (sim_types.truncateRunes) -- a byte-truncated
## codepoint renders in a browser and then fails a strict UTF-8 parser.

import std/strutils
import sim_types, directives

type
  RecordKind* = enum
    rkJoin = 1
    rkLeave = 2
    rkGameStart = 3
    rkOrders = 4
    rkChat = 5
    rkHash = 6
    rkStop = 7

  OrdersRecord* = object
    tick*: int
    game*: int
    turn*: int
    slot*: int
    orders*: array[SquadCount, SquadOrder]

  JoinRecord* = object
    tick*: int
    slot*: int
    name*: string
    token*: string

  ChatRecord* = object
    tick*: int
    slot*: int
    text*: string

  HashRecord* = object
    tick*: int
    value*: uint64

  StopRecord* = object
    tick*: int
    endRule*: string

  GameStartRecord* = object
    tick*: int
    gameIndex*: int
    redSlot*: int

  ReplayData* = object
    gameName*: string
    gameVersion*: string
    configJson*: string
    joins*: seq[JoinRecord]
    leaves*: seq[JoinRecord]
    gameStarts*: seq[GameStartRecord]
    orders*: seq[OrdersRecord]
    chats*: seq[ChatRecord]
    hashes*: seq[HashRecord]
    stops*: seq[StopRecord]
    frameCount*: int

  ReplayWriter* = object
    path*: string
    buffer*: string
    open*: bool

# --------------------------------------------------------------------------
#  primitives
# --------------------------------------------------------------------------

proc putU8(buffer: var string, value: int) =
  buffer.add(char(value and 0xff))

proc putU16(buffer: var string, value: int) =
  buffer.add(char(value and 0xff))
  buffer.add(char((value shr 8) and 0xff))

proc putU32(buffer: var string, value: int) =
  for shift in [0, 8, 16, 24]:
    buffer.add(char((value shr shift) and 0xff))

proc putU64(buffer: var string, value: uint64) =
  for shift in 0 ..< 8:
    buffer.add(char(int((value shr (shift * 8)) and 0xff'u64)))

proc putStr(buffer: var string, value: string) =
  buffer.putU32(value.len)
  buffer.add(value)

type Cursor = object
  data: string
  pos: int

proc need(cursor: var Cursor, count: int) =
  if cursor.pos + count > cursor.data.len:
    raise newException(ReplayError, "replay truncated at byte " & $cursor.pos)

proc getU8(cursor: var Cursor): int =
  cursor.need(1)
  result = int(uint8(cursor.data[cursor.pos]))
  inc cursor.pos

proc getU16(cursor: var Cursor): int =
  cursor.need(2)
  result = int(uint8(cursor.data[cursor.pos])) or
    (int(uint8(cursor.data[cursor.pos + 1])) shl 8)
  cursor.pos += 2

proc getU32(cursor: var Cursor): int =
  cursor.need(4)
  for shift in [0, 8, 16, 24]:
    result = result or (int(uint8(cursor.data[cursor.pos])) shl shift)
    inc cursor.pos

proc getU64(cursor: var Cursor): uint64 =
  cursor.need(8)
  for shift in 0 ..< 8:
    result = result or (uint64(uint8(cursor.data[cursor.pos])) shl (shift * 8))
    inc cursor.pos

proc getStr(cursor: var Cursor): string =
  let length = cursor.getU32()
  cursor.need(length)
  result = cursor.data[cursor.pos ..< cursor.pos + length]
  cursor.pos += length

# --------------------------------------------------------------------------
#  writing
# --------------------------------------------------------------------------

proc openReplayWriter*(path, configJson: string): ReplayWriter =
  ## Always buffers, even with no path: the bytes are what `/replay-data`
  ## serves, what the runtime uploader PUTs, and what the tests re-derive from.
  ## The path only decides whether they are also written to disk.
  result.path = path
  result.open = true
  result.buffer.add(ReplayMagic)
  result.buffer.putU16(int(ReplayFormatVersion))
  result.buffer.putStr(GameName)
  result.buffer.putStr(GameVersion)
  result.buffer.putStr(configJson)

proc writeJoin*(writer: var ReplayWriter, tick, slot: int, name, token: string) =
  if not writer.open: return
  writer.buffer.putU8(ord(rkJoin))
  writer.buffer.putU32(tick)
  writer.buffer.putU16(slot)
  writer.buffer.putStr(name)
  writer.buffer.putStr(token)

proc writeLeave*(writer: var ReplayWriter, tick, slot: int) =
  if not writer.open: return
  writer.buffer.putU8(ord(rkLeave))
  writer.buffer.putU32(tick)
  writer.buffer.putU16(slot)

proc writeGameStart*(writer: var ReplayWriter, tick, gameIndex, redSlot: int) =
  if not writer.open: return
  writer.buffer.putU8(ord(rkGameStart))
  writer.buffer.putU32(tick)
  writer.buffer.putU8(gameIndex)
  writer.buffer.putU8(redSlot)

proc writeOrders*(
  writer: var ReplayWriter, tick, game, turn, slot: int,
  orders: array[SquadCount, SquadOrder]
) =
  ## The only inputs this game has. Nine orders, one per squad, per seat, per
  ## turn -- the whole input log of an episode.
  if not writer.open: return
  writer.buffer.putU8(ord(rkOrders))
  writer.buffer.putU32(tick)
  writer.buffer.putU8(game)
  writer.buffer.putU16(turn)
  writer.buffer.putU8(slot)
  for order in orders:
    writer.buffer.putU8(ord(order.kind))
    writer.buffer.putU16(order.x)
    writer.buffer.putU16(order.y)
    writer.buffer.putU8(order.target + 1)
    writer.buffer.putU8(ord(order.side))

proc writeChat*(writer: var ReplayWriter, tick, slot: int, text: string) =
  if not writer.open: return
  writer.buffer.putU8(ord(rkChat))
  writer.buffer.putU32(tick)
  writer.buffer.putU16(slot)
  writer.buffer.putStr(text)

proc writeHash*(writer: var ReplayWriter, tick: int, value: uint64) =
  if not writer.open: return
  writer.buffer.putU8(ord(rkHash))
  writer.buffer.putU32(tick)
  writer.buffer.putU64(value)

proc writeStop*(writer: var ReplayWriter, tick: int, endRule: string) =
  ## The load-bearing wall-clock / fault stop. A wall-clock fact cannot be
  ## re-derived from sim state, so it is recorded and applied by the same proc
  ## on record and on playback (sim.applyStop).
  if not writer.open: return
  writer.buffer.putU8(ord(rkStop))
  writer.buffer.putU32(tick)
  writer.buffer.putStr(endRule)

proc bytes*(writer: ReplayWriter): string =
  writer.buffer

proc closeReplayWriter*(writer: var ReplayWriter) =
  if not writer.open:
    return
  writer.open = false
  if writer.path.len > 0:
    writeFile(writer.path, writer.buffer)

# --------------------------------------------------------------------------
#  reading
# --------------------------------------------------------------------------

proc parseReplayBytes*(data: string): ReplayData =
  if data.len < ReplayMagic.len or data[0 ..< ReplayMagic.len] != ReplayMagic:
    raise newException(ReplayError, "not a " & ReplayMagic & " replay")
  var cursor = Cursor(data: data, pos: ReplayMagic.len)
  let format = cursor.getU16()
  if format != int(ReplayFormatVersion):
    raise newException(ReplayError,
      "replay format " & $format & " is not " & $ReplayFormatVersion)
  result.gameName = cursor.getStr()
  result.gameVersion = cursor.getStr()
  result.configJson = cursor.getStr()
  if result.gameName != GameName:
    raise newException(ReplayError, "replay is for " & result.gameName)
  while cursor.pos < data.len:
    let kind = cursor.getU8()
    case kind
    of ord(rkJoin):
      var record = JoinRecord(tick: cursor.getU32(), slot: cursor.getU16())
      record.name = cursor.getStr()
      record.token = cursor.getStr()
      result.joins.add(record)
    of ord(rkLeave):
      result.leaves.add(
        JoinRecord(tick: cursor.getU32(), slot: cursor.getU16()))
    of ord(rkGameStart):
      result.gameStarts.add(GameStartRecord(
        tick: cursor.getU32(), gameIndex: cursor.getU8(),
        redSlot: cursor.getU8()))
    of ord(rkOrders):
      var record = OrdersRecord(
        tick: cursor.getU32(), game: cursor.getU8(), turn: cursor.getU16(),
        slot: cursor.getU8())
      for k in 0 ..< SquadCount:
        record.orders[k] = SquadOrder(
          kind: OrderKind(cursor.getU8()),
          x: cursor.getU16(),
          y: cursor.getU16(),
          target: cursor.getU8() - 1,
          side: FlankSide(cursor.getU8()),
          fromReply: true)
      result.orders.add(record)
    of ord(rkChat):
      var record = ChatRecord(tick: cursor.getU32(), slot: cursor.getU16())
      record.text = cursor.getStr()
      result.chats.add(record)
    of ord(rkHash):
      result.hashes.add(
        HashRecord(tick: cursor.getU32(), value: cursor.getU64()))
    of ord(rkStop):
      var record = StopRecord(tick: cursor.getU32())
      record.endRule = cursor.getStr()
      result.stops.add(record)
    else:
      raise newException(ReplayError,
        "unknown replay record " & $kind & " at byte " & $(cursor.pos - 1))
  # The frame span is the maximum tick ANY record carries, not just the hashed
  # ones: a wall-clock or fault stop is written on a frame the recording never
  # advanced (and therefore never hashed), and the trailing `result` record
  # lands one frame later still. Deriving the span from hashes alone left the
  # stop beyond maxFrame, so playback never applied it and re-derived an
  # episode with no banked game at all.
  for record in result.hashes:
    result.frameCount = max(result.frameCount, record.tick + 1)
  for record in result.stops:
    result.frameCount = max(result.frameCount, record.tick + 1)
  for record in result.gameStarts:
    result.frameCount = max(result.frameCount, record.tick + 1)
  for record in result.orders:
    result.frameCount = max(result.frameCount, record.tick + 1)
  for record in result.chats:
    result.frameCount = max(result.frameCount, record.tick + 1)

proc loadReplay*(path: string): ReplayData =
  parseReplayBytes(readFile(path))

proc configField*(data: ReplayData, key: string): string =
  ## A cheap scalar read out of the header config without a JSON dependency in
  ## the caller. Returns "" when the key is absent.
  let needle = "\"" & key & "\":"
  let at = data.configJson.find(needle)
  if at < 0:
    return ""
  var i = at + needle.len
  while i < data.configJson.len and data.configJson[i] in {' ', '\t'}:
    inc i
  if i < data.configJson.len and data.configJson[i] == '"':
    inc i
    let start = i
    while i < data.configJson.len and data.configJson[i] != '"':
      inc i
    return data.configJson[start ..< i]
  let start = i
  while i < data.configJson.len and data.configJson[i] notin {',', '}'}:
    inc i
  data.configJson[start ..< i].strip()
