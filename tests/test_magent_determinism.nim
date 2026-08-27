## The determinism gate, as its own module so a shard can carry it alone: record
## an episode, re-simulate it from the replay's seed and ORDER RECORDS ALONE on a
## fresh sim, and assert identical final tick, winner, survivor counts and
## per-tick gameHash.

import std/[strutils, unittest]
import helpers
import magent/[replay_runtime, roster]

suite "magent determinism":

  test "re-simulating from the bytes reproduces the episode exactly":
    for mapSize in [31, 45]:
      var config = testConfig(mapSize = mapSize, maxTicks = 200)
      let run = runScriptedEpisode(config)
      checkpoint("mapSize " & $mapSize)
      var
        data = parseReplayBytes(run.bytes)
        initialized = initReplayRuntime(data, mismatchQuit = true)
        player = initialized.player
        fresh = initialized.sim
      fresh.applyJoinRecords(data)
      ## the ONLY inputs re-applied are the recorded order records
      check data.orders.len >= SeatCount * run.sim.gameLog.len
      var guard = 0
      while player.frame <= player.maxFrame and guard < 100000:
        player.advanceReplayFrame(fresh)
        inc guard
      check player.hashMismatchTick == -1
      check fresh.gameLog.len == run.sim.gameLog.len
      for i in 0 ..< run.sim.gameLog.len:
        check fresh.gameLog[i].ticks == run.sim.gameLog[i].ticks
        check fresh.gameLog[i].survivors == run.sim.gameLog[i].survivors
        check fresh.gameLog[i].kills == run.sim.gameLog[i].kills
        check fresh.gameLog[i].endRule == run.sim.gameLog[i].endRule
        check fresh.gameLog[i].redSlot == run.sim.gameLog[i].redSlot
      check fresh.scoreOf(0) == run.sim.scoreOf(0)
      check fresh.scoreOf(1) == run.sim.scoreOf(1)
      check fresh.totalSurvivors(0) == run.sim.totalSurvivors(0)
      check fresh.units.aliveCount == run.sim.units.aliveCount

  test "two episodes with the same seed and the same orders are identical":
    ## The only randomness in `battle` is the seed and it is used for nothing:
    ## spawns are a pure function of mapSize, the controller is deterministic,
    ## and resolution order is by unit id.
    var config = testConfig(mapSize = 31, maxTicks = 200)
    let first = runScriptedEpisode(config)
    let second = runScriptedEpisode(config)
    check first.bytes == second.bytes
    check first.sim.scoreOf(0) == second.sim.scoreOf(0)

  test "the hash chain covers the whole episode, tick by tick":
    var config = testConfig(mapSize = 31, maxTicks = 120)
    let run = runScriptedEpisode(config)
    let data = parseReplayBytes(run.bytes)
    ## one hash per advanced frame, and the ticks are strictly increasing
    check data.hashes.len > 40
    for i in 1 ..< data.hashes.len:
      check data.hashes[i].tick > data.hashes[i - 1].tick
    ## and the chain actually changes: an all-zero or constant chain would pass
    ## a naive comparison while proving nothing
    var seenHashes: seq[uint64]
    for record in data.hashes:
      if record.value notin seenHashes:
        seenHashes.add(record.value)
    check seenHashes.len > data.hashes.len div 2
