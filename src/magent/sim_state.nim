## Sim state: the server object every module reads, the `gameHash` chain the
## replay integrity check runs on, the event sink, and the lobby / game-over
## lifecycle.

import std/strutils
import sim_types, units, directives, events

type
  GameRecord* = object
    game*: int
    redSlot*: int
    survivors*: array[SeatCount, int]
    kills*: array[SeatCount, int]
    ticks*: int
    endRule*: string

  SimServer* = object
    config*: GameConfig
    units*: Units
    tick*: int                ## ticks elapsed in the CURRENT game
    episodeTick*: int         ## ticks elapsed across the whole episode
    gameIndex*: int           ## 0-based
    redSlot*: int             ## which seat holds red in the current game
    phase*: Phase
    lobbyTicks*: int
    gameOverHold*: int
    turnIndex*: int           ## 1-based command turn within the current game
    turnsPlayed*: int         ## decision turns run across the episode
    endReason*: string
    endRule*: string
    stopDetail*: string
    gameLog*: seq[GameRecord]

    directives*: array[SeatCount, ArmyDirective]
    haveDirective*: array[SeatCount, bool]
    lastSeenTurn*: array[SeatCount, array[SquadCount, int]]
    aliveAtTurnStart*: array[SeatCount, int]
    enemyKilledLastTurn*: array[SeatCount, int]
    lostLastTurn*: array[SeatCount, int]

    killsByArmy*: array[2, int]
    rewardMilli*: array[2, int]
    episodeRewardMilli*: array[SeatCount, int]

    seatNames*: array[SeatCount, string]
    seatAliases*: array[SeatCount, string]
    seatPolicyKind*: array[SeatCount, string]
    seatPolicyLabel*: array[SeatCount, string]
    llmTurns*: array[SeatCount, int]
    fallbackTurns*: array[SeatCount, int]
    ordersRejected*: array[SeatCount, int]
    deadSeats*: array[SeatCount, bool]
    joined*: array[SeatCount, bool]

    gameHashValue*: uint64
    collectEvents*: bool
    events*: seq[SimEvent]
    lastKills*: seq[tuple[tick, attacker, victim, x, y: int]]
    wipedArmy*: int

proc seatOfArmy*(sim: SimServer, army: int): int {.inline.} =
  if army == 0: sim.redSlot else: 1 - sim.redSlot

proc armyOfSeat*(sim: SimServer, seat: int): int {.inline.} =
  if seat == sim.redSlot: 0 else: 1

proc sideOfSeat*(sim: SimServer, seat: int): string {.inline.} =
  if seat == sim.redSlot: "red" else: "blue"

proc survivors*(sim: SimServer, seat: int): int {.inline.} =
  sim.units.aliveCount[sim.armyOfSeat(seat)]

proc killsOf*(sim: SimServer, seat: int): int {.inline.} =
  sim.killsByArmy[sim.armyOfSeat(seat)]

proc turnsPerGame*(sim: SimServer): int {.inline.} =
  max(1, sim.config.maxTicks div max(1, sim.config.turnTicks))

proc mixHash*(value: var uint64, item: int) {.inline.} =
  ## FNV-1a over the 64-bit two's-complement image of `item`. Integer only, so
  ## the native build and the wasm32 build mix identically.
  var bits = cast[uint64](int64(item))
  for _ in 0 ..< 8:
    value = value xor (bits and 0xff'u64)
    value = value * 0x100000001b3'u64
    bits = bits shr 8

proc emitEvent*(
  sim: var SimServer, kind: SimEventKind, source = -1, target = -1,
  amount = 0, detail = ""
) =
  if not sim.collectEvents:
    return
  sim.events.add(SimEvent(
    kind: kind, tick: sim.tick, game: sim.gameIndex + 1, source: source,
    target: target, amount: amount, detail: detail))

proc resetToLobby*(sim: var SimServer) =
  ## Between the two games of an episode. The seats, their policies and the
  ## episode-level counters survive; the board, the orders and the per-game
  ## counters do not.
  sim.units = initUnits(sim.config.mapSize)
  sim.tick = 0
  sim.turnIndex = 0
  sim.phase = Lobby
  sim.lobbyTicks = 0
  sim.gameOverHold = 0
  sim.endRule = ""
  sim.killsByArmy = [0, 0]
  sim.rewardMilli = [0, 0]
  sim.wipedArmy = -1
  sim.lastKills = @[]
  for seat in 0 ..< SeatCount:
    sim.directives[seat] = defaultDirective()
    sim.haveDirective[seat] = false
    sim.aliveAtTurnStart[seat] = 0
    sim.enemyKilledLastTurn[seat] = 0
    sim.lostLastTurn[seat] = 0
    for k in 0 ..< SquadCount:
      sim.lastSeenTurn[seat][k] = -1

proc initSimServer*(config: GameConfig): SimServer =
  result.config = config
  result.redSlot = 0
  result.endReason = ReasonComplete
  result.gameHashValue = 0xcbf29ce484222325'u64
  for seat in 0 ..< SeatCount:
    result.seatAliases[seat] = seatAliasName(seat)
    result.seatNames[seat] = seatAliasName(seat)
    result.seatPolicyKind[seat] = "scripted"
    result.seatPolicyLabel[seat] = "pincer"
  result.resetToLobby()

proc startGame*(sim: var SimServer) =
  sim.phase = Playing
  sim.tick = 0
  sim.turnIndex = 0
  for seat in 0 ..< SeatCount:
    sim.aliveAtTurnStart[seat] = sim.survivors(seat)

proc lobbyJoinTimedOut*(sim: SimServer): bool =
  sim.phase == Lobby and sim.lobbyTicks >= sim.config.lobbyJoinTimeoutTicks

proc gameHash*(sim: SimServer): uint64 =
  ## The per-tick integrity chain. Mix order is FIXED: per soldier, then per
  ## army, then per squad order, then the clock. One divergent bit between the
  ## native writer and the wasm re-simulation is caught at the tick it happens.
  result = 0xcbf29ce484222325'u64
  for id in 0 ..< sim.units.soldiers.len:
    let soldier = sim.units.soldiers[id]
    result.mixHash(id)
    result.mixHash(soldier.x)
    result.mixHash(soldier.y)
    result.mixHash(soldier.hp)
    result.mixHash(if soldier.alive: 1 else: 0)
  for army in 0 ..< 2:
    result.mixHash(sim.units.aliveCount[army])
    result.mixHash(sim.killsByArmy[army])
    result.mixHash(sim.rewardMilli[army])
  for seat in 0 ..< SeatCount:
    for k in 0 ..< SquadCount:
      let order = sim.directives[seat].orders[k]
      result.mixHash(ord(order.kind))
      result.mixHash(order.x)
      result.mixHash(order.y)
      result.mixHash(order.target)
      result.mixHash(ord(order.side))
  result.mixHash(sim.tick)
  result.mixHash(sim.gameIndex)
  result.mixHash(sim.redSlot)

proc scoreOf*(sim: SimServer, seat: int): int =
  ## `sum over games of (100 * outcome + survivors[you] - survivors[them])`.
  ## Exactly zero-sum: score[0] + score[1] == 0 always. Higher is better.
  let other = 1 - seat
  for record in sim.gameLog:
    var outcome = 0
    if record.survivors[seat] > record.survivors[other]: outcome = 1
    elif record.survivors[seat] < record.survivors[other]: outcome = -1
    result += 100 * outcome + record.survivors[seat] - record.survivors[other]

proc bankGame*(sim: var SimServer, endRule: string) =
  ## Archives the current game. Called by the SAME proc on record and on
  ## playback, so a wall-clock stop re-derives identically.
  var record = GameRecord(
    game: sim.gameIndex + 1, redSlot: sim.redSlot, ticks: sim.tick,
    endRule: endRule)
  for seat in 0 ..< SeatCount:
    record.survivors[seat] = sim.survivors(seat)
    record.kills[seat] = sim.killsOf(seat)
  for seat in 0 ..< SeatCount:
    sim.episodeRewardMilli[seat] += sim.rewardMilli[sim.armyOfSeat(seat)]
  sim.gameLog.add(record)
  sim.endRule = endRule
  sim.phase = GameOver
  sim.gameOverHold = 0
  sim.emitEvent(PhaseChange, amount = sim.gameIndex + 1, detail = endRule)

proc totalSurvivors*(sim: SimServer, seat: int): int =
  for record in sim.gameLog:
    result += record.survivors[seat]

proc totalKills*(sim: SimServer, seat: int): int =
  for record in sim.gameLog:
    result += record.kills[seat]

proc gameWins*(sim: SimServer, seat: int): int =
  let other = 1 - seat
  for record in sim.gameLog:
    if record.survivors[seat] > record.survivors[other]:
      inc result

proc rewardOf*(sim: SimServer, seat: int): int =
  ## Accumulated MAgent reward for a seat across the whole EPISODE, in
  ## thousandths: banked games plus the game in progress. Recorded, never
  ## scored -- it is the port's fidelity evidence and a spectator readout, and
  ## scoring off it would reward attack-spam over winning.
  sim.episodeRewardMilli[seat] +
    (if sim.gameLog.len > sim.gameIndex: 0
     else: sim.rewardMilli[sim.armyOfSeat(seat)])

proc formatMilli*(milli: int): string =
  ## A thousandths integer as its decimal string, with no float anywhere on
  ## the path: `-238090` -> `-238.09`.
  let negative = milli < 0
  var value = (if negative: -milli else: milli)
  let
    whole = value div 1000
    frac = value mod 1000
  var fracText = align($frac, 3, '0')
  while fracText.len > 1 and fracText[^1] == '0':
    fracText.setLen(fracText.len - 1)
  (if negative: "-" else: "") & $whole & "." & fracText

proc hpText*(tenths: int): string =
  ## Mean hp in upstream units to one decimal, integer-only.
  let negative = tenths < 0
  let value = (if negative: -tenths else: tenths)
  (if negative: "-" else: "") & $(value div 10) & "." & $(value mod 10)

proc parseHashHex*(text: string): uint64 =
  parseBiggestUInt("0x" & text).uint64

proc gameHashHex*(sim: SimServer): string =
  toHex(sim.gameHash())
