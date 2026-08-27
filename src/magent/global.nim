## The board payload: the soldier chips the viewer blits, the baked-floor
## descriptor and the object-pool sizing.
##
## The board is a GRID, not a pixel arena: coordinates are emitted in CELL
## space and the renderer scales them, so the same packet reads correctly at
## 360 px and at desktop width. There is no fov cache and no shadowcasting --
## spectators see everything; the COMMANDERS' fog lives in the observation
## builder (decide.nim), not in the renderer.

import std/json
import sim_types, sim_state, units, upstream

const
  UnitSpriteBase* = 1000
    ## Soldier chip pool base id, sized to MaxUnits and filled in unit-id
    ## order, like the starter's other object families.
  UnitObjectBase* = 2000
  FloorDarkenPermille* = 180
    ## arena_floor.png is tiled and darkened 18 % at map install, plus a 1 px
    ## chalk border and faint 5-cell gridlines, so the scale of the board reads
    ## with the HUD off.
  GridlineEvery* = 5

proc unitsJson*(sim: SimServer): JsonNode =
  ## One entry per LIVING soldier: `[x, y, army, hpPermille, squad]`. Dead
  ## soldiers are dropped -- the renderer draws its own fading scorch marks
  ## from the kill events, so a corpse costs no bytes.
  result = newJArray()
  for soldier in sim.units.soldiers:
    if not soldier.alive:
      continue
    result.add(%[soldier.x, soldier.y, soldier.army,
      (soldier.hp * 1000) div HpMax, soldier.squad])

proc killsJson*(sim: SimServer): JsonNode =
  ## The kills resolved in the frame just stepped: the renderer flashes each
  ## cell white, fades it over 6 frames and leaves a scorch for 60, so the
  ## shape of the fight persists.
  result = newJArray()
  for kill in sim.lastKills:
    result.add(%*{
      "x": kill.x, "y": kill.y,
      "a": sim.units.soldiers[kill.attacker].army,
      "v": sim.units.soldiers[kill.victim].army
    })

proc boardJson*(sim: SimServer): JsonNode =
  ## The static board descriptor, sent every frame (it is four numbers) so a
  ## viewer that joins mid-stream never draws an unsized grid.
  %*{
    "size": sim.units.mapSize,
    "floorDarken": FloorDarkenPermille,
    "gridEvery": GridlineEvery,
    "maxUnits": MaxUnits
  }
