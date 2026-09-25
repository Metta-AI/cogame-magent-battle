## JSONL training bridge through the game's episode driver and fogged seat view.

import std/[hashes, json]
import sim, decide, episode, replays, roster, baselines, policy_actions

var
  world: SimServer
  engine: DecisionEngine
  driver: EpisodeState
  writer: ReplayWriter
  decisionId: int
  playerCount: int
  pendingSeat: int
  pendingActions: array[SeatCount, seq[int]]

proc dispatchBridge(game, turn, deadlineMs: int,
                    requests: seq[ExternalRequest]) =
  discard game
  discard turn
  discard deadlineMs
  discard requests

proc collectBridge(game, turn, deadlineMs: int,
                   requests: seq[ExternalRequest]): seq[seq[int]] =
  discard game
  discard turn
  discard deadlineMs
  for request in requests: result.add(pendingActions[request.seat])

proc currentDecision(): JsonNode =
  let turn = world.tick div world.config.turnTicks + 1
  var preview = world
  preview.turnIndex = turn
  preview.refreshSeatMemory(turn)
  let view = engine.seatView(preview, pendingSeat, includeNotes = true)
  var properties = newJObject()
  var required = newJArray()
  for squad in 0 ..< SquadCount:
    let name = "squad_" & $squad
    properties[name] = %*{"type": "string", "enum": ActionNames}
    required.add(%name)
  %*{"kind": "decision", "game": "magent-battle",
    "decision_id": decisionId, "seat": pendingSeat,
    "engine_seat": pendingSeat, "turn": turn,
    "semantic_view": view, "inbox": [],
    "messages": [{"role": "user", "content": $view}],
    "speech_messages": [], "action_schema": {"type": "object",
      "properties": properties, "required": required},
    "typed_question": newJNull()}

proc reset(request: JsonNode): JsonNode =
  playerCount = request["players"].getInt()
  doAssert playerCount in 1 .. SeatCount
  var config = defaultGameConfig()
  config.seed = int(hash(request["seed"].getStr()) and hash(high(int)))
  config.turnSpacingMs = 0
  world = initSimServer(config)
  engine = initDecisionEngine(config, enableLlm = false)
  driver = initEpisodeState()
  writer = openReplayWriter("", config.configJson())
  for seat in 0 ..< SeatCount:
    world.admitSeat(seat, seatAliasName(seat))
    writer.writeJoin(0, seat, seatAlias(seat), "")
    engine.seats[seat].isExternal = seat < playerCount
    world.seatPolicyKind[seat] = engine.policyKind(seat)
  engine.externalDispatch = dispatchBridge
  engine.externalCollect = collectBridge
  doAssert driver.maybeStartFirstGame(world, writer)
  decisionId = 0
  pendingSeat = 0
  currentDecision()

proc step(request: JsonNode): JsonNode =
  if request["decision_id"].getInt() != decisionId:
    return %*{"kind": "rejected", "reason": "stale decision"}
  let action = parseJson(request["response"].getStr())
  var selected: seq[int]
  for squad in 0 ..< SquadCount:
    let name = action["squad_" & $squad].getStr()
    var index = -1
    for candidate, label in ActionNames:
      if label == name: index = candidate
    doAssert index >= 0
    selected.add(index)
  pendingActions[pendingSeat] = selected
  inc decisionId
  if pendingSeat + 1 < playerCount:
    inc pendingSeat
    return %*{"kind": "accepted", "action": action,
      "observation": currentDecision()}

  discard driver.runEpisodeFrame(world, engine, writer, 0)
  while not driver.finished and not
      (world.phase == Playing and world.tick mod world.config.turnTicks == 0 and
        world.gameIndex * 1_000_000 +
        world.tick div world.config.turnTicks + 1 != driver.lastTurnKey):
    discard driver.runEpisodeFrame(world, engine, writer, 0)
  pendingSeat = 0
  if driver.finished:
    driver.finishEpisode(world, writer)
    var scores = newJObject()
    var utilities = newJObject()
    for seat in 0 ..< playerCount:
      let score = world.scoreOf(seat)
      scores[$seat] = %score
      utilities[$seat] = %(score.float / 362.0)
    return %*{"kind": "accepted", "action": action,
      "observation": {"kind": "terminal", "scores": scores,
        "utilities": utilities}}
  %*{"kind": "accepted", "action": action,
    "observation": currentDecision()}

proc teacher(): JsonNode =
  let directive = scriptedDirective(world, pendingSeat, blPincer,
    engine.pincerParams)
  var response = newJObject()
  for squad, order in directive.orders:
    var action = 0
    case order.kind
    of okAdvance: action = 0
    of okRetreat: action = 1
    of okFlank: action = if order.side == fsLeft: 2 else: 3
    of okFocus: action = 4 + order.target
    of okHold:
      let col = min(2, order.x * 3 div world.config.mapSize)
      let row = min(2, order.y * 3 div world.config.mapSize)
      action = 13 + row * 3 + col
    response["squad_" & $squad] = %ActionNames[action]
  %*{"response": $response}

when isMainModule:
  for line in stdin.lines:
    let request = parseJson(line)
    let response = case request["kind"].getStr()
      of "reset": reset(request)
      of "encode":
        var preview = world
        preview.turnIndex = world.tick div world.config.turnTicks + 1
        preview.refreshSeatMemory(preview.turnIndex)
        %*{"decision_id": decisionId,
          "values": values(engine.seatView(preview, pendingSeat,
            includeNotes = true)), "action_heads": actionHeads()}
      of "teacher": teacher()
      of "step": step(request)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
