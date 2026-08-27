## Bounded orders and legality on the scripted baselines, the fallback
## identity, the reply validator's repair rules, and the swept tuning pick.

import std/[json, random, strutils, unicode, unittest]
import helpers

const VerbNames = ["advance", "hold", "focus", "flank", "retreat"]

proc validate(sim: SimServer, seat: int, directive: ArmyDirective) =
  ## The reply schema, applied to a SCRIPTED directive: exactly nine orders,
  ## every verb in the enum, every hold coordinate on the board, every focus
  ## target an EXISTING enemy squad, every flank side in its enum, and the
  ## serialised directive within its cap.
  check directive.orders.len == SquadCount
  check directive.say.runeLen <= MaxSayRunes
  check directive.notes.runeLen <= MaxNoteRunes
  var seen: seq[string]
  for k in 0 ..< SquadCount:
    let
      order = directive.orders[k]
      id = squadAlias(seat, k)
    check id.runeLen <= MaxSquadIdRunes
    check id notin seen
    seen.add(id)
    check $order.kind in VerbNames
    check ($order.kind).runeLen <= MaxVerbRunes
    case order.kind
    of okHold:
      check order.x >= 0 and order.x < sim.config.mapSize
      check order.y >= 0 and order.y < sim.config.mapSize
    of okFocus:
      check order.target >= 0 and order.target < SquadCount
      ## an EXISTING enemy squad, not merely a legal index
      check squadStat(sim.units, 1 - sim.armyOfSeat(seat), order.target).alive > 0
    of okFlank:
      check ($order.side).runeLen <= MaxFlankSideRunes
      check $order.side in ["left", "right"]
    of okAdvance, okRetreat:
      discard
  let serialised = $directive.ordersJson(seat)
  check serialised.len <= 2048

suite "magent control and baselines":

  test "baselines are bounded":
    ## 200 pseudo-random world states -- varying alive counts, extinct squads,
    ## hp distributions, both map sizes, both sides -- against BOTH baselines. A
    ## baseline that ever proposes an illegal or unbounded order fails the
    ## build.
    var rng = initRand(1234)
    for iteration in 0 ..< 200:
      let mapSize = (if iteration mod 2 == 0: 31 else: 45)
      var sim = initSimServer(testConfig(mapSize = mapSize))
      sim.applyGameStart(iteration mod 2, iteration mod 2)
      ## thin the armies out at random, including whole extinct squads
      let doomedSquad = rng.rand(0 .. SquadCount - 1)
      for id in 0 ..< sim.units.soldiers.len:
        if sim.units.soldiers[id].squad == doomedSquad and
            sim.units.soldiers[id].army == iteration mod 2:
          sim.units.kill(id)
        elif rng.rand(1.0) < 0.4:
          sim.units.kill(id)
        else:
          sim.units.soldiers[id].hp = rng.rand(1 .. HpMax)
      for seat in 0 ..< SeatCount:
        for baseline in [blLine, blPincer]:
          let directive = scriptedDirective(sim, seat, baseline)
          checkpoint("iteration " & $iteration & " seat " & $seat &
            " baseline " & $baseline)
          validate(sim, seat, directive)
          check directive.say.len == 0
          check directive.notes.len == 0

  test "line advances, always":
    var sim = playingSim()
    for seat in 0 ..< SeatCount:
      let directive = lineDirective(sim, seat)
      for k in 0 ..< SquadCount:
        check directive.orders[k].kind == okAdvance
        check directive.orders[k].fromReply

  test "pincer retreats, focuses, then splits into wings":
    var sim = emptyBoard(45)
    ## a badly hurt squad retreats
    discard sim.place(5, 5, 0, 0, hp = 30)
    ## a healthy squad with an adjacent enemy squad focuses it
    discard sim.place(20, 20, 0, 1)
    discard sim.place(21, 20, 1, 4)
    ## a healthy squad with nothing near it takes its wing order
    discard sim.place(5, 40, 0, 8)
    let directive = pincerDirective(sim, 0)
    check directive.orders[0].kind == okRetreat
    check directive.orders[1].kind == okFocus
    check directive.orders[1].target == 4
    check directive.orders[8].kind == okFlank
    check directive.orders[8].side == fsRight
    check directive.orders[3].kind == okAdvance

  test "the fallback IS the pincer proc":
    ## The decision engine's fallback and the published `pincer` baseline
    ## resolve to the same orders, order for order, so they cannot drift.
    var rng = initRand(99)
    for _ in 0 ..< 25:
      var sim = playingSim(45)
      for id in 0 ..< sim.units.soldiers.len:
        if rng.rand(1.0) < 0.5:
          sim.units.kill(id)
        else:
          sim.units.soldiers[id].hp = rng.rand(1 .. HpMax)
      for seat in 0 ..< SeatCount:
        let
          baseline = pincerDirective(sim, seat)
          fallback = fallbackDirective(sim, seat)
        check fallback.source == dsFallback
        for k in 0 ..< SquadCount:
          check fallback.orders[k].kind == baseline.orders[k].kind
          check fallback.orders[k].x == baseline.orders[k].x
          check fallback.orders[k].y == baseline.orders[k].y
          check fallback.orders[k].target == baseline.orders[k].target
          check fallback.orders[k].side == baseline.orders[k].side

  test "reply validation":
    var sim = playingSim(45)
    let previous = pincerDirective(sim, 0)
    block accepted:
      let reply = parseJson("""{
        "orders": [
          {"squad": "A1", "verb": "advance"},
          {"squad": "A2", "verb": "hold", "x": 22, "y": 30},
          {"squad": "A3", "verb": "focus", "target": "B5"},
          {"squad": "A4", "verb": "flank", "side": "left"},
          {"squad": "A5", "verb": "retreat"}
        ],
        "say": "wrap their left, A2 holds the gap",
        "notes": "A7-A9 going wide"
      }""")
      let directive = parseArmyDirective(reply, 0, previous, sim.config.mapSize)
      check directive.orders[0].kind == okAdvance
      check directive.orders[1].kind == okHold
      check directive.orders[1].x == 22 and directive.orders[1].y == 30
      check directive.orders[2].kind == okFocus
      check directive.orders[2].target == 4
      check directive.orders[3].kind == okFlank
      check directive.orders[3].side == fsLeft
      check directive.orders[4].kind == okRetreat
      check directive.rejected == 0
      check directive.say == "wrap their left, A2 holds the gap"
      ## a squad the reply does not name KEEPS its previous order
      for k in 5 ..< SquadCount:
        check directive.orders[k].kind == previous.orders[k].kind

    block repaired:
      ## An individually invalid order is REPAIRED to the squad's previous
      ## order while the rest of the reply stands, and it is counted.
      let reply = parseJson("""{
        "orders": [
          {"squad": "A1", "verb": "teleport"},
          {"squad": "Z9", "verb": "advance"},
          {"squad": "A3", "verb": "focus", "target": "A4"},
          {"squad": "A4", "verb": "flank", "side": "sideways"},
          {"squad": "A5", "verb": "hold"},
          {"squad": "A6", "verb": "retreat"}
        ]
      }""")
      let directive = parseArmyDirective(reply, 0, previous, sim.config.mapSize)
      check directive.rejected == 5
      check directive.orders[0].kind == previous.orders[0].kind
      check directive.orders[2].kind == previous.orders[2].kind
      check directive.orders[3].kind == previous.orders[3].kind
      check directive.orders[4].kind == previous.orders[4].kind
      check directive.orders[5].kind == okRetreat
      ## NO squad is ever left unactuated
      for k in 0 ..< SquadCount:
        check $directive.orders[k].kind in VerbNames

    block clamped:
      let reply = parseJson(
        """{"orders":[{"squad":"A1","verb":"hold","x":9999,"y":-40}]}""")
      let directive = parseArmyDirective(reply, 0, previous, sim.config.mapSize)
      check directive.orders[0].x == sim.config.mapSize - 1
      check directive.orders[0].y == 0

    block duplicatesLastWins:
      let reply = parseJson("""{"orders":[
        {"squad":"A1","verb":"advance"},
        {"squad":"A1","verb":"retreat"}]}""")
      let directive = parseArmyDirective(reply, 0, previous, sim.config.mapSize)
      check directive.orders[0].kind == okRetreat

    block extrasDropped:
      var entries: seq[string]
      for k in 1 .. 14:
        entries.add("{\"squad\":\"A" & $(if k <= 9: k else: 9) &
          "\",\"verb\":\"advance\"}")
      let reply = parseJson("{\"orders\":[" & entries.join(",") & "]}")
      let directive = parseArmyDirective(reply, 0, previous, sim.config.mapSize)
      check directive.orders.len == SquadCount

    block sayOnlyIsUsable:
      let reply = parseJson("""{"say":"hold the line"}""")
      let directive = parseArmyDirective(reply, 0, previous, sim.config.mapSize)
      check directive.say == "hold the line"
      for k in 0 ..< SquadCount:
        check directive.orders[k].kind == previous.orders[k].kind

    block hardFailures:
      expect DirectiveError:
        discard parseArmyDirective(
          parseJson("""[1, 2, 3]"""), 0, previous, sim.config.mapSize)
      expect DirectiveError:
        discard parseArmyDirective(
          parseJson("""{"orders": "advance everything"}"""), 0, previous,
          sim.config.mapSize)
      expect DirectiveError:
        discard extractJsonObject("no braces at all here")

    block runeBoundaries:
      ## 4-byte emoji sitting EXACTLY on every cap. The cut lands on a rune
      ## boundary, so the record stays valid UTF-8 -- a byte cut here is what
      ## makes a replay render in a browser and then fail a strict parser.
      var say = ""
      for _ in 0 ..< 200:
        say.add("\u{1F525}")
      var notes = ""
      for _ in 0 ..< 400:
        notes.add("\u{1F6E1}")
      let reply = %*{"orders": [], "say": say, "notes": notes}
      let directive = parseArmyDirective(reply, 0, previous, sim.config.mapSize)
      check directive.say.runeLen == MaxSayRunes
      check directive.notes.runeLen == MaxNoteRunes
      check directive.say.validateUtf8() == -1
      check directive.notes.validateUtf8() == -1
      let record = directive.boundedDirectiveRecord(
        1, 1, 0, "red", newJNull())
      check record.validateUtf8() == -1
      check record.runeLen <= MaxDirectiveRunes
      discard parseJson(record)          ## still valid JSON after trimming

    block extractionIsTolerant:
      let fenced = "Here is my plan:\n```json\n" &
        "{\"orders\":[{\"squad\":\"A1\",\"verb\":\"retreat\"}]}\n```\nGood luck."
      let node = extractJsonObject(fenced)
      let directive = parseArmyDirective(node, 0, previous, sim.config.mapSize)
      check directive.orders[0].kind == okRetreat

  test "baseline tuning is the swept pick":
    let tuning = parseJson(readRepoFile("tools/ci/baseline_tuning.json"))
    check DefaultBaselineParams.retreatHpTenths ==
      tuning["retreatHpTenths"].getInt()
    check DefaultBaselineParams.focusRadius == tuning["focusRadius"].getInt()
    check DefaultBaselineParams.flankOffset == tuning["flankOffset"].getInt()
    check DefaultBaselineParams.flankOffset == FlankOffset
    check DefaultBaseline == blPincer
    ## anything unrecognised is the published default
    check parseBaseline("") == DefaultBaseline
    check parseBaseline("nonsense") == DefaultBaseline
    check parseBaseline("LINE") == blLine
    check parseBaseline(" pincer ") == blPincer
