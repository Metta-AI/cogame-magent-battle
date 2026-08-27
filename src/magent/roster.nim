## Join, auth, the two name spaces, and the results document.
##
## TWO NAME SPACES, and both are required. In-game the seats are `Alpha` and
## `Bravo` and their squads `A1..A9` / `B1..B9`; those aliases are the only
## names that appear in an observation, a prompt, an order or a sprite label,
## so a commander can never learn who it is playing. The seats' REAL policy
## names live only in `results.names`, in the replay's join records and in the
## viewer's scorebug -- spectator side only, with `showPlayerLabels` false.

import std/[json, strutils]
import sim_types, sim_state, sim_config, directives, replays

const IdentityNames* = ["Alpha", "Bravo"]

proc seatAlias*(slot: int): string =
  ## Army-anonymous: independent of which side the seat holds this game.
  IdentityNames[slot mod IdentityNames.len]

proc cleanPlayerName*(name: string): string =
  result = name.strip()
  for ch in result.mitems:
    if ch in {' ', '\t', '\n', '\r'}:
      ch = '_'

proc joinError*(sim: SimServer, slot: int, token: string): string =
  ## The rejection reason for bad roster credentials, or "" to admit.
  if slot < 0 or slot >= sim.config.numAgents:
    return "Player slot must be between 0 and " &
      $(sim.config.numAgents - 1) & "."
  if not sim.config.playerJoinAllowed(slot, token):
    return "Player token does not match configured slot " & $slot & "."
  ""

proc admitSeat*(sim: var SimServer, slot: int, name: string) =
  if slot < 0 or slot >= SeatCount:
    return
  sim.joined[slot] = true
  if name.len > 0:
    sim.seatNames[slot] = name
  elif sim.config.configuredPlayerName(slot).len > 0:
    sim.seatNames[slot] = sim.config.configuredPlayerName(slot)

proc seatsJoined*(sim: SimServer): int =
  for slot in 0 ..< sim.config.numAgents:
    if sim.joined[slot]:
      inc result

proc winnerNode(sim: SimServer): JsonNode =
  let a = sim.scoreOf(0)
  if a > 0: %0
  elif a < 0: %1
  else: newJNull()

proc armyResultsJson*(sim: SimServer): string =
  ## The CLOSED results schema. Adding a key means updating this proc, the
  ## manifest's `results_schema` and tools_ci docker_smoke.sh's expected-key
  ## set in the same commit -- Coworld schemas are closed and undeclared keys
  ## are dropped.
  var
    names = newJArray()
    aliases = newJArray()
    scores = newJArray()
    win = newJArray()
    gameWinsNode = newJArray()
    survivorsNode = newJArray()
    killsNode = newJArray()
    rewardNode = newJArray()
    policyKinds = newJArray()
    llmTurns = newJArray()
    fallbackTurns = newJArray()
    ordersRejected = newJArray()
    deadSeats = newJArray()
  for seat in 0 ..< SeatCount:
    names.add(%sim.seatNames[seat])
    aliases.add(%seatAlias(seat))
    scores.add(%sim.scoreOf(seat))
    win.add(%(sim.scoreOf(seat) > 0))
    gameWinsNode.add(%sim.gameWins(seat))
    survivorsNode.add(%sim.totalSurvivors(seat))
    killsNode.add(%sim.totalKills(seat))
    rewardNode.add(%formatMilli(sim.episodeRewardMilli[seat]))
    policyKinds.add(%sim.seatPolicyKind[seat])
    llmTurns.add(%sim.llmTurns[seat])
    fallbackTurns.add(%sim.fallbackTurns[seat])
    ordersRejected.add(%sim.ordersRejected[seat])
    deadSeats.add(%sim.deadSeats[seat])
  var gameResults = newJArray()
  for record in sim.gameLog:
    gameResults.add(%*{
      "game": record.game,
      "redSlot": record.redSlot,
      "survivors": [record.survivors[0], record.survivors[1]],
      "kills": [record.kills[0], record.kills[1]],
      "ticks": record.ticks,
      "endRule": record.endRule
    })
  $(%*{
    "names": names,
    "aliases": aliases,
    "scores": scores,
    "win": win,
    "winner": winnerNode(sim),
    "reason": sim.endReason,
    "games": sim.gameLog.len,
    "gameWins": gameWinsNode,
    "survivors": survivorsNode,
    "kills": killsNode,
    "finalTick": sim.tick,
    "turnsPlayed": sim.turnsPlayed,
    "seed": sim.config.seed,
    "magentReward": rewardNode,
    "policyKinds": policyKinds,
    "llmTurns": llmTurns,
    "fallbackTurns": fallbackTurns,
    "ordersRejected": ordersRejected,
    "deadSeats": deadSeats,
    "gameResults": gameResults,
    "stopDetail": sim.stopDetail.sanitizeLine(MaxStopDetailRunes)
  })

proc resultRecord*(sim: SimServer): string =
  ## The `result` control record: the whole results document, written once into
  ## the replay chat stream at episode end. It is what makes the replay
  ## self-sufficient -- without it the outcome exists only at
  ## COGAME_RESULTS_URI, which a spectator holding the bytes cannot read. The
  ## document is already valid JSON, so it is embedded verbatim: nothing on the
  ## path to the artifact writes may raise.
  "{\"k\":\"result\",\"results\":" & sim.armyResultsJson() & "}"

proc applyJoinRecords*(sim: var SimServer, data: ReplayData) =
  ## Playback: the real seat names come back out of the join records, which is
  ## what lets the scorebug show them spectator-side.
  for record in data.joins:
    if record.slot >= 0 and record.slot < SeatCount:
      sim.seatNames[record.slot] = record.name
      sim.joined[record.slot] = true

proc applyReplayChat*(sim: var SimServer, text: string) =
  ## Playback: chat records are re-applied into NON-HASHED fields only. A
  ## `register` record restores the policy kind and label; a `fallback` bumps
  ## the seat's counter; a `directive` bumps llmTurns. None of this can affect
  ## the simulation.
  if text.len == 0 or text[0] != '{':
    return
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return
  if node.kind != JObject:
    return
  let kind = node{"k"}.getStr()
  let slot = node{"slot"}.getInt(-1)
  case kind
  of "register":
    if slot >= 0 and slot < SeatCount:
      sim.seatPolicyKind[slot] = node{"kind"}.getStr("scripted")
      sim.seatPolicyLabel[slot] = node{"policy"}.getStr()
      # Mirror the server: the scorebug shows the seat's REAL policy name
      # (spectator side only), and a locally-run config names its seats with
      # the anonymous alias, so the registration label is the better name
      # whenever the join record carried only the alias.
      if sim.seatPolicyLabel[slot].len > 0 and
          sim.seatNames[slot] == seatAlias(slot):
        sim.seatNames[slot] = sim.seatPolicyLabel[slot]
  of "fallback":
    if slot >= 0 and slot < SeatCount and node{"attempt"}.getInt(1) == 2:
      inc sim.fallbackTurns[slot]
  of "directive":
    if slot >= 0 and slot < SeatCount and node{"source"}.getStr() == "llm":
      inc sim.llmTurns[slot]
  of "result":
    let results = node{"results"}
    if not results.isNil and results.kind == JObject:
      sim.endReason = results{"reason"}.getStr(sim.endReason)
  else:
    discard
