## Shared test scaffolding: a configured sim, a headless episode, and the
## repo-root path resolution the tests read source files through.
##
## Every test runs from the repo ROOT (`nim r tests/<file>.nim`), which is what
## the source-grep gates and the manifest read depend on.

import std/[json, os, strutils]
import magent/[sim, baselines, decide, episode, replays]

export sim, baselines, decide, episode, replays

proc repoRoot*(): string =
  ## The repo root, resolved from THIS file rather than from the cwd, so a
  ## shard binary run from anywhere still finds the sources it greps.
  currentSourcePath().parentDir().parentDir()

proc readRepoFile*(relative: string): string =
  readFile(repoRoot() / relative)

proc repoFileExists*(relative: string): bool =
  fileExists(repoRoot() / relative)

proc testConfig*(mapSize = 31, maxTicks = 300, maxGames = 2): GameConfig =
  result = defaultGameConfig()
  result.seed = 42
  result.mapSize = mapSize
  result.maxTicks = maxTicks
  result.maxGames = maxGames
  result.turnTicks = 20
  result.turnSpacingMs = 0
  result.gameOverTicks = 2
  result.lobbyJoinTimeoutTicks = 1
  result.players = @[PlayerConfig(name: "Alpha"), PlayerConfig(name: "Bravo")]
  result.slots = @[SlotConfig(team: "red"), SlotConfig(team: "blue")]
  result.clampConfig()

proc playingSim*(mapSize = 31): SimServer =
  ## A sim with both armies spawned and the first game started.
  result = initSimServer(testConfig(mapSize = mapSize))
  result.applyGameStart(0, 0)

proc emptyBoard*(mapSize = 31): SimServer =
  ## A started game with every soldier removed, so a unit test can place
  ## exactly the soldiers it wants to reason about.
  result = playingSim(mapSize)
  result.units.soldiers.setLen(0)
  result.units.armyCount = [0, 0]
  result.units.aliveCount = [0, 0]
  result.units.clearOccupancy()

proc place*(sim: var SimServer, x, y, army, squad: int, hp = HpMax): int =
  ## Adds one soldier and returns its unit id. Ids ascend in call order, which
  ## is the resolution order the whole tick is pinned to.
  result = sim.units.soldiers.len
  sim.units.soldiers.add(Soldier(
    x: x, y: y, hp: hp, army: army, squad: squad, alive: true))
  sim.units.occupancy[cellIndex(sim.units.mapSize, x, y)] = result
  inc sim.units.armyCount[army]
  inc sim.units.aliveCount[army]

proc setOrder*(
  sim: var SimServer, seat, squad: int, kind: OrderKind,
  x = 0, y = 0, target = -1, side = fsLeft
) =
  sim.directives[seat].orders[squad] = SquadOrder(
    kind: kind, x: x, y: y, target: target, side: side, fromReply: true)
  sim.haveDirective[seat] = true

proc scriptedEngine*(
  config: GameConfig, first = blPincer, second = blLine
): DecisionEngine =
  result = initDecisionEngine(config)
  result.seats[0].baseline = first
  result.seats[0].label = $first
  result.seats[1].baseline = second
  result.seats[1].label = $second

proc runScriptedEpisode*(
  config: GameConfig, replayPath = "",
  first = blPincer, second = blLine,
  joinSeats: set[uint8] = {0'u8, 1'u8}
): tuple[sim: SimServer, state: EpisodeState, bytes: string] =
  var engine = scriptedEngine(config, first, second)
  runHeadlessEpisode(config, engine, replayPath, joinSeats)

proc stripNimComments*(source: string): string =
  ## Source with `#`/`##` comments removed, so a token grep asks about CODE.
  ## Naive about `#` inside string literals -- the sim modules the float gate
  ## covers contain none, and the gate itself asserts that.
  var lines: seq[string]
  for line in source.splitLines():
    var inString = false
    var kept = ""
    var i = 0
    while i < line.len:
      let ch = line[i]
      if ch == '"':
        inString = not inString
      if ch == '#' and not inString:
        break
      kept.add(ch)
      inc i
    lines.add(kept)
  lines.join("\n")

proc manifestJson*(): JsonNode =
  parseJson(readRepoFile("coworld_manifest_template.json"))
