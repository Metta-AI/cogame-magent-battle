## The spawn gate: an INDEPENDENT transcription of upstream's `generate_map`
## loop, run against `arena.nim`'s spawner position for position, plus the army
## counts and the preserved two-column asymmetry.
##
## The independent transcription is deliberately written from the Python text
## rather than by calling the shipped proc, so a bug in one is not silently
## agreed with by the other.

import std/[json, math, strutils, unittest]
import helpers
import magent/upstream

proc referenceGenerateMap(mapSize: int): tuple[red, blue: seq[SpawnCell]] =
  ## Transcribed from vendor/upstream/battle.py, `BattleEnv.generate_map`:
  ##
  ##   width = height = map_size
  ##   init_num = map_size * map_size * 0.04
  ##   gap = 3
  ##   n = init_num; side = int(math.sqrt(n)) * 2
  ##   for x in range(width // 2 - gap - side, width // 2 - gap - side + side, 2):
  ##     for y in range((height - side) // 2, (height - side) // 2 + side, 2):
  ##       if 0 < x < width - 1 and 0 < y < height - 1: pos.append([x, y, 0])
  ##   team1_size = len(pos)
  ##   ... right block with x in range(width // 2 + gap, width // 2 + gap + side, 2)
  ##   pos = pos[:team1_size]
  ##
  ## This is the ONE place the port is allowed to use floats: it exists to prove
  ## the integer transcription in arena.nim agrees with the float original.
  let
    width = mapSize
    height = mapSize
    initNum = float(mapSize) * float(mapSize) * 0.04
    gap = 3
    side = int(sqrt(initNum)) * 2
  var x = width div 2 - gap - side
  while x < width div 2 - gap - side + side:
    var y = (height - side) div 2
    while y < (height - side) div 2 + side:
      if 0 < x and x < width - 1 and 0 < y and y < height - 1:
        result.red.add((x, y))
      y += 2
    x += 2
  let team1Size = result.red.len
  x = width div 2 + gap
  while x < width div 2 + gap + side:
    var y = (height - side) div 2
    while y < (height - side) div 2 + side:
      if 0 < x and x < width - 1 and 0 < y and y < height - 1:
        result.blue.add((x, y))
      y += 2
    x += 2
  if result.blue.len > team1Size:
    result.blue.setLen(team1Size)

suite "magent spawn":

  test "the integer spawner equals the float transcription":
    for mapSize in [12, 31, 45, 64]:
      let
        reference = referenceGenerateMap(mapSize)
        ported = generateMap(mapSize)
      checkpoint("mapSize " & $mapSize)
      check ported.red.len == reference.red.len
      check ported.blue.len == reference.blue.len
      for i in 0 ..< reference.red.len:
        check ported.red[i] == reference.red[i]
      for i in 0 ..< reference.blue.len:
        check ported.blue[i] == reference.blue[i]
      check spawnSide(mapSize) == int(sqrt(
        float(mapSize) * float(mapSize) * 0.04)) * 2

  test "the shipped army sizes":
    ## 45 is upstream's own default and yields exactly 81 and 81 -- the 162
    ## agents the upstream docs list.
    let big = generateMap(45)
    check big.red.len == 81
    check big.blue.len == 81
    ## 31 yields 30 and 30, NOT the 25 the design note guessed: at 31 the x
    ## range is range(0, 12, 2) which the `0 < x` filter cuts to five columns,
    ## and the y range is range(9, 21, 2) which is SIX rows. Asserting the
    ## number rather than trusting the paragraph is what the note itself asked
    ## for; the divergence is recorded in vendor/PATCHES.md.
    let small = generateMap(31)
    check small.red.len == 30
    check small.blue.len == 30
    ## the minimum board upstream allows still spawns a playable pair
    let tiny = generateMap(MinMapSize)
    check tiny.red.len == tiny.blue.len
    check tiny.red.len > 0

  test "the two-column asymmetry is PRESENT":
    ## upstream's `0 < x` filter drops red's leftmost column, so blue starts
    ## two columns closer to contact than red's mirror would. It is upstream's,
    ## it is kept byte for byte, and it is neutralised by playing both sides --
    ## so a future tidy-up that MIRRORS the spawn must fail here.
    for mapSize in [31, 45]:
      let spawn = generateMap(mapSize)
      var redMin = mapSize
      var blueMax = 0
      for cell in spawn.red:
        redMin = min(redMin, cell.x)
      for cell in spawn.blue:
        blueMax = max(blueMax, cell.x)
      let mirrorOfRedMin = mapSize - 1 - redMin
      checkpoint("mapSize " & $mapSize & ": red min x " & $redMin &
        ", blue max x " & $blueMax & ", the mirror would be " &
        $mirrorOfRedMin)
      check blueMax != mirrorOfRedMin
      check mirrorOfRedMin - blueMax == 2

  test "squads partition every army, in nine contiguous blocks":
    for mapSize in [12, 31, 45, 64]:
      let spawn = generateMap(mapSize)
      for red in [true, false]:
        let
          cells = (if red: spawn.red else: spawn.blue)
          squads = assignSquads(cells, red)
        checkpoint("mapSize " & $mapSize & (if red: " red" else: " blue"))
        check squads.len == cells.len
        var counts = newSeq[int](SquadCount)
        for squad in squads:
          check squad >= 0 and squad < SquadCount
          inc counts[squad]
        let expected = squadPartition(cells.len)
        for k in 0 ..< SquadCount:
          check counts[k] == expected[k]
        ## squad 1 is the rearmost rank and squad 9 the front rank, for BOTH
        ## armies, whichever side of the board they hold
        var rearDepth = -1
        var frontDepth = -1
        for i, cell in cells:
          let depth = (if red: cell.x else: mapSize - 1 - cell.x)
          if squads[i] == 0:
            rearDepth = max(rearDepth, depth)
          if squads[i] == SquadCount - 1:
            frontDepth = max(frontDepth, depth)
        if counts[0] > 0 and counts[SquadCount - 1] > 0:
          check frontDepth >= rearDepth

  test "at mapSize 45 each squad is exactly one spawn column":
    let spawn = generateMap(45)
    let squads = assignSquads(spawn.red, true)
    var columns: array[SquadCount, seq[int]]
    for i, cell in spawn.red:
      if cell.x notin columns[squads[i]]:
        columns[squads[i]].add(cell.x)
    for k in 0 ..< SquadCount:
      check columns[k].len == 1
    check columns[0][0] == 1
    check columns[SquadCount - 1][0] == 17

  test "every variant's game_config spawns the right army size":
    ## A config-scaled construct that fits the small cert fixture and breaks the
    ## big variant is exactly the collab-cooking 0.1.1 failure, so EVERY
    ## variant is constructed and spawned here, not just the fixture's.
    let manifest = manifestJson()
    var checked = 0
    for variant in manifest["variants"]:
      let gameConfig = variant["game_config"]
      var config = defaultGameConfig()
      config.update($gameConfig)
      config.clampConfig()
      var sim = initSimServer(config)
      checkpoint("variant " & variant["id"].getStr())
      let expected = generateMap(config.mapSize)
      check sim.units.armyCount[0] == expected.red.len
      check sim.units.armyCount[1] == expected.blue.len
      check sim.units.armyCount[0] > 0
      check sim.units.aliveCount == sim.units.armyCount
      inc checked
    var config = defaultGameConfig()
    config.update($manifest["certification"]["game_config"])
    config.clampConfig()
    var sim = initSimServer(config)
    check sim.units.armyCount[0] == 30
    check sim.units.armyCount[1] == 30
    inc checked
    check checked == 3
