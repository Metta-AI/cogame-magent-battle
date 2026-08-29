## Replay playback: the frame driver, the per-tick hash check, the transport
## commands, and the load-time PRE-SCAN that lets the unit-count sparkline and
## the scrubber beats draw at full width on the very first frame.
##
## The driver is `sim.advanceFrame` -- the SAME proc the live server loop calls
## -- and every fact that cannot be re-derived from sim state (a game start, a
## wall-clock stop) is a recorded record applied by the same proc on both
## sides. That is what keeps the chain clean at the stop tick.

import std/[json, strutils]
import sim, replays

const
  TicksPerSecondBase* = 8
    ## Playback rate at speed 1: eight sim ticks a second, advanced by an
    ## integer accumulator against TargetFps. One MAgent cycle is a whole
    ## exchange of blows and a decided battle runs 30-60 ticks a game, so one
    ## tick per animation frame would flash a whole episode past in four
    ## seconds. At this rate a typical episode plays for ~20 s, which is what
    ## the viewer soak and a human spectator both need.
  LullTicks* = 40
    ## A lull is this many consecutive ticks with no kill.
  ReplayHalfSpeedIndex* = -1
    ## `speedIndex` sentinel for the 1/2x playback speed (command '5'): the
    ## accumulator is fed HALF the base rate, so the board crawls at four sim
    ## ticks a second instead of eight. It is a sentinel rather than a
    ## `PlaybackSpeeds` entry because that array is the engine's INTEGER speed
    ## table, shared with the live loop, which has no fractional pace to give.
    ## `playbackSpeed` clamps the sentinel back to 1x for anything that wants
    ## an integer multiple.

type
  Beat* = object
    tick*: int
    kind*: string
    side*: string
    label*: string

  ReplayPlayer* = object
    data*: ReplayData
    frame*: int
    maxFrame*: int
    playing*: bool
    looping*: bool
    skipLulls*: bool
    speedIndex*: int
    accumulator*: int
    hashMismatchTick*: int
    mismatchQuit*: bool
    orderCursor*: int
    chatCursor*: int
    startCursor*: int
    stopCursor*: int
    feed*: seq[ChatRecord]
    pending*: seq[ChatRecord]
    lulls*: seq[array[2, int]]
    beats*: seq[Beat]
    aliveSeries*: seq[array[3, int]]   ## frame, red alive, blue alive
    gameStartFrames*: seq[int]
    scanned*: bool
    fastForward*: bool

  InitializedReplay* = object
    config*: GameConfig
    sim*: SimServer
    player*: ReplayPlayer

proc playbackSpeed*(player: ReplayPlayer): int =
  ## The integer speed multiple. 1 at 1/2x -- the fractional pace lives in the
  ## accumulator step, not here.
  PlaybackSpeeds[clamp(player.speedIndex, 0, PlaybackSpeeds.high)]

proc replayDisplaySpeed*(player: ReplayPlayer): float =
  ## The speed the chrome shows and highlights a chip for: 0.5 at 1/2x, else
  ## the integer speed.
  if player.speedIndex == ReplayHalfSpeedIndex: 0.5
  else: float(player.playbackSpeed())

proc startFrame*(player: ReplayPlayer): int =
  ## The first game-start frame. Everything before it is the recorded pre-game
  ## lobby (seats joining, LLM registration) with the board frozen at tick 0.
  ## The scrubber axis already begins here (`st` in buildStateJson), so
  ## playback opens here and every seek clamps here -- dwelling on the lobby
  ## held the hosted viewer on its first tick for gameStarts[0].tick / 6
  ## seconds (~45 s on a real ladder episode) before anything moved.
  if player.gameStartFrames.len > 0:
    min(player.gameStartFrames[0], player.maxFrame)
  else:
    0

proc resetCursors(player: var ReplayPlayer) =
  player.frame = 0
  player.orderCursor = 0
  player.chatCursor = 0
  player.startCursor = 0
  player.stopCursor = 0
  player.accumulator = 0
  player.feed = @[]
  player.pending = @[]

proc configFromReplay*(data: ReplayData): GameConfig =
  result = defaultGameConfig()
  result.update(data.configJson)

proc runFrame(player: var ReplayPlayer, sim: var SimServer) =
  ## Applies every record stamped with the current frame, advances the sim by
  ## one frame, then checks the recorded hash.
  player.pending = @[]
  while player.startCursor < player.data.gameStarts.len and
      player.data.gameStarts[player.startCursor].tick == player.frame:
    let record = player.data.gameStarts[player.startCursor]
    sim.applyGameStart(record.gameIndex, record.redSlot)
    inc player.startCursor
  while player.orderCursor < player.data.orders.len and
      player.data.orders[player.orderCursor].tick == player.frame:
    let record = player.data.orders[player.orderCursor]
    if record.slot >= 0 and record.slot < SeatCount:
      var directive = sim.directives[record.slot]
      directive.orders = record.orders
      directive.source = dsScripted
      sim.applyOrders(record.slot, directive)
      sim.turnIndex = record.turn
    inc player.orderCursor
  while player.stopCursor < player.data.stops.len and
      player.data.stops[player.stopCursor].tick == player.frame:
    sim.applyStop(player.data.stops[player.stopCursor].endRule)
    inc player.stopCursor
  while player.chatCursor < player.data.chats.len and
      player.data.chats[player.chatCursor].tick == player.frame:
    player.pending.add(player.data.chats[player.chatCursor])
    player.feed.add(player.data.chats[player.chatCursor])
    inc player.chatCursor
  sim.lastKills = @[]
  sim.advanceFrame()
  # the hash for THIS frame, checked at the tick it happens
  var recorded = -1
  for i in 0 ..< player.data.hashes.len:
    if player.data.hashes[i].tick == player.frame:
      recorded = i
      break
  if recorded >= 0 and player.hashMismatchTick < 0:
    if sim.gameHash() != player.data.hashes[recorded].value:
      player.hashMismatchTick = player.frame
      if player.mismatchQuit:
        raise newException(ReplayError,
          "replay hash mismatch at tick " & $player.frame)
  inc player.frame

proc scanReplay(player: var ReplayPlayer, config: GameConfig) =
  ## The load-time pre-scan: re-simulate the whole episode once headlessly,
  ## recording the per-frame alive counts, the lull spans and the beat ticks.
  ## Integer work over a couple of hundred frames -- single-digit
  ## milliseconds in wasm -- and it is what lets the sparkline and the
  ## scrubber beats draw at FULL WIDTH on the first frame instead of growing
  ## in.
  var sim = initSimServer(config)
  player.resetCursors()
  player.hashMismatchTick = -1
  var
    firstBlood = false
    lastKillFrame = 0
    lastTurnAlive: array[SeatCount, int]
    turnAliveKnown = false
  player.beats = @[]
  player.aliveSeries = @[]
  player.lulls = @[]
  player.gameStartFrames = @[]
  for record in player.data.gameStarts:
    player.gameStartFrames.add(record.tick)
  while player.frame <= player.maxFrame:
    let frame = player.frame
    for record in player.pending:
      discard record
    runFrame(player, sim)
    player.aliveSeries.add([frame,
      sim.units.aliveCount[0], sim.units.aliveCount[1]])
    for kill in sim.lastKills:
      lastKillFrame = frame
      if not firstBlood:
        firstBlood = true
        let side = (if sim.units.soldiers[kill.attacker].army == 0: "red"
                    else: "blue")
        player.beats.add(Beat(
          tick: frame, kind: "firstblood", side: side,
          label: "First blood - " &
            seatAliasName(sim.seatOfArmy(sim.units.soldiers[kill.attacker].army))))
    if frame - lastKillFrame >= LullTicks:
      if player.lulls.len > 0 and player.lulls[^1][1] >= lastKillFrame:
        player.lulls[^1][1] = frame
      else:
        player.lulls.add([lastKillFrame + 1, frame])
    if sim.config.turnTicks > 0 and sim.phase == Playing and
        sim.tick mod sim.config.turnTicks == 0:
      if turnAliveKnown:
        for seat in 0 ..< SeatCount:
          let lost = lastTurnAlive[seat] - sim.survivors(seat)
          if lost >= RoutLostThreshold:
            player.beats.add(Beat(
              tick: frame, kind: "rout",
              side: sim.sideOfSeat(seat),
              label: seatAliasName(seat).toUpperAscii() & " routed - " &
                $lost & " down"))
      for seat in 0 ..< SeatCount:
        lastTurnAlive[seat] = sim.survivors(seat)
      turnAliveKnown = true
    if sim.phase == GameOver and sim.gameOverHold == 1:
      if sim.endRule == EndRuleWipe:
        let army = sim.wipedArmy
        if army == 0 or army == 1:
          player.beats.add(Beat(
            tick: frame, kind: "wipe", side: (if army == 0: "red" else: "blue"),
            label: seatAliasName(sim.seatOfArmy(army)).toUpperAscii() &
              " is wiped out"))
      player.beats.add(Beat(
        tick: frame, kind: "end", side: "",
        label: "Game " & $(sim.gameIndex + 1) & " ends - " & sim.endRule))
  for record in player.data.chats:
    if record.text.len > 0 and record.text[0] == '{' and
        "\"k\":\"fallback\"" in record.text:
      player.beats.add(Beat(
        tick: record.tick, kind: "fallback", side: "",
        label: "A commander missed the call - scripted orders"))
  player.scanned = true

proc initReplayRuntime*(
  data: ReplayData, mismatchQuit = false
): InitializedReplay =
  result.config = configFromReplay(data)
  result.player.data = data
  result.player.maxFrame = max(0, data.frameCount - 1)
  result.player.mismatchQuit = mismatchQuit
  result.player.hashMismatchTick = -1
  result.player.playing = true
  result.player.speedIndex = 0
  scanReplay(result.player, result.config)
  result.player.resetCursors()
  result.player.hashMismatchTick = -1
  result.sim = initSimServer(result.config)
  while result.player.frame <= result.player.startFrame:
    runFrame(result.player, result.sim)

proc seekTo*(player: var ReplayPlayer, sim: var SimServer, frame: int) =
  ## Seeks by re-simulating from frame 0. A couple of hundred integer frames
  ## is microseconds, so a fresh re-derivation is both the simplest and the
  ## most trustworthy seek: the state a viewer scrubs to is always the state
  ## the recorded orders produce.
  let target = clamp(frame, player.startFrame, player.maxFrame)
  let keepMismatch = player.hashMismatchTick
  player.resetCursors()
  player.hashMismatchTick = -1
  sim = initSimServer(sim.config)
  while player.frame <= target:
    runFrame(player, sim)
  if player.hashMismatchTick < 0:
    player.hashMismatchTick = keepMismatch

proc applyCommand*(
  player: var ReplayPlayer, sim: var SimServer, command: string
) =
  ## The transport. Plain single chars from the shared chrome, plus `s:<tick>`
  ## from the scrubber and the labelled beat buttons.
  if command.len == 0:
    return
  if command.startsWith("s:"):
    try:
      player.seekTo(sim, parseInt(command[2 .. ^1].strip()))
    except CatchableError:
      discard
    return
  case command[0]
  of ' ': player.playing = not player.playing
  of 'b': player.seekTo(sim, player.frame - 2)
  of ',': player.seekTo(sim, 0)
  of '.': player.seekTo(sim, player.frame + 5 * TicksPerSecondBase)
  of 'e': player.seekTo(sim, player.maxFrame)
  of 'r': player.looping = not player.looping
  of 'f': player.skipLulls = not player.skipLulls
  of '5': player.speedIndex = ReplayHalfSpeedIndex
  of '1': player.speedIndex = 0
  of '2': player.speedIndex = 1
  of '4': player.speedIndex = 2
  of '8': player.speedIndex = 3
  else: discard

proc inLull(player: ReplayPlayer, frame: int): bool =
  for span in player.lulls:
    if frame >= span[0] and frame <= span[1]:
      return true
  false

proc advanceReplayFrame*(
  player: var ReplayPlayer, sim: var SimServer
) =
  ## One presentation frame. Bounded: at most a handful of sim frames run per
  ## call even when skipping a lull, so a slow browser can never be starved by
  ## the runtime.
  player.fastForward = false
  if not player.playing:
    return
  if player.frame > player.maxFrame:
    if player.looping:
      player.seekTo(sim, 0)
    return
  # The 1/2x speed halves the rate the accumulator is fed instead of adding a
  # frame-parity gate: TicksPerSecondBase is even, so the halved step is exact
  # and the crawl stays evenly spaced (a tick every 7.5 frames) rather than
  # bunching into every other frame.
  let step =
    if player.speedIndex == ReplayHalfSpeedIndex: TicksPerSecondBase div 2
    else: player.playbackSpeed() * TicksPerSecondBase
  player.accumulator += step
  var advanced = 0
  while player.accumulator >= TargetFps and advanced < 8:
    player.accumulator -= TargetFps
    if player.frame > player.maxFrame:
      break
    runFrame(player, sim)
    inc advanced
  if player.skipLulls and player.inLull(player.frame):
    player.fastForward = true
    var skipped = 0
    while player.frame <= player.maxFrame and player.inLull(player.frame) and
        skipped < 64:
      runFrame(player, sim)
      inc skipped

proc beatsJson*(player: ReplayPlayer): JsonNode =
  result = newJArray()
  for beat in player.beats:
    result.add(%*{
      "t": beat.tick, "k": beat.kind, "side": beat.side, "label": beat.label})

proc lullsJson*(player: ReplayPlayer): JsonNode =
  result = newJArray()
  for span in player.lulls:
    result.add(%[span[0], span[1]])

proc leadJson*(player: ReplayPlayer): JsonNode =
  ## The unit-count sparkline: two series over the WHOLE episode, red alive and
  ## blue alive, in the shape chrome_common's momentum graph reads
  ## (`{teams, pts}` with pts = [tick, a, b]).
  var pts = newJArray()
  var last = [-1, -1]
  for sample in player.aliveSeries:
    if sample[1] == last[0] and sample[2] == last[1]:
      continue
    last = [sample[1], sample[2]]
    pts.add(%[sample[0], sample[1], sample[2]])
  %*{"teams": ["red", "blue"], "pts": pts}
