## GameConfig lifecycle: the defaults every variant starts from, the
## `config.update` merge the runner's JSON drives, and the resolved config JSON
## the replay header carries.

import std/[json, strutils]
import sim_types, upstream, arena

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    numAgents: SeatCount,
    minPlayers: SeatCount,
    mapSize: DefaultMapSize,
    maxTicks: 300,
    maxGames: 2,
    turnTicks: 20,
    turnBudgetMs: 14000,
    turnSpacingMs: 8000,
    attempt1Ms: 9000,
    retryMs: 4000,
    wallClockBudgetSeconds: 660,
    lobbyJoinTimeoutTicks: 2400,
    gameOverTicks: 30,
    fastMode: true,
    showPlayerLabels: false,
    model: "claude-haiku-4-5-20251001",
    maxOutputTokens: 900,
    players: @[],
    slots: @[],
    tokens: @[]
  )

proc clampConfig*(config: var GameConfig) =
  ## Every bound the sim relies on, applied in one place. A hosted config is
  ## repaired, never rejected: an episode that refuses to start scores nobody.
  config.numAgents = max(1, min(SeatCount, config.numAgents))
  config.minPlayers = max(0, min(config.numAgents, config.minPlayers))
  config.mapSize = max(MinMapSize, min(128, config.mapSize))
  config.maxTicks = max(1, min(MaxCyclesDefault, config.maxTicks))
  config.maxGames = max(1, min(8, config.maxGames))
  config.turnTicks = max(1, min(config.maxTicks, config.turnTicks))
  config.turnBudgetMs = max(0, min(60000, config.turnBudgetMs))
  config.turnSpacingMs = max(0, min(60000, config.turnSpacingMs))
  config.attempt1Ms = max(1000, min(30000, config.attempt1Ms))
  config.retryMs = max(1000, min(30000, config.retryMs))
  config.wallClockBudgetSeconds =
    max(10, min(660, config.wallClockBudgetSeconds))
  config.lobbyJoinTimeoutTicks = max(1, config.lobbyJoinTimeoutTicks)
  config.gameOverTicks = max(0, min(600, config.gameOverTicks))
  config.maxOutputTokens = max(1, config.maxOutputTokens)

proc getIntOr(node: JsonNode, key: string, fallback: int): int =
  let value = node{key}
  if value.isNil:
    return fallback
  case value.kind
  of JInt: int(value.getBiggestInt())
  of JFloat: int(value.getFloat())
  of JString:
    try: parseInt(value.getStr().strip())
    except CatchableError: fallback
  else: fallback

proc getBoolOr(node: JsonNode, key: string, fallback: bool): bool =
  let value = node{key}
  if value.isNil:
    return fallback
  case value.kind
  of JBool: value.getBool()
  of JInt: value.getBiggestInt() != 0
  else: fallback

proc update*(config: var GameConfig, text: string) =
  ## Merges one runner-supplied JSON config. Unknown keys are ignored; every
  ## known key is clamped by `clampConfig`.
  if text.strip().len == 0:
    return
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError as error:
    raise newException(MagentError, "config is not JSON: " & error.msg)
  if node.kind != JObject:
    raise newException(MagentError, "config must be a JSON object")
  config.seed = node.getIntOr("seed", config.seed)
  config.numAgents = node.getIntOr("num_agents", config.numAgents)
  config.minPlayers = node.getIntOr("minPlayers", config.minPlayers)
  config.mapSize = node.getIntOr("mapSize", config.mapSize)
  config.maxTicks = node.getIntOr("maxTicks", config.maxTicks)
  config.maxGames = node.getIntOr("maxGames", config.maxGames)
  config.turnTicks = node.getIntOr("turnTicks", config.turnTicks)
  config.turnBudgetMs = node.getIntOr("turnBudgetMs", config.turnBudgetMs)
  config.turnSpacingMs = node.getIntOr("turnSpacingMs", config.turnSpacingMs)
  config.attempt1Ms = node.getIntOr("attempt1Ms", config.attempt1Ms)
  config.retryMs = node.getIntOr("retryMs", config.retryMs)
  config.wallClockBudgetSeconds =
    node.getIntOr("wallClockBudgetSeconds", config.wallClockBudgetSeconds)
  config.lobbyJoinTimeoutTicks =
    node.getIntOr("lobbyJoinTimeoutTicks", config.lobbyJoinTimeoutTicks)
  config.gameOverTicks = node.getIntOr("gameOverTicks", config.gameOverTicks)
  config.fastMode = node.getBoolOr("fastMode", config.fastMode)
  config.showPlayerLabels =
    node.getBoolOr("showPlayerLabels", config.showPlayerLabels)
  config.maxOutputTokens =
    node.getIntOr("maxOutputTokens", config.maxOutputTokens)
  if not node{"model"}.isNil and node{"model"}.kind == JString:
    config.model = node{"model"}.getStr()
  if not node{"players"}.isNil and node{"players"}.kind == JArray:
    config.players = @[]
    for entry in node{"players"}:
      config.players.add(PlayerConfig(name: entry{"name"}.getStr()))
  if not node{"slots"}.isNil and node{"slots"}.kind == JArray:
    config.slots = @[]
    for entry in node{"slots"}:
      config.slots.add(SlotConfig(
        team: entry{"team"}.getStr(), token: entry{"token"}.getStr()))
  if not node{"tokens"}.isNil and node{"tokens"}.kind == JArray:
    config.tokens = @[]
    for entry in node{"tokens"}:
      config.tokens.add(entry.getStr())
  config.clampConfig()

proc configuredPlayerName*(config: GameConfig, slot: int): string =
  if slot >= 0 and slot < config.players.len:
    return config.players[slot].name
  ""

proc playerJoinAllowed*(config: GameConfig, slot: int, token: string): bool =
  ## Token discipline: a configured slot with a token admits only that token.
  ## An unconfigured slot inside `numAgents` is open (the smoke harness and
  ## local development both join without one).
  if slot < 0 or slot >= config.numAgents:
    return false
  if slot < config.tokens.len and config.tokens[slot].len > 0:
    return token == config.tokens[slot]
  if slot < config.slots.len and config.slots[slot].token.len > 0:
    return token == config.slots[slot].token
  true

proc configJson*(config: GameConfig): string =
  ## The resolved config, embedded verbatim in the replay header. It carries
  ## the seed, the seat count, every upstream constant and the REAL player
  ## names, so the bytes explain the episode with no server in the loop.
  var players = newJArray()
  for entry in config.players:
    players.add(%*{"name": entry.name})
  var slots = newJArray()
  for entry in config.slots:
    slots.add(%*{"team": entry.team})
  $(%*{
    "game": GameName,
    "gameVersion": GameVersion,
    "protocol": ProtocolId,
    "seed": config.seed,
    "num_agents": config.numAgents,
    "minPlayers": config.minPlayers,
    "mapSize": config.mapSize,
    "maxTicks": config.maxTicks,
    "maxGames": config.maxGames,
    "turnTicks": config.turnTicks,
    "turnBudgetMs": config.turnBudgetMs,
    "turnSpacingMs": config.turnSpacingMs,
    "attempt1Ms": config.attempt1Ms,
    "retryMs": config.retryMs,
    "wallClockBudgetSeconds": config.wallClockBudgetSeconds,
    "lobbyJoinTimeoutTicks": config.lobbyJoinTimeoutTicks,
    "gameOverTicks": config.gameOverTicks,
    "fastMode": config.fastMode,
    "showPlayerLabels": config.showPlayerLabels,
    "spawnSide": spawnSide(config.mapSize),
    "upstream": {
      "repo": UpstreamRepo,
      "commit": UpstreamCommit,
      "path": UpstreamPath,
      "hpMax": HpMax,
      "damage": Damage,
      "stepRecover": StepRecover,
      "speed": Speed,
      "viewRadius": ViewRadius,
      "attackRadiusSq": AttackRadiusSq,
      "actionCount": ActionCount,
      "stepRewardMilli": StepRewardMilli,
      "deadPenaltyMilli": DeadPenaltyMilli,
      "attackPenaltyMilli": AttackPenaltyMilli,
      "attackOpponentRewardMilli": AttackOpponentRewardMilli,
      "killRewardMilli": KillRewardMilli,
      "minimapMode": MinimapMode,
      "extraFeatures": ExtraFeatures
    },
    "players": players,
    "slots": slots
  })
