## The episode driver: ONE frame of the whole game, shared by the live server
## and by `tests/test_magent_engine.nim`.
##
## Everything that decides the episode lives here -- the command turn, the
## order and chat records, the sim advance, the hash, the wall-clock stop, the
## side swap and the next game. `server.nim` adds only sockets and the
## broadcast; the end-to-end test drives THIS proc, so the test and production
## can never run two different loops (the bullwhip "stale binary" class of bug,
## structurally).

import std/[monotimes, times]
import sim, decide, replays, roster

type
  EpisodeState* = object
    frame*: int
    gamesPlayed*: int
    started*: bool
    stopped*: bool
    finished*: bool
    failureSlot*: int
    lastTurnKey*: int
    turnRecords*: seq[string]

  EpisodeFrame* = object
    ## What the caller needs to know about the frame just run.
    records*: seq[ChatRecord]
    startedGame*: bool
    finishedGame*: bool
    faulted*: bool

proc initEpisodeState*(): EpisodeState =
  result.lastTurnKey = -1
  result.failureSlot = -1

proc maybeStop*(
  state: var EpisodeState, sim: var SimServer, writer: var ReplayWriter,
  elapsedSeconds: int
): bool =
  ## The engine's own hard stop, checked before anything else in a frame. The
  ## stop is written as ONE load-bearing record and applied by `sim.applyStop`
  ## -- the same proc playback calls -- so the hash chain stays clean at the
  ## stop tick (the particle-worlds scar).
  if state.stopped or elapsedSeconds < sim.config.wallClockBudgetSeconds:
    return false
  state.stopped = true
  sim.endReason = ReasonDeadline
  sim.stopDetail = "wall-clock budget of " &
    $sim.config.wallClockBudgetSeconds & "s reached"
  writer.writeStop(state.frame, EndRuleWallClock)
  sim.applyStop(EndRuleWallClock)
  state.finished = true
  true

proc maybeStartFirstGame*(
  state: var EpisodeState, sim: var SimServer, writer: var ReplayWriter
): bool =
  ## Starts game 1 once every seat is seated, or once the lobby budget expires.
  ## A seat that never connects DOES NOT end the episode: it is reported once
  ## to the platform and its army plays the pincer baseline for both games.
  if state.started or sim.phase != Lobby:
    return false
  let ready = sim.seatsJoined() >= sim.config.numAgents
  if not ready and not sim.lobbyJoinTimedOut():
    return false
  if not ready:
    for slot in 0 ..< sim.config.numAgents:
      if not sim.joined[slot]:
        sim.deadSeats[slot] = true
        if state.failureSlot < 0:
          state.failureSlot = slot
  state.started = true
  sim.applyGameStart(0, 0)
  writer.writeGameStart(state.frame, 0, 0)
  true

proc runTurnIfDue*(
  state: var EpisodeState, sim: var SimServer, engine: var DecisionEngine,
  writer: var ReplayWriter, elapsedSeconds: int
) =
  ## One command turn every `turnTicks`, at most once per (game, turn).
  if sim.phase != Playing or sim.tick mod max(1, sim.config.turnTicks) != 0:
    return
  let
    turnIndex = sim.tick div max(1, sim.config.turnTicks) + 1
    turnKey = sim.gameIndex * 1_000_000 + turnIndex
  if turnKey == state.lastTurnKey:
    return
  state.lastTurnKey = turnKey
  sim.emitEvent(TurnStart, amount = turnIndex)
  state.turnRecords = engine.turn(sim, turnIndex, elapsedSeconds)
  inc sim.turnsPlayed
  for record in state.turnRecords:
    writer.writeChat(state.frame, 0, record)
  for seat in 0 ..< SeatCount:
    let directive = sim.directives[seat]
    case directive.source
    of dsLlm: inc sim.llmTurns[seat]
    of dsFallback:
      inc sim.fallbackTurns[seat]
      sim.emitEvent(Fallback, source = seat, amount = turnIndex)
    of dsScripted: discard
    ## `lostLastTurn` was refreshed at the top of `engine.turn`, so this is the
    ## army's losses since the PREVIOUS command turn -- the same rout rule the
    ## feed and the scrubber beat use.
    if sim.lostLastTurn[seat] >= RoutLostThreshold:
      sim.emitEvent(Rout, source = seat, amount = sim.lostLastTurn[seat])
    writer.writeOrders(
      state.frame, sim.gameIndex + 1, turnIndex, seat, directive.orders)
    writer.writeChat(state.frame, seat, directive.boundedDirectiveRecord(
      sim.gameIndex + 1, turnIndex, seat, sim.sideOfSeat(seat),
      engine.lastView[seat]))
    sim.emitEvent(Directive, source = seat, amount = turnIndex,
      detail = $directive.source)

proc advanceEpisodeFrame*(
  state: var EpisodeState, sim: var SimServer, writer: var ReplayWriter
): bool =
  ## Advances the sim by one frame and records its hash. Returns false when a
  ## fault was caught -- the episode is then settled from the last completed
  ## tick, `results.stopDetail` names it, and the artifacts are still written.
  result = true
  try:
    sim.advanceFrame()
  except CatchableError as error:
    sim.endReason = ReasonFault
    sim.stopDetail = error.msg.sanitizeLine(MaxStopDetailRunes)
    writer.writeStop(state.frame, EndRuleFault)
    sim.applyStop(EndRuleFault)
    state.finished = true
    result = false
  writer.writeHash(state.frame, sim.gameHash())

proc maybeNextGame*(
  state: var EpisodeState, sim: var SimServer, writer: var ReplayWriter
): bool =
  ## Banks the finished game and, if another is due, swaps the sides and starts
  ## it. Seat 0 is red in game 1 and blue in game 2, so both seats play the
  ## identical starting position from both sides and upstream's own two-column
  ## spawn asymmetry cancels.
  if state.finished or sim.phase != GameOver or
      sim.gameOverHold < sim.config.gameOverTicks:
    return false
  inc state.gamesPlayed
  result = true
  if state.gamesPlayed >= sim.config.maxGames:
    state.finished = true
    return
  let nextRed = 1 - sim.redSlot
  sim.applyGameStart(state.gamesPlayed, nextRed)
  # frame + 1, NOT frame. This runs AFTER this frame's advance and after this
  # frame's hash was written, so the recorded state for `frame` is still the
  # game-over state of the game just finished. Playback applies every record at
  # the TOP of a frame, so stamping the start with `frame` would reset the board
  # one frame early and hash-mismatch at exactly the game boundary.
  writer.writeGameStart(state.frame + 1, state.gamesPlayed, nextRed)
  state.lastTurnKey = -1

proc runEpisodeFrame*(
  state: var EpisodeState, sim: var SimServer, engine: var DecisionEngine,
  writer: var ReplayWriter, elapsedSeconds: int
): EpisodeFrame =
  ## The whole frame, in the order the design pins.
  if state.maybeStop(sim, writer, elapsedSeconds):
    discard
  result.startedGame = state.maybeStartFirstGame(sim, writer)
  state.turnRecords = @[]
  if not state.finished:
    state.runTurnIfDue(sim, engine, writer, elapsedSeconds)
    result.faulted = not state.advanceEpisodeFrame(sim, writer)
    result.finishedGame = state.maybeNextGame(sim, writer)
  inc state.frame

proc finishEpisode*(
  state: var EpisodeState, sim: var SimServer, writer: var ReplayWriter
) =
  ## Settles and writes the `result` control record -- the whole results
  ## document, once, into the replay chat stream, which is what makes the bytes
  ## self-sufficient.
  for seat in 0 ..< SeatCount:
    if not sim.joined[seat]:
      sim.deadSeats[seat] = true
  if sim.gameLog.len == 0:
    sim.applyStop(EndRuleWallClock)
  writer.writeChat(state.frame, 0, resultRecord(sim))
  writer.closeReplayWriter()

proc runHeadlessEpisode*(
  config: GameConfig, engine: var DecisionEngine, replayPath: string,
  joinSeats: set[uint8] = {0'u8, 1'u8}, maxFrames = 20000
): tuple[sim: SimServer, state: EpisodeState, bytes: string] =
  ## The whole episode with no sockets: the e2e test's driver, and the exact
  ## same per-frame proc the live server calls.
  var
    sim = initSimServer(config)
    state = initEpisodeState()
    writer = openReplayWriter(replayPath, config.configJson())
    started = getMonoTime()
  for seat in 0 ..< SeatCount:
    if uint8(seat) in joinSeats:
      sim.admitSeat(seat, "")
      writer.writeJoin(0, seat, seatAlias(seat), "")
      sim.seatPolicyKind[seat] = engine.policyKind(seat)
  while not state.finished and state.frame < maxFrames:
    let elapsed = (getMonoTime() - started).inSeconds.int
    discard state.runEpisodeFrame(sim, engine, writer, elapsed)
  state.finishEpisode(sim, writer)
  (sim, state, writer.bytes())
