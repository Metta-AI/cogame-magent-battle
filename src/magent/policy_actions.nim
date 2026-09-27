## Finite commander actions shared by training and ordinary player policies.

import std/[json, strutils]
import sim

const
  ActionCount* = 22
  ActionNames* = ["advance", "retreat", "flank left", "flank right",
    "focus 1", "focus 2", "focus 3", "focus 4", "focus 5",
    "focus 6", "focus 7", "focus 8", "focus 9",
    "hold northwest", "hold north", "hold northeast",
    "hold west", "hold center", "hold east",
    "hold southwest", "hold south", "hold southeast"]

proc actionHeads*(): JsonNode =
  result = newJArray()
  for squad in 0 ..< SquadCount:
    var choices = newJArray()
    for name in ActionNames: choices.add(%name)
    result.add(%*{"name": "squad_" & $squad, "choices": choices})

proc values*(view: JsonNode): JsonNode =
  ## All fields come from the fogged seat view. Enemy coordinates absent from
  ## that view remain -1; no server state or spectator packet is consulted.
  result = newJArray()
  for key in ["game", "of_games", "turn", "of", "tick", "turn_ticks",
              "ticks_left", "score_now"]:
    result.add(view[key])
  result.add(%(if view["your_side"].getStr() == "red": 1 else: 0))
  result.add(view["map"]["width"])
  for key in ["alive", "started", "lost_last_turn"]:
    result.add(view["your_army"][key])
  for key in ["visible_soldiers", "killed_last_turn"]:
    result.add(view["enemy"][key])
  for squad in view["your_army"]["squads"]:
    for key in ["alive", "x", "y"]: result.add(squad[key])
    result.add(%parseFloat(squad["hp"].getStr()))
    for kind in OrderKind:
      result.add(%(if squad["order"].getStr() == $kind: 1 else: 0))
  for squad in view["enemy"]["squads"]:
    result.add(squad["seen"])
    for key in ["x", "y", "last_seen_turn"]:
      result.add(if squad[key].kind == JNull: %(-1) else: squad[key])
    result.add(%(if squad["hp"].kind == JNull: -1.0
                 else: parseFloat(squad["hp"].getStr())))

proc validActions*(actions: openArray[int]): bool =
  if actions.len != SquadCount: return false
  for action in actions:
    if action notin 0 ..< ActionCount: return false
  true

proc directiveForActions*(sim: SimServer, seat: int,
                          actions: openArray[int]): ArmyDirective =
  doAssert validActions(actions)
  var orders = newJArray()
  for squad, action in actions:
    var entry = %*{"squad": squadAlias(seat, squad)}
    case action
    of 0: entry["verb"] = %"advance"
    of 1: entry["verb"] = %"retreat"
    of 2, 3:
      entry["verb"] = %"flank"
      entry["side"] = %(if action == 2: "left" else: "right")
    of 4 .. 12:
      entry["verb"] = %"focus"
      entry["target"] = %squadAlias(1 - seat, action - 4)
    of 13 .. 21:
      entry["verb"] = %"hold"
      let cell = action - 13
      entry["x"] = %((2 * (cell mod 3) + 1) * sim.config.mapSize div 6)
      entry["y"] = %((2 * (cell div 3) + 1) * sim.config.mapSize div 6)
    else: doAssert false
    orders.add(entry)
  result = parseArmyDirective(%*{"orders": orders}, seat,
    sim.directives[seat], sim.config.mapSize)
