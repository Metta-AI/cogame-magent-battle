## The soldiers: flat arrays, the occupancy grid, army-scale visibility and the
## per-squad aggregates the observation builder reports.
##
## PURE INTEGER (see arena.nim). Centroids are `sum div count`, distances are
## squared, mean hp is in tenths.

import arena, sim_types, upstream

type
  Soldier* = object
    x*, y*: int
    hp*: int          ## tenths; HpMax == 100 == 10.0 upstream
    army*: int        ## 0 = red (left at spawn), 1 = blue (right at spawn)
    squad*: int       ## 0 .. SquadCount-1
    alive*: bool

  Units* = object
    mapSize*: int
    soldiers*: seq[Soldier]
    occupancy*: seq[int]      ## cell -> unit id, or -1
    armyStart*: array[2, int] ## first unit id of each army
    armyCount*: array[2, int] ## soldiers spawned per army
    aliveCount*: array[2, int]

proc clearOccupancy*(units: var Units) =
  for i in 0 ..< units.occupancy.len:
    units.occupancy[i] = -1

proc initUnits*(mapSize: int): Units =
  ## Spawns both armies from upstream's `generate_map` and fixes squad
  ## membership. Unit ids are red first, then blue, ascending -- and that
  ## order is the resolution order the whole tick is pinned to.
  result.mapSize = mapSize
  result.occupancy = newSeq[int](mapSize * mapSize)
  result.clearOccupancy()
  let spawn = generateMap(mapSize)
  let
    redSquads = assignSquads(spawn.red, true)
    blueSquads = assignSquads(spawn.blue, false)
  result.armyStart[0] = 0
  result.armyCount[0] = spawn.red.len
  result.armyStart[1] = spawn.red.len
  result.armyCount[1] = spawn.blue.len
  for i, cell in spawn.red:
    result.soldiers.add(Soldier(
      x: cell.x, y: cell.y, hp: HpMax, army: 0, squad: redSquads[i],
      alive: true))
  for i, cell in spawn.blue:
    result.soldiers.add(Soldier(
      x: cell.x, y: cell.y, hp: HpMax, army: 1, squad: blueSquads[i],
      alive: true))
  for id, soldier in result.soldiers:
    result.occupancy[cellIndex(mapSize, soldier.x, soldier.y)] = id
  result.aliveCount[0] = result.armyCount[0]
  result.aliveCount[1] = result.armyCount[1]

proc occupantAt*(units: Units, x, y: int): int {.inline.} =
  if not onBoard(units.mapSize, x, y):
    -1
  else:
    units.occupancy[cellIndex(units.mapSize, x, y)]

proc moveTo*(units: var Units, id, x, y: int) =
  units.occupancy[cellIndex(units.mapSize, units.soldiers[id].x,
    units.soldiers[id].y)] = -1
  units.soldiers[id].x = x
  units.soldiers[id].y = y
  units.occupancy[cellIndex(units.mapSize, x, y)] = id

proc kill*(units: var Units, id: int) =
  ## Death is immediate: the cell is freed inside the same tick, which is what
  ## lets a mover step into it later in the resolution order.
  if not units.soldiers[id].alive:
    return
  units.soldiers[id].alive = false
  units.soldiers[id].hp = 0
  units.occupancy[cellIndex(units.mapSize, units.soldiers[id].x,
    units.soldiers[id].y)] = -1
  dec units.aliveCount[units.soldiers[id].army]

proc armyOf*(units: Units, id: int): int {.inline.} =
  units.soldiers[id].army

proc visibleToArmy*(units: Units, viewer: int, id: int): bool =
  ## MAgent's own `view_range` lifted to army scale: an enemy soldier is
  ## visible iff SOME living soldier of `viewer`'s army is within
  ## CircleRange(6) of it (dx*dx + dy*dy <= 36).
  let target = units.soldiers[id]
  if not target.alive:
    return false
  for other in units.soldiers:
    if not other.alive or other.army != viewer:
      continue
    if distSq(other.x, other.y, target.x, target.y) <= ViewRadiusSq:
      return true
  false

type
  SquadStat* = object
    alive*: int
    x*, y*: int         ## integer centroid of the living members
    hpTenths*: int      ## mean hp of the living members, in tenths

proc squadStat*(units: Units, army, squad: int): SquadStat =
  var sumX, sumY, sumHp = 0
  for soldier in units.soldiers:
    if not soldier.alive or soldier.army != army or soldier.squad != squad:
      continue
    inc result.alive
    sumX += soldier.x
    sumY += soldier.y
    sumHp += soldier.hp
  if result.alive > 0:
    result.x = sumX div result.alive
    result.y = sumY div result.alive
    result.hpTenths = sumHp div result.alive

proc visibleSquadStat*(units: Units, viewer, army, squad: int): SquadStat =
  ## The same aggregate, restricted to members `viewer`'s army can currently
  ## see. A squad with no visible member reports `alive == 0`.
  var sumX, sumY, sumHp = 0
  for id in 0 ..< units.soldiers.len:
    let soldier = units.soldiers[id]
    if not soldier.alive or soldier.army != army or soldier.squad != squad:
      continue
    if not units.visibleToArmy(viewer, id):
      continue
    inc result.alive
    sumX += soldier.x
    sumY += soldier.y
    sumHp += soldier.hp
  if result.alive > 0:
    result.x = sumX div result.alive
    result.y = sumY div result.alive
    result.hpTenths = sumHp div result.alive

proc armyCentroid*(units: Units, army: int): tuple[ok: bool, x, y: int] =
  var sumX, sumY, count = 0
  for soldier in units.soldiers:
    if soldier.alive and soldier.army == army:
      inc count
      sumX += soldier.x
      sumY += soldier.y
  if count == 0:
    return (false, 0, 0)
  (true, sumX div count, sumY div count)

proc visibleEnemyCount*(units: Units, viewer: int): int =
  let enemy = 1 - viewer
  for id in 0 ..< units.soldiers.len:
    if units.soldiers[id].army == enemy and units.visibleToArmy(viewer, id):
      inc result
