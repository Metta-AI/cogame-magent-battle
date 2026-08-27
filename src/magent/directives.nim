## The order schema: what a commander (LLM or scripted) may say, how a reply is
## parsed TOLERANTLY, and how an illegal order is REPAIRED to that squad's
## previous order rather than dropped.
##
## Both policy kinds emit the same object through this one validator, which is
## what makes the bounded-orders test in tests/test_magent_control.nim
## meaningful.
##
## RUNE DISCIPLINE. Every cap here is measured in runes and every truncation
## lands on a rune boundary (`truncateRunes`). Byte slicing anywhere on the
## path to the replay is forbidden.

import std/[json, strutils, unicode]
import sim_types

type
  OrderKind* = enum
    okAdvance = "advance"
    okHold = "hold"
    okFocus = "focus"
    okFlank = "flank"
    okRetreat = "retreat"

  FlankSide* = enum
    fsLeft = "left"
    fsRight = "right"

  SquadOrder* = object
    kind*: OrderKind
    x*, y*: int          ## hold: the cell to march to and stand on
    target*: int         ## focus: enemy squad index 0..8
    side*: FlankSide
    fromReply*: bool     ## a reply entry really named this squad

  DirectiveSource* = enum
    dsLlm = "llm"
    dsScripted = "scripted"
    dsFallback = "fallback"

  ArmyDirective* = object
    ## One seat's whole order set for one turn: exactly SquadCount entries,
    ## squad k at index k.
    orders*: array[SquadCount, SquadOrder]
    say*: string         ## <= MaxSayRunes, spectator chatter
    notes*: string       ## <= MaxNoteRunes, private, echoed back next turn
    source*: DirectiveSource
    latencyMs*: int
    rejected*: int       ## orders repaired because they did not validate

  DirectiveError* = object of ValueError

const
  SquadLetters* = ["A", "B"]

proc squadAlias*(seat, squad: int): string =
  ## `A1`..`A9` for seat 0, `B1`..`B9` for seat 1 -- the ANONYMOUS in-game
  ## names, independent of which colour that seat holds this game.
  SquadLetters[seat mod SquadLetters.len] & $(squad + 1)

proc seatAliasName*(seat: int): string =
  if seat == 0: "Alpha" else: "Bravo"

proc parseSquadId*(text: string, seat: int): int =
  ## The squad index this seat's id names, or -1. Case-insensitive, capped at
  ## MaxSquadIdRunes before matching so an oversized id can never be a match.
  let key = text.strip().truncateRunes(MaxSquadIdRunes).toUpperAscii()
  if key.len != 2:
    return -1
  if key[0] != SquadLetters[seat mod SquadLetters.len][0]:
    return -1
  let digit = int(key[1]) - int('0')
  if digit < 1 or digit > SquadCount:
    return -1
  digit - 1

proc parseOrderKind*(text: string): tuple[ok: bool, kind: OrderKind] =
  ## Tolerant: lower-cased, hyphens and spaces normalised, capped at
  ## MaxVerbRunes. An unrecognised verb reports `ok = false` so the caller
  ## repairs to the squad's previous order instead of inventing one.
  let key = text.strip().truncateRunes(MaxVerbRunes).toLowerAscii()
    .replace("-", "_").replace(" ", "_")
  for kind in OrderKind:
    if $kind == key:
      return (true, kind)
  (false, okAdvance)

proc parseFlankSide*(text: string): tuple[ok: bool, side: FlankSide] =
  let key = text.strip().truncateRunes(MaxFlankSideRunes).toLowerAscii()
  for side in FlankSide:
    if $side == key:
      return (true, side)
  (false, fsLeft)

proc defaultDirective*(): ArmyDirective =
  ## Turn 1's default for every squad is `advance`.
  for k in 0 ..< SquadCount:
    result.orders[k] = SquadOrder(kind: okAdvance, target: -1)
  result.source = dsScripted

proc extractJsonObject*(text: string): JsonNode =
  ## The outermost balanced `{...}` in a model reply, tolerating markdown
  ## fences and any prose the model prefixed or suffixed. Falls back to
  ## first-brace..last-brace when the scan finds no balanced pair.
  var
    depth = 0
    start = -1
    inString = false
    escaped = false
  for i, ch in text:
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    case ch
    of '"': inString = true
    of '{':
      if depth == 0: start = i
      inc depth
    of '}':
      if depth > 0:
        dec depth
        if depth == 0 and start >= 0:
          try:
            return parseJson(text[start .. i])
          except CatchableError:
            start = -1
    else: discard
  let
    first = text.find('{')
    last = text.rfind('}')
  if first < 0 or last <= first:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.truncateRunes(160) & "..."
    raise newException(
      DirectiveError, "no JSON object in reply: " & head.replace("\n", " "))
  parseJson(text[first .. last])

proc readInt(node: JsonNode): tuple[ok: bool, value: int] =
  if node.isNil:
    return (false, 0)
  case node.kind
  of JInt: (true, int(node.getBiggestInt()))
  of JFloat:
    let f = node.getFloat()
    if f != f or f > 1.0e9 or f < -1.0e9: (false, 0) else: (true, int(f))
  of JString:
    try: (true, int(parseFloat(node.getStr().strip())))
    except CatchableError: (false, 0)
  else: (false, 0)

proc orderEntries(payload: JsonNode): seq[JsonNode] =
  ## The reply's `orders` collection. An ARRAY is the documented shape; an
  ## OBJECT keyed by squad id is accepted too (models emit both). Entries
  ## beyond the ninth are dropped.
  let node = payload{"orders"}
  if node.isNil:
    return @[]
  if node.kind == JArray:
    for item in node:
      if item.kind == JObject:
        result.add(item)
        if result.len >= SquadCount:
          return
  elif node.kind == JObject:
    for key, item in node:
      if item.kind != JObject:
        continue
      var entry = copy(item)
      if entry{"squad"}.isNil:
        entry["squad"] = %key
      result.add(entry)
      if result.len >= SquadCount:
        return
  else:
    raise newException(DirectiveError, "orders is not an array")

proc parseArmyDirective*(
  payload: JsonNode,
  seat: int,
  previous: ArmyDirective,
  mapSize: int
): ArmyDirective =
  ## Turns one parsed reply into a legal directive, REPAIRING every field the
  ## schema bounds rather than rejecting the reply:
  ##
  ## * a squad the reply does not name keeps its previous order;
  ## * an unknown verb, an out-of-range squad id, a `focus` on a non-enemy id,
  ##   a `flank` with no side -> the squad's PREVIOUS order, counted in
  ##   `rejected`, never dropped into "unactuated";
  ## * `hold` coordinates are clamped into [0, mapSize);
  ## * duplicates: last wins;
  ## * `say` and `notes` are rune-truncated at their caps.
  ##
  ## Raises DirectiveError only when the payload is not an object or its
  ## `orders` is not an array -- the two conditions the retry and then the
  ## scripted fallback exist for.
  if payload.isNil or payload.kind != JObject:
    raise newException(DirectiveError, "reply is not a JSON object")
  result = previous
  result.source = dsLlm
  result.rejected = 0
  result.say = sanitizeSay(payload{"say"}.getStr())
  result.notes = sanitizeLine(payload{"notes"}.getStr(), MaxNoteRunes)
  for k in 0 ..< SquadCount:
    result.orders[k].fromReply = false
  let enemySeat = 1 - seat
  for entry in payload.orderEntries():
    let squad = parseSquadId(entry{"squad"}.getStr(), seat)
    if squad < 0:
      inc result.rejected
      continue
    let verb = parseOrderKind(entry{"verb"}.getStr())
    if not verb.ok:
      inc result.rejected
      continue
    var order = SquadOrder(kind: verb.kind, target: -1, side: fsLeft)
    case verb.kind
    of okHold:
      let
        rx = readInt(entry{"x"})
        ry = readInt(entry{"y"})
      if not rx.ok or not ry.ok:
        inc result.rejected
        continue
      order.x = clamp(rx.value, 0, mapSize - 1)
      order.y = clamp(ry.value, 0, mapSize - 1)
    of okFocus:
      let target = parseSquadId(entry{"target"}.getStr(), enemySeat)
      if target < 0:
        inc result.rejected
        continue
      order.target = target
    of okFlank:
      let side = parseFlankSide(entry{"side"}.getStr())
      if not side.ok:
        inc result.rejected
        continue
      order.side = side.side
    of okAdvance, okRetreat:
      discard
    order.fromReply = true
    result.orders[squad] = order

proc orderArg*(order: SquadOrder, seat: int): string =
  ## The order's argument as one short spectator-facing string.
  case order.kind
  of okHold: $order.x & "," & $order.y
  of okFocus: squadAlias(1 - seat, order.target)
  of okFlank: $order.side
  else: ""

proc ordersJson*(directive: ArmyDirective, seat: int): JsonNode =
  result = newJArray()
  for k in 0 ..< SquadCount:
    result.add(%*{
      "squad": squadAlias(seat, k),
      "verb": $directive.orders[k].kind,
      "arg": orderArg(directive.orders[k], seat)
    })

proc directiveRecord*(
  directive: ArmyDirective,
  game, turn, seat: int,
  side: string,
  view: JsonNode
): JsonNode =
  ## The replay chat record for one turn's directive. Re-applied at playback
  ## into NON-HASHED fields only: it drives the broadcast feed and
  ## tools/replay_summary.py and can never affect the simulation.
  %*{
    "k": "directive",
    "game": game,
    "turn": turn,
    "slot": seat,
    "alias": seatAliasName(seat),
    "side": side,
    "source": $directive.source,
    "latency_ms": directive.latencyMs,
    "say": directive.say.truncateRunes(MaxSayRunes),
    "orders": directive.ordersJson(seat),
    "view": view
  }

proc boundedDirectiveRecord*(
  directive: ArmyDirective,
  game, turn, seat: int,
  side: string,
  view: JsonNode
): string =
  ## The serialized record, guaranteed <= MaxDirectiveRunes. `say` is the only
  ## field that can grow, so it is the one that shrinks -- and the cut still
  ## lands on a rune boundary. The SERIALIZED string is never sliced: that
  ## would emit broken JSON, the exact failure the rune rule prevents.
  var trimmed = directive
  result = $trimmed.directiveRecord(game, turn, seat, side, view)
  var guard = 0
  while result.runeLen > MaxDirectiveRunes and guard < 16:
    inc guard
    trimmed.say = trimmed.say.truncateRunes(max(0, trimmed.say.runeLen - 16))
    result = $trimmed.directiveRecord(game, turn, seat, side, view)
