## The port-fidelity TRIPWIRE. `vendor/upstream/battle.py` is a byte-pristine
## copy of the upstream file at the pinned commit; this test regex-parses it and
## asserts byte-equality against every constant in `src/magent/upstream.nim`.
##
## A re-vendor that changes a number therefore FAILS TESTS instead of silently
## desyncing the game. That is the whole point: nothing else in the build reads
## upstream, so nothing else could notice.

import std/[os, strutils, unittest]
import helpers
import magent/upstream

proc upstreamSource(): string =
  readRepoFile("vendor/upstream/battle.py")

proc valueAfter(source, needle: string): string =
  ## The literal token that follows `needle` in the vendored file: skip the
  ## separators (`:`, `=`, whitespace, an opening paren) and read the number or
  ## identifier. Hand-rolled rather than `std/re` on purpose -- PCRE is a
  ## dynamic library the CI runner is not guaranteed to carry, and a missing
  ## libpcre would turn this tripwire into a red herring.
  ## Returns "" when the needle is absent, which fails the assertion reading it.
  let at = source.find(needle)
  if at < 0:
    return ""
  var i = at + needle.len
  while i < source.len and source[i] in {' ', '\t', ':', '=', '('}:
    inc i
  let start = i
  while i < source.len and
      (source[i] in {'0' .. '9'} or source[i] in {'a' .. 'z'} or
       source[i] in {'A' .. 'Z'} or source[i] in {'.', '-', '_'}):
    inc i
  source[start ..< i].strip()

suite "magent upstream fidelity":

  test "the vendored upstream file is present and pinned":
    check repoFileExists("vendor/upstream/battle.py")
    check repoFileExists("vendor/UPSTREAM.md")
    check repoFileExists("vendor/LICENSE-magent2")
    check repoFileExists("vendor/PATCHES.md")
    let record = readRepoFile("vendor/UPSTREAM.md")
    check UpstreamRepo in record
    check UpstreamCommit in record
    check UpstreamPath in record
    check UpstreamSha256 in record

  test "the agent-type options match":
    let source = upstreamSource()
    check source.valueAfter("\"hp\"") == HpUpstream
    check source.valueAfter("\"speed\"") == SpeedUpstream
    check source.valueAfter("\"damage\"") == DamageUpstream
    check source.valueAfter("\"step_recover\"") == StepRecoverUpstream
    check source.valueAfter("\"view_range\": gw.CircleRange") ==
      ViewRangeUpstream
    check source.valueAfter("\"attack_range\": gw.CircleRange") ==
      AttackRangeUpstream

  test "the reward terms match":
    let source = upstreamSource()
    check source.valueAfter("KILL_REWARD") == KillRewardUpstream
    check source.valueAfter("step_reward=") == StepRewardUpstream
    check source.valueAfter("dead_penalty=") == DeadPenaltyUpstream
    check source.valueAfter("attack_penalty=") == AttackPenaltyUpstream
    check source.valueAfter("attack_opponent_reward=") ==
      AttackOpponentRewardUpstream

  test "the board and cycle defaults match":
    let source = upstreamSource()
    check source.valueAfter("default_map_size") == DefaultMapSizeUpstream
    check source.valueAfter("max_cycles_default") == MaxCyclesUpstream
    check source.valueAfter("map_size >=") == MinMapSizeUpstream
    check source.valueAfter("minimap_mode_default") == MinimapModeUpstream
    check source.valueAfter("extra_features=") == ExtraFeaturesUpstream

  test "the spawn arithmetic matches":
    let source = upstreamSource()
    check source.valueAfter("init_num = map_size * map_size *") ==
      SpawnInitNumFactorUpstream
    check source.valueAfter("gap = ") == SpawnGapUpstream
    check source.valueAfter("side = int(math.sqrt(n)) *") == "2"
    ## the loop stride, read off the left block's range() call
    check source.valueAfter(
      "for x in range(width // 2 - gap - side, width // 2 - gap - side + side,"
      ) == SpawnStrideUpstream
    ## and the y range, so a change to either loop is caught
    check source.valueAfter(
      "for y in range((height - side) // 2, (height - side) // 2 + side,"
      ) == SpawnStrideUpstream
    check "pos = pos[:team1_size]" in source
    check "if 0 < x < width - 1 and 0 < y < height - 1:" in source

  test "the ported integers say the same thing as the upstream decimals":
    ## The port carries hp in TENTHS and rewards in THOUSANDTHS so the whole
    ## sim is integer. These assertions are how the two representations are
    ## tied together -- change one and this fails.
    check HpMax == 100 and HpUpstream == "10"
    check Damage == 20 and DamageUpstream == "2"
    check StepRecover == 1 and StepRecoverUpstream == "0.1"
    check Speed == 2 and SpeedUpstream == "2"
    check ViewRadius == 6 and ViewRangeUpstream == "6"
    check ViewRadiusSq == ViewRadius * ViewRadius
    ## CircleRange(1.5) floored onto the integer grid is the 8 Moore
    ## neighbours: 1*1 + 1*1 = 2 <= 2.25 and 2*2 = 4 > 2.25.
    check AttackRadiusSq == 2 and AttackRangeUpstream == "1.5"
    check KillRewardMilli == 5000 and KillRewardUpstream == "5"
    check StepRewardMilli == -5 and StepRewardUpstream == "-0.005"
    check DeadPenaltyMilli == -100 and DeadPenaltyUpstream == "-0.1"
    check AttackPenaltyMilli == -100 and AttackPenaltyUpstream == "-0.1"
    check AttackOpponentRewardMilli == 200 and
      AttackOpponentRewardUpstream == "0.2"
    check DefaultMapSize == 45 and MinMapSize == 12
    check MaxCyclesDefault == 1000
    check SpawnGap == 3 and SpawnStride == 2
    check MinimapMode == false and ExtraFeatures == false
    check ActionCount == 21
