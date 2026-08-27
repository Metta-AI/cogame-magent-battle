## The two scripted baselines, both shipped as fillers. `pincer` is also the
## server-side fallback -- the decision engine imports THIS proc rather than
## duplicating it, so the two can never drift (tests/test_magent_control.nim).
##
## Both emit the same ArmyDirective an LLM does, through the same validator,
## which is what makes the bounded-orders test meaningful.
##
## PURE INTEGER (see arena.nim).

import std/strutils
import sim_types, sim_state, units, arena, directives, control

type
  Baseline* = enum
    blLine = "line"
    blPincer = "pincer"

  BaselineParams* = object
    retreatHpTenths*: int
    focusRadius*: int
    flankOffset*: int

const
  DefaultBaselineParams* = BaselineParams(
    # retreatHpTenths: mean hp below 4.0 pulls a squad out to heal.
    # focusRadius: an enemy centroid this close is worth focusing.
    # flankOffset: how far wide a flank swings.
    retreatHpTenths: 40,
    focusRadius: 3,
    flankOffset: FlankOffset
  )
    ## Not guessed: tools_tune_baselines.nim sweeps the three head to head and
    ## tools_ci baseline_tuning.json records the pick;
    ## tests/test_magent_tuning.nim asserts the shipped defaults still equal it.

  DefaultBaseline* = blPincer
    ## Anything unrecognised is the published default (the starter's rule).

proc parseBaseline*(text: string): Baseline =
  let key = text.strip().toLowerAscii()
  for baseline in Baseline:
    if $baseline == key:
      return baseline
  DefaultBaseline

proc lineDirective*(sim: SimServer, seat: int): ArmyDirective =
  ## Every squad advances, every turn, forever. Five lines, and a real
  ## opponent: a mass charge beats a badly split commander.
  result = defaultDirective()
  result.source = dsScripted
  for k in 0 ..< SquadCount:
    result.orders[k] = SquadOrder(kind: okAdvance, target: -1, fromReply: true)

proc pincerDirective*(
  sim: SimServer, seat: int, params = DefaultBaselineParams
): ArmyDirective =
  ## 1. any squad with alive > 0 and mean hp below `retreatHpTenths` retreats;
  ## 2. else any squad with a visible enemy squad centroid within
  ##    `focusRadius` focuses it (nearest, ties by lowest id);
  ## 3. else squads 1-3 flank left, 4-6 advance, 7-9 flank right.
  result = defaultDirective()
  result.source = dsScripted
  let
    army = sim.armyOfSeat(seat)
    enemyArmy = 1 - army
    enemySeat = 1 - seat
  var enemyStats: array[SquadCount, SquadStat]
  for k in 0 ..< SquadCount:
    enemyStats[k] = visibleSquadStat(sim.units, army, enemyArmy, k)
  discard enemySeat
  for k in 0 ..< SquadCount:
    let mine = squadStat(sim.units, army, k)
    if mine.alive > 0 and mine.hpTenths < params.retreatHpTenths:
      result.orders[k] =
        SquadOrder(kind: okRetreat, target: -1, fromReply: true)
      continue
    var
      bestSquad = -1
      bestDist = 0
    if mine.alive > 0:
      for e in 0 ..< SquadCount:
        if enemyStats[e].alive == 0:
          continue
        let d = distSq(mine.x, mine.y, enemyStats[e].x, enemyStats[e].y)
        if d > params.focusRadius * params.focusRadius:
          continue
        if bestSquad < 0 or d < bestDist:
          bestSquad = e
          bestDist = d
    if bestSquad >= 0:
      result.orders[k] = SquadOrder(
        kind: okFocus, target: bestSquad, fromReply: true)
      continue
    if k < 3:
      result.orders[k] = SquadOrder(
        kind: okFlank, side: fsLeft, target: -1, fromReply: true)
    elif k < 6:
      result.orders[k] = SquadOrder(kind: okAdvance, target: -1, fromReply: true)
    else:
      result.orders[k] = SquadOrder(
        kind: okFlank, side: fsRight, target: -1, fromReply: true)

proc scriptedDirective*(
  sim: SimServer, seat: int, baseline: Baseline,
  params = DefaultBaselineParams
): ArmyDirective =
  case baseline
  of blLine: lineDirective(sim, seat)
  of blPincer: pincerDirective(sim, seat, params)

proc fallbackDirective*(
  sim: SimServer, seat: int, params = DefaultBaselineParams
): ArmyDirective =
  ## The server-side fallback IS the pincer baseline -- same proc, never a
  ## copy (tests/test_magent_control.nim asserts they agree order for order).
  var directive = pincerDirective(sim, seat, params)
  directive.source = dsFallback
  directive
