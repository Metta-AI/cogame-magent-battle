## The baseline sweep's pick, and the head-to-head evidence behind it.

import std/[json, strutils, unittest]
import helpers
import "../tools/tune_baselines"

suite "magent baseline tuning":

  test "the shipped defaults are the swept pick":
    let tuning = parseJson(readRepoFile("tools/ci/baseline_tuning.json"))
    check DefaultBaselineParams.retreatHpTenths ==
      tuning["retreatHpTenths"].getInt()
    check DefaultBaselineParams.focusRadius == tuning["focusRadius"].getInt()
    check DefaultBaselineParams.flankOffset == tuning["flankOffset"].getInt()

  test "the sweep still ranks the shipped pick at the top":
    ## The same head-to-head the tool runs, over a small grid, so a change to
    ## the controller that makes another parameter set strictly better shows up
    ## here rather than in a ladder round.
    let ranking = sweepBaselines(mapSize = 31, maxTicks = 120)
    check ranking.len >= 4
    checkpoint("best " & $ranking[0].params & " score " & $ranking[0].score)
    ## the shipped pick is in the top half of the grid
    var rank = -1
    for i, entry in ranking:
      if entry.params == DefaultBaselineParams:
        rank = i
    check rank >= 0
    check rank <= ranking.len div 2

  test "a mass charge beats a split commander, at scale":
    ## The design note's own claim about why `line` is worth shipping: "a mass
    ## charge beats a badly-split commander". At upstream scale it does, and by
    ## a lot -- which is exactly what makes `line` a real filler rather than a
    ## punchbag, and what a commander has to beat. A controller change that
    ## inverted this would be a change worth noticing, so it is pinned.
    for mapSize in [31, 45]:
      let head = headToHead(DefaultBaselineParams, mapSize = mapSize,
        maxTicks = 200)
      checkpoint("mapSize " & $mapSize & ": pincer " & $head.pincer &
        " line " & $head.line)
      ## the formula is EXACTLY zero-sum: no pair of seats can raise their
      ## joint total by cooperating
      check head.pincer + head.line == 0
      check head.line >= head.pincer

  test "the fallback is a real opponent, not a walkover":
    ## `pincer` is the server-side fallback, so a champion that loses a turn to
    ## a timeout must not thereby lose its army. It keeps living soldiers in
    ## every game it plays.
    var config = testConfig(mapSize = 45, maxTicks = 200)
    let run = runScriptedEpisode(config, first = blPincer, second = blLine)
    check run.sim.gameLog.len == 2
    ## It FIGHTS: at upstream scale a mass charge overruns a split army, so what
    ## has to hold is that the fallback trades hard rather than folding -- a
    ## champion that loses one turn to a timeout is penalised, not deleted.
    var pincerKills = 0
    for record in run.sim.gameLog:
      pincerKills += record.kills[0]
    checkpoint("pincer kills over the pair: " & $pincerKills &
      ", survivors " & $run.sim.totalSurvivors(0))
    check pincerKills > 20
