## Shared types, wire constants and the rune caps.
##
## GameVersion gates replay compatibility. The changelog comment below is
## PREPEND-ONLY (the starter's discipline, kept, with
## `tools/ci/check_gameversion.sh`): say what the number means and what it
## obsoletes, so two branches claiming one number are distinguishable.

import std/[strutils, unicode]

const
  GameVersion* = "1"
    ## GV1 (magent-battle v1): MAgent2 battle_v4 ported to a 45x45 integer
    ##   grid, two commander seats, nine squads each, two games with the sides
    ##   swapped. Obsoletes nothing.

  GameName* = "magent-battle"
  ReplayMagic* = "COWLDMAG"
  ReplayFormatVersion* = 1'u16
  ProtocolId* = "magent-battle/v1"

  MaxSayRunes* = 120
  MaxNoteRunes* = 240
  MaxPromptRunes* = 4000
  MaxPolicyLabelRunes* = 64
  MaxFallbackDetailRunes* = 200
  MaxStopDetailRunes* = 200
  MaxReplyBytes* = 8192
  MaxSquadIdRunes* = 2
  MaxVerbRunes* = 8
  MaxFlankSideRunes* = 5
  MaxDirectiveRunes* = 6000

  SquadCount* = 9
  SeatCount* = 2
  RoutLostThreshold* = 10
    ## An army that lost this many soldiers since the previous command turn is
    ## ROUTED: the threshold behind the `rout` feed event, the `rout` scrubber
    ## beat and the tier-2 `Rout` analysis event, in one place so the three
    ## cannot disagree.
  MaxUnits* = 400
    ## Sprite/object pool ceiling. 45x45 spawns 81 per army; the pools are
    ## sized above the largest configured board so a unit id never falls out
    ## of a pool mid-episode.

  TargetFps* = 30
    ## Presentation frame rate, and the denominator of the playback
    ## accumulator. The SIM rate is `replay_runtime.TicksPerSecondBase` (8
    ## ticks a second at speed 1), NOT one tick per frame: see
    ## `vendor/PATCHES.md` section 9 for why, and what it means for the soak.
  PlaybackSpeeds* = [1, 2, 4, 8]

  ReasonComplete* = "complete"
  ReasonDeadline* = "deadline"
  ReasonFault* = "fault"

  EndRuleWipe* = "wipe"
  EndRuleTickCap* = "tickCap"
  EndRuleWallClock* = "wallClock"
  EndRuleFault* = "fault"

type
  MagentError* = object of CatchableError
  SimGuardError* = object of MagentError
  ReplayError* = object of MagentError

  Phase* = enum
    Lobby, Playing, GameOver

  SlotConfig* = object
    team*: string
    token*: string

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    seed*: int
    numAgents*: int
    minPlayers*: int
    mapSize*: int
    maxTicks*: int
    maxGames*: int
    turnTicks*: int
    turnBudgetMs*: int
    turnSpacingMs*: int
    attempt1Ms*: int
    retryMs*: int
    wallClockBudgetSeconds*: int
    lobbyJoinTimeoutTicks*: int
    gameOverTicks*: int
    fastMode*: bool
    showPlayerLabels*: bool
    model*: string
    maxOutputTokens*: int
    players*: seq[PlayerConfig]
    slots*: seq[SlotConfig]
    tokens*: seq[string]

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single
  ## place any recorded string is shortened. Byte truncation is forbidden
  ## anywhere on the path to the replay: a half-codepoint renders in a browser
  ## and then fails a strict UTF-8 parser.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc truncateBytes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` BYTES, never mid-codepoint. For the one cap
  ## that is genuinely a byte budget -- how much of a provider reply is read
  ## before parsing -- where a rune cap would admit up to four times the bytes.
  ## Trailing continuation bytes are dropped rather than kept, so the result is
  ## always valid UTF-8 if the input was.
  if limit <= 0:
    return ""
  if text.len <= limit:
    return text
  var cut = limit
  while cut > 0 and (ord(text[cut]) and 0xC0) == 0x80:
    dec cut
  text[0 ..< cut]

proc sanitizeLine*(text: string, limit: int): string =
  ## A recorded free-text field: newlines collapse to spaces so one record
  ## stays one line, then the rune cap applies on a rune boundary.
  text.replace("\n", " ").replace("\r", " ").strip().truncateRunes(limit)

proc sanitizeSay*(text: string): string =
  ## The commander's spectator line. Rune-capped FIRST, then filtered to
  ## printable characters with braces excluded: the replay chat stream tells a
  ## control record from a plain line by a leading '{'.
  result = ""
  for rune in text.sanitizeLine(MaxSayRunes).runes:
    let value = int(rune)
    if value >= 32 and value != ord('{') and value != ord('}') and
        value != 127:
      result.add($rune)
  result = result.strip()
