## End-to-end episodes, driven through the SAME `episode.nim` frame proc the
## live server calls -- so the test and production can never run two different
## loops.

import std/[json, os, sets, strutils, unittest]
import helpers
import magent/[broadcast, replay_runtime, roster]

proc resultKeys(sim: SimServer): HashSet[string] =
  for key, _ in parseJson(sim.armyResultsJson()).pairs:
    result.incl(key)

suite "magent engine":

  test "episode writes artifacts":
    let path = getTempDir() / "magent-engine-episode.replay"
    removeFile(path)
    var config = testConfig(mapSize = 31, maxTicks = 100)
    let run = runScriptedEpisode(config, path)
    check fileExists(path)
    check getFileSize(path) > 1000
    let results = parseJson(run.sim.armyResultsJson())
    check results["reason"].getStr() == ReasonComplete
    check results["scores"][0].getInt() + results["scores"][1].getInt() == 0
    check results["games"].getInt() == config.maxGames
    check run.sim.gameLog.len == config.maxGames
    ## both games appear with OPPOSITE redSlot -- the side swap
    check run.sim.gameLog[0].redSlot != run.sim.gameLog[1].redSlot
    check results["gameResults"].len == config.maxGames
    check results["aliases"][0].getStr() == "Alpha"
    check results["aliases"][1].getStr() == "Bravo"
    ## the results key set equals the manifest's results_schema key set EXACTLY
    var declared: HashSet[string]
    for key, _ in manifestJson()["game"]["results_schema"]["properties"].pairs:
      declared.incl(key)
    check resultKeys(run.sim) == declared
    removeFile(path)

  test "no seat can stall":
    ## A seat that never connects at all does not end the episode: it is
    ## reported once with the platform's CLOSED payload, its army plays the
    ## pincer baseline, and both games run to their natural end.
    var config = testConfig(mapSize = 31, maxTicks = 60)
    let run = runScriptedEpisode(config, "", joinSeats = {0'u8})
    check run.state.finished
    check run.sim.gameLog.len == config.maxGames
    check run.sim.endReason == ReasonComplete
    check run.sim.deadSeats[1]
    check not run.sim.deadSeats[0]
    check run.state.failureSlot == 1
    ## exactly the platform's two keys, and nothing else -- asserted against the
    ## payload the SERVER writes (roster.playerFailurePayload, called by
    ## server.declarePlayerFailure), not against a literal this test builds
    let payload = parseJson(playerFailurePayload(
      run.state.failureSlot,
      "player slot 1 never joined the lobby within 1 lobby ticks; its army " &
      "plays the pincer baseline"))
    var keys: HashSet[string]
    for key, _ in payload.pairs:
      keys.incl(key)
    check keys == ["message", "failed_policy_index"].toHashSet()
    check payload["failed_policy_index"].getInt() == 1
    check payload["message"].getStr().len > 0
    ## and every turn of the empty seat is recorded with cause `disconnected`,
    ## so a replay reader can tell "nobody was home" from "a scripted filler
    ## was seated" (r1 review F8)
    var disconnected = 0
    for record in parseReplayBytes(run.bytes).chats:
      if "\"k\":\"fallback\"" in record.text:
        let node = parseJson(record.text)
        check node["slot"].getInt() == 1
        check node["cause"].getStr() == "disconnected"
        inc disconnected
    check disconnected > 0

  test "an LLM seat with no credentials counts as a fallback, not a score":
    ## The client disables itself with no credentials, so every turn is a
    ## fallback and both are COUNTABLE -- llmTurns 0 with fallbackTurns 0 for an
    ## episode that was nothing but fallbacks is the bug this asserts against.
    var config = testConfig(mapSize = 31, maxTicks = 60)
    var engine = initDecisionEngine(config)
    engine.seats[0].isLlm = true
    engine.seats[0].prompt = "win by concentration"
    engine.seats[0].label = "vanguard"
    engine.seats[1].baseline = blLine
    let run = runHeadlessEpisode(config, engine, "")
    check run.sim.llmTurns[0] == 0
    check run.sim.fallbackTurns[0] > 0
    check run.sim.fallbackTurns[1] == 0
    check run.sim.endReason == ReasonComplete
    check run.sim.gameLog.len == config.maxGames

  test "the tier-2 event stream emits every kind it declares":
    ## `events.SimEventKind` declares eight kinds and three of them --
    ## TurnStart, Fallback and Rout -- had no emit site at all, so they could
    ## never appear in a COGAME_EVENTS_URI stream (r1 review F15). Driven at one
    ## command turn so the rout is exact rather than a hope about the sim.
    var sim = playingSim(31)
    sim.collectEvents = true
    ## 12 of army 0 die between the first command turn and the next one
    var killed = 0
    for id in 0 ..< sim.units.soldiers.len:
      if killed >= RoutLostThreshold + 2:
        break
      if sim.units.soldiers[id].army == 0 and sim.units.soldiers[id].alive:
        sim.units.soldiers[id].alive = false
        dec sim.units.aliveCount[0]
        inc killed
    check killed == RoutLostThreshold + 2
    sim.tick = sim.config.turnTicks           ## the next turn is due
    var engine = initDecisionEngine(sim.config)
    engine.seats[0].isLlm = true              ## no credentials: it falls back
    engine.seats[0].prompt = "hold the centre"
    var state = initEpisodeState()
    var writer = openReplayWriter("", sim.config.configJson())
    state.runTurnIfDue(sim, engine, writer, 0)
    var kinds: HashSet[string]
    for event in sim.events:
      kinds.incl($event.kind)
    checkpoint("emitted kinds: " & $kinds)
    for kind in ["turn_start", "fallback", "rout", "directive"]:
      checkpoint(kind)
      check kind in kinds
    ## the mandatory summary row still closes the stream
    let stream = eventsJsonl(sim.events, sim.tick)
    check "\"type\":\"summary\"" in stream
    check stream.endsWith("\n")

  test "budget guard settles early":
    ## With the guard forced (a wall-clock budget smaller than two turns), the
    ## LLM is switched off for the rest of the episode, a budget_guard record
    ## names the turn, and the episode still ends `complete` -- not `deadline`.
    var config = testConfig(mapSize = 31, maxTicks = 60)
    config.wallClockBudgetSeconds = 10
    config.turnBudgetMs = 14000
    var engine = initDecisionEngine(config)
    engine.seats[0].isLlm = true
    engine.seats[0].prompt = "hold the line"
    engine.seats[1].isLlm = true
    engine.seats[1].prompt = "charge"
    let records = engine.turn(
      (var sim = initSimServer(config); sim.applyGameStart(0, 0); sim), 1, 0)
    check engine.llmOff
    var sawGuard = false
    for record in records:
      if "\"k\":\"budget_guard\"" in record:
        sawGuard = true
        let node = parseJson(record)
        check node["turn"].getInt() == 1
    check sawGuard
    let run = runHeadlessEpisode(config, engine, "")
    check run.sim.endReason == ReasonComplete

  test "the wall-clock stop settles and reports deadline":
    var config = testConfig(mapSize = 45, maxTicks = 300)
    var engine = scriptedEngine(config)
    var sim = initSimServer(config)
    var state = initEpisodeState()
    var writer = openReplayWriter("", config.configJson())
    for seat in 0 ..< SeatCount:
      sim.admitSeat(seat, "")
    ## drive a handful of frames, then hand the driver an elapsed time past the
    ## budget: the stop is recorded and applied by sim.applyStop
    for _ in 0 ..< 40:
      discard state.runEpisodeFrame(sim, engine, writer, 0)
    discard state.runEpisodeFrame(
      sim, engine, writer, config.wallClockBudgetSeconds)
    check state.stopped
    check state.finished
    check sim.endReason == ReasonDeadline
    check sim.gameLog[^1].endRule == EndRuleWallClock
    check sim.stopDetail.len > 0
    state.finishEpisode(sim, writer)
    let results = parseJson(sim.armyResultsJson())
    check results["reason"].getStr() == ReasonDeadline
    check results["scores"][0].getInt() + results["scores"][1].getInt() == 0

  test "the state packet the viewer consumes is well formed":
    var config = testConfig(mapSize = 31, maxTicks = 60)
    let run = runScriptedEpisode(config)
    var
      data = parseReplayBytes(run.bytes)
      initialized = initReplayRuntime(data)
      tracker = initBroadcastTracker()
    let packet = parseJson(buildStateJson(
      initialized.sim, initialized.player, tracker, newJArray(), false))
    for key in ["t", "st", "mx", "mt", "ph", "pl", "sp", "en", "teams",
                "roster", "mg", "lulls", "beats", "lead"]:
      check packet.hasKey(key)
    for key in ["board", "units", "seats", "alive", "kills", "turn", "turns",
                "tick", "maxTicks", "mismatchTick", "events"]:
      check packet["mg"].hasKey(key)
    ## chrome_common's momentum graph reads teams[side].lives, which is the
    ## side's ALIVE COUNT here -- that is what makes it the unit-count
    ## sparkline with no change to that byte-identical file
    check packet["teams"]["red"]["lives"].getInt() > 0
    check packet["lead"]["teams"][0].getStr() == "red"
    check packet["roster"].len == SeatCount
    check packet["mg"]["seats"].len == SeatCount
