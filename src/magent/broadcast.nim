## The broadcast layer: the per-frame state packet the viewer chrome consumes,
## the roster block, and `stepEvents` -- the derived event stream.
##
## The nine event kinds are DERIVED from state deltas and from the replay's
## chat records during playback, so they cost no replay bytes and are identical
## live and in replay:
##
##   turn {n, game}          order {slot, squad, verb, arg}   say {slot, text}
##   fallback {slot, cause}  firstblood {slot, unit, victim}  kill {a, v, cell}
##   rout {army, lost}       wipe {army}                      end {reason, winner, survivors}
##
## Only `firstblood`, `rout`, `wipe`, `fallback` and `end` become scrubber
## BEATS; `kill`, `turn`, `order` and `say` drive the feed (forty-plus kill
## markers would make the scrubber unreadable).

import std/[json, strutils]
import sim, replays, replay_runtime, roster, global

type
  BroadcastTracker* = object
    firstBloodSeen*: bool
    lastAlive*: array[SeatCount, int]
    sentOnce*: bool

proc initBroadcastTracker*(): BroadcastTracker =
  result.lastAlive = [-1, -1]

proc phaseText*(phase: Phase): string =
  case phase
  of Lobby: "lobby"
  of Playing: "playing"
  of GameOver: "gameover"

proc stepEvents*(
  sim: SimServer, tracker: var BroadcastTracker, chats: seq[ChatRecord]
): JsonNode =
  ## Everything that happened in the frame just stepped, in one array. Pure
  ## function of the sim delta plus the frame's chat records.
  result = newJArray()
  for kill in sim.lastKills:
    let attackerArmy = sim.units.soldiers[kill.attacker].army
    if not tracker.firstBloodSeen:
      tracker.firstBloodSeen = true
      result.add(%*{
        "k": "firstblood",
        "slot": sim.seatOfArmy(attackerArmy),
        "unit": kill.attacker,
        "victim": kill.victim
      })
    result.add(%*{
      "k": "kill",
      "a": sim.seatOfArmy(attackerArmy),
      "v": sim.seatOfArmy(sim.units.soldiers[kill.victim].army),
      "cell": [kill.x, kill.y]
    })
  for seat in 0 ..< SeatCount:
    let alive = sim.survivors(seat)
    if tracker.lastAlive[seat] >= 0 and tracker.lastAlive[seat] - alive >= 10:
      result.add(%*{
        "k": "rout", "army": seat,
        "lost": tracker.lastAlive[seat] - alive})
      tracker.lastAlive[seat] = alive
    elif tracker.lastAlive[seat] < 0 or alive > tracker.lastAlive[seat]:
      tracker.lastAlive[seat] = alive
  for record in chats:
    if record.text.len == 0 or record.text[0] != '{':
      continue
    var node: JsonNode
    try:
      node = parseJson(record.text)
    except CatchableError:
      continue
    if node.kind != JObject:
      continue
    case node{"k"}.getStr()
    of "directive":
      let slot = node{"slot"}.getInt(0)
      result.add(%*{
        "k": "turn", "n": node{"turn"}.getInt(0),
        "game": node{"game"}.getInt(1)})
      for order in node{"orders"}:
        result.add(%*{
          "k": "order", "slot": slot,
          "squad": order{"squad"}.getStr(),
          "verb": order{"verb"}.getStr(),
          "arg": order{"arg"}.getStr()})
      let say = node{"say"}.getStr()
      if say.len > 0:
        result.add(%*{"k": "say", "slot": slot, "text": say})
    of "fallback":
      result.add(%*{
        "k": "fallback", "slot": node{"slot"}.getInt(0),
        "cause": node{"cause"}.getStr()})
    else:
      discard
  if sim.phase == GameOver and sim.gameOverHold == 1:
    if sim.wipedArmy == 0 or sim.wipedArmy == 1:
      result.add(%*{"k": "wipe", "army": sim.seatOfArmy(sim.wipedArmy)})
    result.add(%*{
      "k": "end",
      "reason": sim.endRule,
      "winner": (if sim.scoreOf(0) > 0: 0 elif sim.scoreOf(1) > 0: 1 else: -1),
      "survivors": [sim.survivors(0), sim.survivors(1)]
    })

proc rosterJson*(sim: SimServer): JsonNode =
  ## One entry per seat, in the shape chrome_common's naming and momentum code
  ## already reads. `name` is the REAL policy name (spectator side only);
  ## `alias` is the in-game anonymous name.
  result = newJArray()
  for seat in 0 ..< SeatCount:
    result.add(%*{
      "s": seat,
      "name": sim.seatNames[seat],
      "alias": seatAlias(seat),
      "pol": sim.seatNames[seat],
      "team": sim.sideOfSeat(seat),
      "lives": sim.survivors(seat),
      "alive": sim.survivors(seat) > 0,
      "kind": sim.seatPolicyKind[seat]
    })

proc seatsJson(sim: SimServer): JsonNode =
  result = newJArray()
  for seat in 0 ..< SeatCount:
    result.add(%*{
      "slot": seat,
      "alias": seatAlias(seat).toUpperAscii(),
      "name": sim.seatNames[seat],
      "side": sim.sideOfSeat(seat),
      "alive": sim.survivors(seat),
      "kills": sim.killsOf(seat),
      "fallbacks": sim.fallbackTurns[seat],
      "kind": sim.seatPolicyKind[seat],
      "reward": formatMilli(sim.episodeRewardMilli[seat])
    })

proc teamsJson(sim: SimServer): JsonNode =
  ## `teams[side].lives` is the side's ALIVE COUNT, which is what makes
  ## chrome_common's momentum graph the unit-count sparkline with no change to
  ## that byte-identical file.
  result = newJObject()
  for seat in 0 ..< SeatCount:
    result[sim.sideOfSeat(seat)] = %*{
      "lives": sim.survivors(seat),
      "policies": [sim.seatNames[seat]]
    }

proc endcardJson(sim: SimServer): JsonNode =
  if sim.gameLog.len == 0:
    return newJNull()
  var games = newJArray()
  for record in sim.gameLog:
    games.add(%*{
      "game": record.game,
      "redSlot": record.redSlot,
      "survivors": [record.survivors[0], record.survivors[1]],
      "kills": [record.kills[0], record.kills[1]],
      "ticks": record.ticks,
      "endRule": record.endRule
    })
  %*{
    "games": games,
    "scores": [sim.scoreOf(0), sim.scoreOf(1)],
    "gameWins": [sim.gameWins(0), sim.gameWins(1)],
    "survivors": [sim.totalSurvivors(0), sim.totalSurvivors(1)],
    "kills": [sim.totalKills(0), sim.totalKills(1)],
    "lost": [sim.units.armyCount[0] * sim.gameLog.len - sim.totalSurvivors(0),
             sim.units.armyCount[1] * sim.gameLog.len - sim.totalSurvivors(1)],
    "reward": [formatMilli(sim.episodeRewardMilli[0]),
               formatMilli(sim.episodeRewardMilli[1])],
    "reason": sim.endReason,
    "complete": sim.gameLog.len >= sim.config.maxGames
  }

proc buildStateJson*(
  sim: SimServer,
  player: ReplayPlayer,
  tracker: var BroadcastTracker,
  events: JsonNode,
  live: bool
): string =
  ## One frame. The chrome fields (`t`, `st`, `mx`, `mt`, `ph`, `pl`, `sp`,
  ## `teams`, `roster`, `lulls`, `beats`, `lead`) are the starter's, so
  ## `chrome_common.js` drives the clock, the transport, the scrubber, the
  ## beats and the momentum graph unchanged. Everything this game adds lives
  ## under `mg`.
  ##
  ## LIVE mode has no `ReplayPlayer`: the developer page at `/client/replay`
  ## gets its transport axis from the SIM clock (`tick` of `maxTicks`) instead
  ## of from a default-initialised player, which used to render a static `0 / 1`
  ## playhead. The pre-scanned series (`lulls`, `beats`, `lead`) only exist for
  ## a recorded episode, so live they are OMITTED rather than shipped empty --
  ## an empty `lead` object would disable `chrome_common`'s
  ## accumulate-as-played momentum fallback, which is what a live match wants.
  let
    startFrame =
      if player.gameStartFrames.len > 0: player.gameStartFrames[0] else: 0
    axisTick = if live: sim.tick else: max(0, player.frame - 1)
    axisStart = if live: 0 else: startFrame
    axisMax =
      if live: max(1, sim.config.maxTicks)
      else: max(startFrame + 1, player.maxFrame)
  var node = %*{
    "t": axisTick,
    "st": axisStart,
    "mx": axisMax,
    "mt": sim.config.maxTicks,
    "ph": phaseText(sim.phase),
    "lob": max(0, sim.config.lobbyJoinTimeoutTicks - sim.lobbyTicks),
    "pl": player.playing,
    "lp": player.looping,
    "sk": player.skipLulls,
    "ff": player.fastForward,
    "sp": player.playbackSpeed(),
    "en": true,
    "pov": -1,
    "teams": teamsJson(sim),
    "roster": rosterJson(sim),
    "gv": GameVersion,
    "mg": {
      "board": boardJson(sim),
      "game": sim.gameIndex + 1,
      "games": sim.config.maxGames,
      "turn": sim.turnIndex,
      "turns": sim.turnsPerGame(),
      "tick": sim.tick,
      "maxTicks": sim.config.maxTicks,
      "units": unitsJson(sim),
      "deaths": killsJson(sim),
      "seats": seatsJson(sim),
      "alive": [sim.survivors(0), sim.survivors(1)],
      "kills": [sim.killsOf(0), sim.killsOf(1)],
      "mismatchTick": player.hashMismatchTick,
      "endcard": endcardJson(sim),
      "events": events
    }
  }
  if not tracker.sentOnce and not live:
    tracker.sentOnce = true
    node["lulls"] = player.lullsJson()
    node["beats"] = player.beatsJson()
    node["lead"] = player.leadJson()
  if live:
    node["live"] = %true
  $node
