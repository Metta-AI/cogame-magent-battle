## The squad controller: the deterministic map from one squad order to one
## MAgent action per living soldier, every tick.
##
## There is NO randomness here at all. Ties break by the fixed offset order,
## then by ascending unit id -- which is what makes the recorded order stream
## sufficient to re-derive the whole episode in the browser.
##
## PURE INTEGER (see arena.nim).

import sim_types, sim_state, arena, units, directives, upstream

const
  FlankOffset* = 8
    ## How far off the enemy centroid a `flank` swings, in cells. One of the
    ## three tunables tools_tune_baselines sweeps; tools_ci baseline_tuning.json
    ## records the pick and tests/test_magent_tuning.nim pins it.
  FlankArriveSq* = ViewRadiusSq
    ## Once a soldier is within 6 cells of its flank point it stops swinging
    ## wide and closes on the enemy mass.

proc backEdgeX*(mapSize, army: int): int {.inline.} =
  if army == 0: 1 else: mapSize - 2

proc nearestEnemy*(sim: SimServer, id: int): int =
  ## The nearest living enemy by squared Euclidean distance, ties by lowest
  ## enemy id. -1 when the enemy army is extinct.
  result = -1
  var best = 0
  let
    me = sim.units.soldiers[id]
    enemy = 1 - me.army
  for other in 0 ..< sim.units.soldiers.len:
    let target = sim.units.soldiers[other]
    if not target.alive or target.army != enemy:
      continue
    let d = distSq(me.x, me.y, target.x, target.y)
    if result < 0 or d < best:
      result = other
      best = d

proc targetCell*(sim: SimServer, id: int): tuple[x, y, attackOk, focus: int] =
  ## `T(u)` plus whether the soldier may strike and which enemy squad it
  ## prefers (-1 for none). Returned as ints so the whole module stays free of
  ## bools in the hashed path.
  let
    me = sim.units.soldiers[id]
    seat = sim.seatOfArmy(me.army)
    enemyArmy = 1 - me.army
    order = sim.directives[seat].orders[me.squad]
  result = (me.x, me.y, 1, -1)
  case order.kind
  of okRetreat:
    result = (backEdgeX(sim.units.mapSize, me.army), me.y, 0, -1)
  of okHold:
    result = (order.x, order.y, 1, -1)
  of okFocus:
    let stat = squadStat(sim.units, enemyArmy, order.target)
    if stat.alive > 0:
      result = (stat.x, stat.y, 1, order.target)
    else:
      let near = nearestEnemy(sim, id)
      if near >= 0:
        result = (sim.units.soldiers[near].x, sim.units.soldiers[near].y, 1, -1)
  of okFlank:
    let centroid = armyCentroid(sim.units, enemyArmy)
    if centroid.ok:
      let
        offset = (if order.side == fsLeft: -FlankOffset else: FlankOffset)
        wingY = clamp(centroid.y + offset, 0, sim.units.mapSize - 1)
      if distSq(me.x, me.y, centroid.x, wingY) <= FlankArriveSq:
        result = (centroid.x, centroid.y, 1, -1)
      else:
        result = (centroid.x, wingY, 1, -1)
  of okAdvance:
    let near = nearestEnemy(sim, id)
    if near >= 0:
      result = (sim.units.soldiers[near].x, sim.units.soldiers[near].y, 1, -1)

proc chooseAction*(sim: SimServer, id: int): int =
  ## One action index in the upstream 21-way space:
  ## 0 = do_nothing, 1..12 = move by MoveOffsets, 13..20 = attack by
  ## AttackOffsets.
  let me = sim.units.soldiers[id]
  if not me.alive:
    return ActionDoNothing
  let target = targetCell(sim, id)
  if target.attackOk == 1:
    var
      bestSlot = -1
      bestHp = 0
      bestFocus = 0
    for slot in 0 ..< AttackOffsets.len:
      let
        offset = AttackOffsets[slot]
        occupant = occupantAt(sim.units, me.x + offset.dx, me.y + offset.dy)
      if occupant < 0:
        continue
      let other = sim.units.soldiers[occupant]
      if not other.alive or other.army == me.army:
        continue
      let focus =
        if target.focus >= 0 and other.squad == target.focus: 1 else: 0
      if bestSlot < 0 or focus > bestFocus or
          (focus == bestFocus and other.hp < bestHp):
        bestSlot = slot
        bestHp = other.hp
        bestFocus = focus
    if bestSlot >= 0:
      return ActionAttackBase + bestSlot
  var
    bestSlot = -1
    bestDist = distSq(me.x, me.y, target.x, target.y)
  for slot in 0 ..< MoveOffsets.len:
    let
      offset = MoveOffsets[slot]
      nx = me.x + offset.dx
      ny = me.y + offset.dy
    if not onBoard(sim.units.mapSize, nx, ny):
      continue
    # DIVERGENCE 6 (vendor_PATCHES.md). The design note said occupancy is not
    # consulted here at all. That deadlocks: T(u) for `advance` and `focus` is
    # the ENEMY's own cell, so the argmin move is always onto the enemy, always
    # blocked -- two lines two cells apart each pick a blocked cell, neither
    # ever becomes adjacent, and every game ends 81 v 81 at the tick cap with
    # zero kills (measured). Occupancy is therefore read from the TICK
    # SNAPSHOT at decision time. A blocked move can still fail at resolution --
    # two soldiers may pick the same empty cell, and a cell freed by a kill or
    # taken by an earlier mover changes underneath the decision -- so a dense
    # formation still shuffles rather than teleports, which is the property
    # the note's rule existed to preserve.
    if occupantAt(sim.units, nx, ny) >= 0:
      continue
    let d = distSq(nx, ny, target.x, target.y)
    if d < bestDist:
      bestDist = d
      bestSlot = slot
  if bestSlot < 0:
    return ActionDoNothing
  ActionMoveBase + bestSlot
