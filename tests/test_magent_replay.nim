## Replay tests: record -> re-derive for EVERY end reason, self-sufficiency of
## the bytes, the strict-UTF-8 JSON view, and the fixture version sweep.

import std/[json, os, osproc, strutils, unicode, unittest]
import helpers
import magent/[broadcast, replay_runtime, roster]

proc rederive(bytes: string): tuple[
  player: ReplayPlayer, sim: SimServer, mismatch: int
] =
  var
    data = parseReplayBytes(bytes)
    initialized = initReplayRuntime(data, mismatchQuit = false)
  var
    player = initialized.player
    sim = initialized.sim
  sim.applyJoinRecords(data)
  for record in data.chats:
    sim.applyReplayChat(record.text)
  var guard = 0
  while player.frame <= player.maxFrame and guard < 100000:
    player.advanceReplayFrame(sim)
    inc guard
  (player, sim, player.hashMismatchTick)

suite "magent replay":

  test "record then re-derive, every end reason":
    ## wipe, tickCap, wallClock AND fault. A wall-clock or fault stop cannot be
    ## re-derived from sim state, so it is recorded as ONE load-bearing record
    ## applied by the same proc on both sides -- the particle-worlds scar was a
    ## stop banked outside the stepping proc, which hash-mismatched at the stop
    ## tick on every slow-LLM episode.
    block wipe:
      var config = testConfig(mapSize = 31, maxTicks = 300)
      let run = runScriptedEpisode(config)
      check run.sim.gameLog[0].endRule == EndRuleWipe
      let redone = rederive(run.bytes)
      check redone.mismatch == -1
      check redone.sim.gameLog.len == run.sim.gameLog.len
      check redone.sim.scoreOf(0) == run.sim.scoreOf(0)
      for i in 0 ..< run.sim.gameLog.len:
        check redone.sim.gameLog[i].survivors == run.sim.gameLog[i].survivors
        check redone.sim.gameLog[i].ticks == run.sim.gameLog[i].ticks
        check redone.sim.gameLog[i].endRule == run.sim.gameLog[i].endRule

    block tickCap:
      ## Both armies retreat forever, so nobody ever dies and the games run to
      ## the cap.
      var config = testConfig(mapSize = 31, maxTicks = 12)
      var engine = initDecisionEngine(config)
      for seat in 0 ..< SeatCount:
        engine.seats[seat].isLlm = false
        engine.seats[seat].baseline = blPincer
      var sim = initSimServer(config)
      var state = initEpisodeState()
      var writer = openReplayWriter("", config.configJson())
      for seat in 0 ..< SeatCount:
        sim.admitSeat(seat, "")
      discard state.maybeStartFirstGame(sim, writer)
      while not state.finished and state.frame < 400:
        ## force retreat on every squad every frame so no kill can happen
        for seat in 0 ..< SeatCount:
          for k in 0 ..< SquadCount:
            sim.directives[seat].orders[k] =
              SquadOrder(kind: okRetreat, target: -1, fromReply: true)
        if sim.phase == Playing and sim.tick mod config.turnTicks == 0:
          for seat in 0 ..< SeatCount:
            writer.writeOrders(state.frame, sim.gameIndex + 1,
              sim.tick div config.turnTicks + 1, seat,
              sim.directives[seat].orders)
        discard state.advanceEpisodeFrame(sim, writer)
        discard state.maybeNextGame(sim, writer)
        inc state.frame
      state.finishEpisode(sim, writer)
      check sim.gameLog[0].endRule == EndRuleTickCap
      check sim.units.aliveCount[0] == sim.units.armyCount[0]
      let redone = rederive(writer.bytes())
      check redone.mismatch == -1
      check redone.sim.gameLog[0].endRule == EndRuleTickCap

    block wallClock:
      var config = testConfig(mapSize = 45, maxTicks = 300)
      var engine = scriptedEngine(config)
      var sim = initSimServer(config)
      var state = initEpisodeState()
      var writer = openReplayWriter("", config.configJson())
      for seat in 0 ..< SeatCount:
        sim.admitSeat(seat, "")
      for _ in 0 ..< 25:
        discard state.runEpisodeFrame(sim, engine, writer, 0)
      discard state.runEpisodeFrame(
        sim, engine, writer, config.wallClockBudgetSeconds)
      state.finishEpisode(sim, writer)
      check sim.gameLog[^1].endRule == EndRuleWallClock
      let redone = rederive(writer.bytes())
      check redone.mismatch == -1
      check redone.sim.gameLog[^1].endRule == EndRuleWallClock
      check redone.sim.gameLog[^1].survivors == sim.gameLog[^1].survivors

    block fault:
      ## A fault stop takes the same load-bearing path. The stop record is
      ## written and applied by sim.applyStop, so the chain stays clean at the
      ## stop tick exactly as the wall-clock case does.
      var config = testConfig(mapSize = 31, maxTicks = 300)
      var engine = scriptedEngine(config)
      var sim = initSimServer(config)
      var state = initEpisodeState()
      var writer = openReplayWriter("", config.configJson())
      for seat in 0 ..< SeatCount:
        sim.admitSeat(seat, "")
      for _ in 0 ..< 15:
        discard state.runEpisodeFrame(sim, engine, writer, 0)
      sim.endReason = ReasonFault
      sim.stopDetail = "a tripped sim invariant, for the test"
      writer.writeStop(state.frame, EndRuleFault)
      sim.applyStop(EndRuleFault)
      state.finished = true
      inc state.frame
      state.finishEpisode(sim, writer)
      check sim.gameLog[^1].endRule == EndRuleFault
      let redone = rederive(writer.bytes())
      check redone.mismatch == -1
      check redone.sim.gameLog[^1].endRule == EndRuleFault

  test "a divergent bit is CAUGHT, at the tick it happens":
    ## The chain is only worth having if it fires. Corrupt one recorded hash and
    ## the re-derivation must report that exact tick.
    var config = testConfig(mapSize = 31, maxTicks = 60)
    let run = runScriptedEpisode(config)
    var data = parseReplayBytes(run.bytes)
    check data.hashes.len > 40
    let target = data.hashes[30].tick
    ## rewrite the recorded hash for one frame, byte for byte, in place
    var bytes = run.bytes
    var at = 0
    var patched = false
    while at < bytes.len:
      let index = bytes.find("\x06", at)
      if index < 0:
        break
      at = index + 1
      if index + 13 > bytes.len:
        break
      var tick = 0
      for shift in 0 ..< 4:
        tick = tick or (int(uint8(bytes[index + 1 + shift])) shl (shift * 8))
      if tick == target:
        bytes[index + 5] = char(uint8(bytes[index + 5]) xor 0xff'u8)
        patched = true
        break
    check patched
    let redone = rederive(bytes)
    check redone.mismatch == target

  test "replay is self-sufficient":
    ## The bytes alone yield the seat names, the aliases, the policy kinds, the
    ## full config, the seed, every order record, every chat record and the
    ## result. No server is contacted.
    var config = testConfig(mapSize = 31, maxTicks = 60)
    config.seed = 1734029581
    var engine = scriptedEngine(config)
    engine.seats[0].label = "magent-battle-vanguard"
    engine.seats[1].label = "magent-battle-line"
    let run = runHeadlessEpisode(config, engine, "")
    let data = parseReplayBytes(run.bytes)
    check data.gameName == GameName
    check data.gameVersion == GameVersion
    check data.configField("seed") == "1734029581"
    check data.configField("mapSize") == "31"
    check data.configField("protocol") == ProtocolId
    check data.joins.len == SeatCount
    check data.orders.len >= SeatCount
    check data.gameStarts.len == config.maxGames
    check data.hashes.len >= data.frameCount - 2
    var sawResult = false
    for record in data.chats:
      if "\"k\":\"result\"" in record.text:
        sawResult = true
        let results = parseJson(record.text)["results"]
        check results["reason"].getStr() == ReasonComplete
        check results["aliases"][0].getStr() == "Alpha"
        check results["policyKinds"].len == SeatCount
    check sawResult

  test "replay_summary is strict UTF-8 JSON":
    ## Every capped field filled to EXACTLY its cap with 4-byte emoji, then read
    ## back through the stdlib-only Python view of the bytes.
    var config = testConfig(mapSize = 31, maxTicks = 40)
    var sim = initSimServer(config)
    var state = initEpisodeState()
    var writer = openReplayWriter("", config.configJson())
    var engine = scriptedEngine(config)
    for seat in 0 ..< SeatCount:
      sim.admitSeat(seat, "")
      writer.writeJoin(0, seat, seatAlias(seat), "")
    discard state.maybeStartFirstGame(sim, writer)
    var say = ""
    for _ in 0 ..< 400:
      say.add("\u{1F525}")
    var notes = ""
    for _ in 0 ..< 600:
      notes.add("\u{1F6E1}")
    while not state.finished and state.frame < 4000:
      if sim.phase == Playing and sim.tick mod config.turnTicks == 0:
        for seat in 0 ..< SeatCount:
          var directive = pincerDirective(sim, seat)
          directive.source = dsLlm
          directive.say = sanitizeSay(say)
          directive.notes = sanitizeLine(notes, MaxNoteRunes)
          check directive.say.runeLen <= MaxSayRunes
          sim.applyOrders(seat, directive)
          writer.writeOrders(state.frame, sim.gameIndex + 1,
            sim.tick div config.turnTicks + 1, seat, directive.orders)
          writer.writeChat(state.frame, seat, directive.boundedDirectiveRecord(
            sim.gameIndex + 1, sim.tick div config.turnTicks + 1, seat,
            sim.sideOfSeat(seat), engine.lastView[seat]))
      discard state.advanceEpisodeFrame(sim, writer)
      discard state.maybeNextGame(sim, writer)
      inc state.frame
    state.finishEpisode(sim, writer)
    let path = getTempDir() / "magent-summary-fixture.replay"
    writeFile(path, writer.bytes())
    let summaryPath = getTempDir() / "magent-summary-fixture.json"
    let command = "python3 " & quoteShell(repoRoot() / "tools/replay_summary.py") &
      " " & quoteShell(path) & " > " & quoteShell(summaryPath)
    let code = execCmd(command)
    check code == 0
    let raw = readFile(summaryPath)
    ## STRICT: no lone surrogates, no byte-truncated codepoints
    check raw.validateUtf8() == -1
    let summary = parseJson(raw)
    check summary["protocol"].getStr() == ProtocolId
    check summary["gameVersion"].getStr() == GameVersion
    check summary["tickCount"].getInt() > 0
    check summary["directives"].len > 0
    for directive in summary["directives"]:
      check directive["say"].getStr().validateUtf8() == -1
      check directive["say"].getStr().runeLen <= MaxSayRunes
      check directive["orders"].len == SquadCount
    check summary["results"]["reason"].getStr() in
      [ReasonComplete, ReasonDeadline]
    removeFile(path)
    removeFile(summaryPath)

  test "the reply byte cap cuts bytes on a codepoint boundary":
    ## MaxReplyBytes is how much of a PROVIDER reply is read before parsing, so
    ## it is a byte budget: a rune cut there admits up to 4 x 8192 bytes into
    ## parseJson (r1 review F7). truncateBytes is the byte cut that still lands
    ## on a codepoint boundary.
    var emoji = ""
    while emoji.len <= MaxReplyBytes * 2:
      emoji.add("\u{1F525}")            ## 4 bytes each
    let cut = emoji.truncateBytes(MaxReplyBytes)
    check cut.len <= MaxReplyBytes
    check cut.len > MaxReplyBytes - 4   ## as much as fits, not less
    check cut.validateUtf8() == -1
    check cut.runeLen == cut.len div 4
    ## a 3-byte codepoint straddling the cap is dropped whole, not halved
    var mixed = "x".repeat(MaxReplyBytes - 1) & "\u20AC" & "tail"
    let cutMixed = mixed.truncateBytes(MaxReplyBytes)
    check cutMixed.len == MaxReplyBytes - 1
    check cutMixed.validateUtf8() == -1
    ## short input, and the degenerate limits, are identities
    check "hello".truncateBytes(MaxReplyBytes) == "hello"
    check "hello".truncateBytes(0) == ""

  test "every committed fixture carries the current GameVersion":
    ## The starter's sweep over tests/, kept: a fixture recorded against older
    ## rules fails HERE rather than three CI jobs later.
    var seen = 0
    for path in walkDirRec(repoRoot() / "tests"):
      if not path.endsWith(".replay"):
        continue
      inc seen
      let data = parseReplayBytes(readFile(path))
      checkpoint(path)
      check data.gameName == GameName
      check data.gameVersion == GameVersion
      check data.hashes.len > 0
      let redone = rederive(readFile(path))
      check redone.mismatch == -1
    check seen >= 1
