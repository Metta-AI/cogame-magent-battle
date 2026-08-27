## The board: a `mapSize x mapSize` integer grid with no obstacles (this is
## upstream `battle`, not `battlefield`), the two `CircleRange` offset tables,
## a direct transcription of upstream's `generate_map`, the squad partition and
## the occupancy grid.
##
## PURE INTEGER. No pixie, no pixel queries, no floating point -- the native
## and wasm builds must agree bit for bit, and
## `tests/test_magent_sim.nim`'s no-float grep enforces it mechanically.

import upstream, sim_types

type
  Offset* = tuple[dy, dx: int]

  SpawnCell* = tuple[x, y: int]

const
  MoveOffsets*: array[12, Offset] = [
    (-2, 0), (-1, -1), (-1, 0), (-1, 1), (0, -2), (0, -1),
    (0, 1), (0, 2), (1, -1), (1, 0), (1, 1), (2, 0)
  ]
    ## CircleRange(2): dx*dx + dy*dy <= 4, centre excluded, in the fixed order
    ## action indices 1..12 map onto.

  AttackOffsets*: array[8, Offset] = [
    (-1, -1), (-1, 0), (-1, 1), (0, -1),
    (0, 1), (1, -1), (1, 0), (1, 1)
  ]
    ## CircleRange(1.5): the 8 Moore neighbours, in the fixed order action
    ## indices 13..20 map onto.

  ActionDoNothing* = 0
  ActionMoveBase* = 1
  ActionAttackBase* = 13

proc isqrt*(value: int): int =
  ## Integer square root, floor. Newton's method on integers -- no `math.sqrt`,
  ## because a float sqrt is exactly the kind of platform-dependent rounding
  ## the native <-> wasm hash chain cannot tolerate.
  if value <= 0:
    return 0
  var
    guess = value
    next = (value + 1) shr 1
  while next < guess:
    guess = next
    next = (guess + value div guess) shr 1
  guess

proc spawnSide*(mapSize: int): int =
  ## `init_num = map_size * map_size * 0.04; side = int(sqrt(init_num)) * 2`
  ## in integers. `map_size * map_size * 0.04` is `mapSize*mapSize*4 div 100`
  ## under a floor, and floor(sqrt(f)) == floor(sqrt(floor(f))) for every f of
  ## that shape (an integer square strictly between floor(f) and f cannot
  ## exist), so the transcription is exact rather than approximate.
  isqrt((mapSize * mapSize * 4) div 100) * 2

proc generateMap*(mapSize: int): tuple[red, blue: seq[SpawnCell]] =
  ## The transcription of upstream `BattleEnv.generate_map`, loop for loop:
  ##
  ##   width = height = map_size; gap = 3; side as above
  ##   left:  x in range(w//2 - gap - side, w//2 - gap - side + side, 2)
  ##   right: x in range(w//2 + gap,        w//2 + gap + side,        2)
  ##   both:  y in range((h - side)//2,     (h - side)//2 + side,     2)
  ##   keep   0 < x < w-1 and 0 < y < h-1
  ##   right is truncated to len(left)
  ##
  ## The `0 < x` filter is what makes the two blocks ASYMMETRIC (at
  ## mapSize 45 red holds columns 1..17 and blue 25..41, where red's mirror
  ## would be 27..43). That is upstream's, so it is kept byte for byte and
  ## neutralised by playing both sides -- `tests/test_magent_spawn.nim`
  ## asserts the asymmetry is still PRESENT so a future tidy-up fails loudly.
  let
    width = mapSize
    height = mapSize
    side = spawnSide(mapSize)
    yStart = (height - side) div 2
  var x = width div 2 - SpawnGap - side
  while x < width div 2 - SpawnGap - side + side:
    var y = yStart
    while y < yStart + side:
      if x > 0 and x < width - 1 and y > 0 and y < height - 1:
        result.red.add((x, y))
      y += SpawnStride
    x += SpawnStride
  let leftSize = result.red.len
  x = width div 2 + SpawnGap
  while x < width div 2 + SpawnGap + side:
    var y = yStart
    while y < yStart + side:
      if x > 0 and x < width - 1 and y > 0 and y < height - 1:
        result.blue.add((x, y))
      y += SpawnStride
    x += SpawnStride
  if result.blue.len > leftSize:
    result.blue.setLen(leftSize)

proc squadPartition*(count: int): array[SquadCount, int] =
  ## How many soldiers each of the nine squads gets: `count div 9` for every
  ## squad, plus one for the first `count mod 9`. At mapSize 45 that is nine
  ## squads of nine (one spawn column each); at 31 it is 4,4,4,3,3,3,3,3,3.
  let
    base = count div SquadCount
    extra = count mod SquadCount
  for k in 0 ..< SquadCount:
    result[k] = base + (if k < extra: 1 else: 0)

proc assignSquads*(cells: seq[SpawnCell], red: bool): seq[int] =
  ## Squad index per spawn cell. Membership is by initial position: sorted by
  ## distance from the army's OWN back edge (red ascending x, blue descending
  ## x), ties by ascending y, then split into nine contiguous blocks. Squad 1
  ## is therefore the rearmost rank and squad 9 the front rank, for both
  ## armies, whichever side of the board they hold.
  result = newSeq[int](cells.len)
  var order = newSeq[int](cells.len)
  for i in 0 ..< cells.len:
    order[i] = i
  # Insertion sort: n is at most a few hundred and a stable, dependency-free
  # sort keeps the ordering identical on every platform.
  for i in 1 ..< order.len:
    let cur = order[i]
    var j = i - 1
    while j >= 0:
      let a = cells[order[j]]
      let b = cells[cur]
      let aKey = (if red: a.x else: -a.x)
      let bKey = (if red: b.x else: -b.x)
      if aKey > bKey or (aKey == bKey and a.y > b.y):
        order[j + 1] = order[j]
        dec j
      else:
        break
    order[j + 1] = cur
  let sizes = squadPartition(cells.len)
  var
    squad = 0
    used = 0
  for pos in 0 ..< order.len:
    while squad < SquadCount - 1 and used >= sizes[squad]:
      inc squad
      used = 0
    result[order[pos]] = squad
    inc used

proc cellIndex*(mapSize, x, y: int): int {.inline.} =
  y * mapSize + x

proc onBoard*(mapSize, x, y: int): bool {.inline.} =
  x >= 0 and y >= 0 and x < mapSize and y < mapSize

proc distSq*(ax, ay, bx, by: int): int {.inline.} =
  let
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy
