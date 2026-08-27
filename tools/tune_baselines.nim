## The baseline tuning sweep. Not a guess: the three `pincer` tunables come from
## a head-to-head grid, and `tools/ci/baseline_tuning.json` records the pick that
## `tests/test_magent_tuning.nim` then pins.
##
##   nim c -r --path:src tools/tune_baselines.nim            # print the sweep
##   nim c -r --path:src tools/tune_baselines.nim --check     # verify the pick
##
## Both baselines are scripted and the sim is deterministic, so one episode per
## cell is the whole measurement -- there is nothing to average over.

import std/[json, os, strformat, strutils]
import ../src/magent/[sim, baselines, decide, episode]

export sim, baselines

type
  SweepEntry* = object
    params*: BaselineParams
    score*: int

proc paramsConfig(mapSize, maxTicks: int): GameConfig =
  result = defaultGameConfig()
  result.seed = 42
  result.mapSize = mapSize
  result.maxTicks = maxTicks
  result.maxGames = 2
  result.turnTicks = 20
  result.turnSpacingMs = 0
  result.gameOverTicks = 2
  result.lobbyJoinTimeoutTicks = 1
  result.players = @[PlayerConfig(name: "Alpha"), PlayerConfig(name: "Bravo")]
  result.clampConfig()

proc runPair(
  params: BaselineParams, mapSize, maxTicks: int
): tuple[pincer, line: int] =
  ## `pincer` (with these params) against `line`, as one two-game episode with
  ## the sides swapped. Returns each seat's score, which is exactly zero-sum.
  var config = paramsConfig(mapSize, maxTicks)
  var engine = initDecisionEngine(config)
  engine.seats[0].baseline = blPincer
  engine.seats[1].baseline = blLine
  engine.pincerParams = params
  let run = runHeadlessEpisode(config, engine, "")
  (run.sim.scoreOf(0), run.sim.scoreOf(1))

proc headToHead*(
  params: BaselineParams, mapSize = 31, maxTicks = 200
): tuple[pincer, line: int] =
  runPair(params, mapSize, maxTicks)

proc sweepBaselines*(mapSize = 31, maxTicks = 200): seq[SweepEntry] =
  ## The grid: retreat threshold x focus radius x flank offset. Ranked by the
  ## `pincer` seat's zero-sum score against `line`.
  for retreat in [25, 40, 55]:
    for radius in [2, 3, 5]:
      for offset in [4, 8, 12]:
        let params = BaselineParams(
          retreatHpTenths: retreat, focusRadius: radius, flankOffset: offset)
        let head = runPair(params, mapSize, maxTicks)
        result.add(SweepEntry(params: params, score: head.pincer))
  # insertion sort, descending: the grid is 27 entries and a dependency-free
  # sort keeps the ordering identical on every platform
  for i in 1 ..< result.len:
    let cur = result[i]
    var j = i - 1
    while j >= 0 and result[j].score < cur.score:
      result[j + 1] = result[j]
      dec j
    result[j + 1] = cur

when isMainModule:
  let check = "--check" in commandLineParams()
  let ranking = sweepBaselines()
  echo "retreatHp focusRadius flankOffset  score(pincer vs line)"
  for entry in ranking:
    echo &"{entry.params.retreatHpTenths:>9} {entry.params.focusRadius:>11} " &
      &"{entry.params.flankOffset:>11}  {entry.score:>6}"
  let recorded = parseJson(readFile(
    currentSourcePath().parentDir().parentDir() / "tools/ci/baseline_tuning.json"))
  let pick = BaselineParams(
    retreatHpTenths: recorded["retreatHpTenths"].getInt(),
    focusRadius: recorded["focusRadius"].getInt(),
    flankOffset: recorded["flankOffset"].getInt())
  echo "shipped pick: ", pick
  if pick != DefaultBaselineParams:
    quit("tools/ci/baseline_tuning.json disagrees with DefaultBaselineParams", 1)
  if check:
    var rank = -1
    for i, entry in ranking:
      if entry.params == pick:
        rank = i
    if rank < 0:
      quit("the shipped pick is not in the swept grid", 1)
    if rank > ranking.len div 2:
      quit("the shipped pick ranks " & $rank & " of " & $ranking.len &
        "; re-sweep and update tools/ci/baseline_tuning.json", 1)
    echo "shipped pick ranks ", rank, " of ", ranking.len, ": ok"
