## The decision layer: the per-turn loop that asks both commanders what their
## nine squads do next, and always has an answer.
##
## Cadence: one turn every `turnTicks` (20 ticks), 15 turns per game, 30 per
## episode. At each turn the server builds BOTH seats' request bodies and
## issues them as ONE parallel batch -- this is a simultaneous-decision game,
## so querying seats one after another would double the wall clock for nothing.
##
## DEGRADE, NEVER HANG. Every wait is bounded: attempt 1 gets `attempt1Ms`, the
## single retry gets `retryMs`, and the whole turn sits inside a monotonic
## `turnBudgetMs` deadline. A provider throttle with no other candidate model
## skips the retry outright. On a second failure the seat plays the `pincer`
## scripted directive for that turn and a `fallback` record names the cause.
## No failure mode leaves a soldier unactuated: the control layer always has a
## directive -- this turn's, else last turn's, else `pincer`'s.

import std/[json, monotimes, os, strutils, times]
import curly
import sim, baselines, llm

type
  SeatPolicy* = object
    ## What one seat registered as. A seat that registers with neither field --
    ## or never registers at all -- is `pincer`.
    isLlm*: bool
    prompt*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    client*: LlmClient
    seats*: array[SeatCount, SeatPolicy]
    notes*: array[SeatCount, string]
    lastBatchStart*: MonoTime
    batchStarted*: bool
    llmOff*: bool              ## the budget guard fired; scripted from here on
    lastView*: array[SeatCount, JsonNode]
    pincerParams*: BaselineParams
      ## The swept tunables (tools/tune_baselines.nim). Held on the engine so
      ## the sweep can drive a whole episode with one candidate set without
      ## touching the shipped defaults.

proc initDecisionEngine*(config: GameConfig): DecisionEngine =
  result.client = newLlmClient(config)
  result.pincerParams = DefaultBaselineParams
  for seat in 0 ..< SeatCount:
    result.seats[seat].baseline = DefaultBaseline
    result.seats[seat].label = $DefaultBaseline
    result.lastView[seat] = newJNull()

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < SeatCount and engine.seats[seat].isLlm: "llm"
  else: "scripted"

# ---------------------------------------------------------------------------
#  The per-seat view
# ---------------------------------------------------------------------------

proc seatView*(
  engine: DecisionEngine, sim: SimServer, seat: int, includeNotes: bool
): JsonNode =
  ## Everything this seat may legitimately know. Enemy soldiers appear only
  ## where one of the seat's OWN living soldiers is within CircleRange(6) --
  ## MAgent's `view_range`, lifted to army scale. The opponent's orders,
  ## notes, real name, policy name and fallback statistics are never in here,
  ## and no real policy name ever is: the seats are Alpha and Bravo.
  let
    army = sim.armyOfSeat(seat)
    enemyArmy = 1 - army
    enemySeat = 1 - seat
  var
    squads = newJArray()
    myAlive = 0
  for k in 0 ..< SquadCount:
    let stat = squadStat(sim.units, army, k)
    myAlive += stat.alive
    squads.add(%*{
      "id": squadAlias(seat, k),
      "alive": stat.alive,
      "x": stat.x,
      "y": stat.y,
      "hp": hpText(stat.hpTenths),
      "order": $sim.directives[seat].orders[k].kind
    })
  var
    enemy = newJArray()
    seenTotal = 0
  for k in 0 ..< SquadCount:
    let stat = visibleSquadStat(sim.units, army, enemyArmy, k)
    seenTotal += stat.alive
    var entry = %*{
      "id": squadAlias(enemySeat, k),
      "seen": stat.alive
    }
    if stat.alive > 0:
      entry["x"] = %stat.x
      entry["y"] = %stat.y
      entry["hp"] = %hpText(stat.hpTenths)
    else:
      entry["x"] = newJNull()
      entry["y"] = newJNull()
      entry["hp"] = newJNull()
    if sim.lastSeenTurn[seat][k] >= 0:
      entry["last_seen_turn"] = %sim.lastSeenTurn[seat][k]
    else:
      entry["last_seen_turn"] = newJNull()
    enemy.add(entry)
  result = %*{
    "you": seatAliasName(seat),
    "opponent": seatAliasName(enemySeat),
    "game": sim.gameIndex + 1,
    "of_games": sim.config.maxGames,
    "your_side": sim.sideOfSeat(seat),
    "turn": sim.turnIndex,
    "of": sim.turnsPerGame(),
    "tick": sim.tick,
    "turn_ticks": sim.config.turnTicks,
    "ticks_left": max(0, sim.config.maxTicks - sim.tick),
    "map": {"width": sim.config.mapSize, "height": sim.config.mapSize},
    "soldier": {
      "hp_max": hpText(HpMax),
      "damage": hpText(Damage),
      "recover_per_tick": hpText(StepRecover),
      "move_up_to": Speed,
      "attack_reach": 1,
      "view_radius": ViewRadius
    },
    "your_army": {
      "alive": myAlive,
      "started": sim.units.armyCount[army],
      "lost_last_turn": sim.lostLastTurn[seat],
      "squads": squads
    },
    "enemy": {
      "visible_soldiers": seenTotal,
      "killed_last_turn": sim.enemyKilledLastTurn[seat],
      "squads": enemy
    },
    "score_now": sim.survivors(seat) - sim.survivors(1 - seat)
  }
  if includeNotes:
    result["your_notes"] = %engine.notes[seat]

proc refreshSeatMemory*(sim: var SimServer, turnIndex: int) =
  ## Per-turn bookkeeping the observation reads: which enemy squads each seat
  ## can see right now, and what each side lost since the previous turn. Not
  ## hashed -- it only ever reaches a prompt and a replay `view`.
  for seat in 0 ..< SeatCount:
    let
      army = sim.armyOfSeat(seat)
      enemyArmy = 1 - army
    for k in 0 ..< SquadCount:
      if visibleSquadStat(sim.units, army, enemyArmy, k).alive > 0:
        sim.lastSeenTurn[seat][k] = turnIndex
    sim.lostLastTurn[seat] =
      max(0, sim.aliveAtTurnStart[seat] - sim.survivors(seat))
  for seat in 0 ..< SeatCount:
    sim.enemyKilledLastTurn[seat] = sim.lostLastTurn[1 - seat]
  for seat in 0 ..< SeatCount:
    sim.aliveAtTurnStart[seat] = sim.survivors(seat)

# ---------------------------------------------------------------------------
#  Records
# ---------------------------------------------------------------------------

proc fallbackRecord*(
  game, turn, seat, attempt: int, cause, detail: string
): string =
  $(%*{
    "k": "fallback",
    "game": game,
    "turn": turn,
    "slot": seat,
    "attempt": attempt,
    "cause": cause,
    "detail": detail.sanitizeLine(MaxFallbackDetailRunes)
  })

proc registerRecord*(seat: int, policy, kind, baseline: string): string =
  ## The REDACTED registration record. The seat's prompt is never written:
  ## only the policy label, the kind, and which baseline a scripted seat picked.
  $(%*{
    "k": "register",
    "slot": seat,
    "alias": seatAliasName(seat),
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind,
    "baseline": baseline
  })

proc budgetGuardRecord*(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})

# ---------------------------------------------------------------------------
#  The turn
# ---------------------------------------------------------------------------

proc turn*(
  engine: var DecisionEngine,
  sim: var SimServer,
  turnIndex, elapsedSeconds: int
): seq[string] =
  ## Runs ONE decision turn and installs each seat's directive. Returns the
  ## replay chat records this turn produced. Never raises: every failure path
  ## ends in a legal directive.
  let
    game = sim.gameIndex + 1
    budget = initDuration(milliseconds = max(1, sim.config.turnBudgetMs))
    turnStart = getMonoTime()
  sim.turnIndex = turnIndex
  sim.refreshSeatMemory(turnIndex)
  engine.client.throttled = false

  # --- budget guard: settle EARLY rather than overrun -----------------------
  if not engine.llmOff:
    let turnSeconds = (sim.config.turnBudgetMs + 999) div 1000
    if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
      engine.llmOff = true
      result.add(budgetGuardRecord(
        turnIndex, max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "magent: budget guard fired at turn ", turnIndex,
        "; remaining turns play scripted"

  # --- which seats need a call? --------------------------------------------
  var open: seq[int]
  for seat in 0 ..< SeatCount:
    engine.lastView[seat] = engine.seatView(sim, seat, includeNotes = false)
    if engine.seats[seat].isLlm and not engine.llmOff and
        not engine.client.disabled:
      open.add(seat)
    elif engine.seats[seat].isLlm:
      # An LLM seat that CANNOT call the LLM this turn is a fallback, not a
      # scripted policy, and the design's cause enum names both reasons.
      var directive = fallbackDirective(sim, seat, engine.pincerParams)
      directive.say = ""
      sim.applyOrders(seat, directive)
      let cause = if engine.llmOff: "budget_guard" else: "no_credentials"
      result.add(fallbackRecord(game, turnIndex, seat, 1, cause,
        "the LLM is unavailable for this turn; playing pincer"))
      echo "magent llm: seat ", seat, " falling back to pincer (", cause,
        ") on turn ", turnIndex
    else:
      var directive = scriptedDirective(
        sim, seat, engine.seats[seat].baseline, engine.pincerParams)
      sim.applyOrders(seat, directive)
      if not sim.joined[seat]:
        ## Nobody is home on this seat: its army is on autopilot for the whole
        ## episode, and the replay says WHY rather than looking like a
        ## deliberate scripted filler. `results.deadSeats` carries the same
        ## fact once; this carries it per turn, where a reader of the chat
        ## stream is looking.
        result.add(fallbackRecord(game, turnIndex, seat, 1, "disconnected",
          "seat never joined; its army plays the scripted baseline"))

  # --- the rate floor -------------------------------------------------------
  # The Bedrock sidecar caps 30 requests/minute PER EPISODE and two seats at a
  # fast turn sit right on it. Hold the START of consecutive batches
  # `turnSpacingMs` apart, which pins the episode at <= 15 req/min.
  if open.len > 0 and engine.batchStarted and sim.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < sim.config.turnSpacingMs:
      sleep(min(sim.config.turnSpacingMs, sim.config.turnSpacingMs - since))
  if open.len > 0:
    engine.lastBatchStart = getMonoTime()
    engine.batchStarted = true

  # --- up to two PARALLEL batches ------------------------------------------
  var attempt = 0
  while open.len > 0 and attempt < 2:
    if engine.client.disabled:
      break
    if getMonoTime() - turnStart >= budget:
      for seat in open:
        result.add(fallbackRecord(
          game, turnIndex, seat, attempt + 1, "timeout",
          "per-turn budget exhausted before attempt " & $(attempt + 1)))
      break
    let deadlineMs =
      if attempt == 0: sim.config.attempt1Ms else: sim.config.retryMs
    var batch: RequestBatch
    for seat in open:
      var view = engine.seatView(sim, seat, includeNotes = true)
      var user = $view
      if attempt > 0:
        user.add("\n\nYour previous reply was not usable. Reply with ONLY " &
          "the JSON object described above, starting with '{', with one " &
          "\"orders\" entry per squad you want to re-task.")
      let request = engine.client.requestFor(
        SystemPrompt, userMessage(engine.seats[seat].prompt, user))
      batch.post(request.url, request.headers, request.body, $seat)
    let started = getMonoTime()
    # curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is WHOLE
    # SECONDS, so this conversion FLOORS. sim_config rejects a sub-second
    # value, so the floor is an identity: 9000 -> 9 s inside turnBudgetMs 14 s.
    let responses = engine.client.curl.makeRequests(
      batch, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    var stillOpen: seq[int]
    for position, seat in open:
      var cause = "parse_error"
      try:
        let text = engine.client.textOf(
          responses[position].response, responses[position].error,
          batch[position].url)
        var directive = parseArmyDirective(
          extractJsonObject(text), seat, sim.directives[seat],
          sim.config.mapSize)
        directive.source = dsLlm
        directive.latencyMs = latency
        engine.notes[seat] = directive.notes
        sim.ordersRejected[seat] += directive.rejected
        sim.applyOrders(seat, directive)
      except CatchableError as error:
        if responses[position].error.len > 0:
          cause = (if "timeout" in responses[position].error.toLowerAscii():
                     "timeout" else: "transport_error")
        elif error.msg.startsWith("llm throttled"):
          cause = "throttled"
        result.add(fallbackRecord(
          game, turnIndex, seat, attempt + 1, cause, error.msg))
        echo "magent llm: seat ", seat, " attempt ", attempt + 1,
          " failed, falling back if it fails again: ", error.msg
        stillOpen.add(seat)
    open = stillOpen
    inc attempt
    if engine.client.throttled and open.len > 0:
      # FAIL FAST. The only model left answered 429, so the retry batch would
      # be refused the same way.
      echo "magent llm: provider throttled with no other candidate; ",
        open.len, " seat(s) fall back for turn ", turnIndex
      break

  # --- anything still open plays pincer for this turn -----------------------
  for seat in open:
    var directive = fallbackDirective(sim, seat, engine.pincerParams)
    directive.say = ""
    sim.applyOrders(seat, directive)
    let cause =
      if engine.client.disabled or engine.client.transport == ltNone:
        "no_credentials"
      elif engine.llmOff: "budget_guard"
      elif engine.client.throttled: "throttled"
      else: "parse_error"
    result.add(fallbackRecord(game, turnIndex, seat, 2, cause,
      "seat fell back to the pincer directive"))
    ## "falling back" is the phrase phase 60 greps the GAME log for.
    echo "magent llm: seat ", seat, " falling back to pincer (", cause,
      ") on turn ", turnIndex
