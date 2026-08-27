## Every constant ported from MAgent2's `battle_v4`, each beside the line of
## `vendor/upstream/battle.py` it was read from.
##
## This module is the ONE place an upstream number is written down, and
## `tests/test_magent_upstream.nim` regex-parses the vendored file and asserts
## byte-equality against every entry here. A re-vendor that changes a number
## therefore FAILS THE TESTS instead of silently desyncing the game.
##
## Units. Upstream carries hp and rewards as Python floats. This port carries
## hp in TENTHS and rewards in THOUSANDTHS so the whole simulation is integer
## (design note §Integer arithmetic): `0.1` is not binary-exact, so upstream's
## own `step_recover` drifts under accumulation while `StepRecover = 1` tenth
## is exactly the intended semantics. The `*Upstream` values below are the
## decimal strings the tripwire compares; the integer values are what the sim
## runs on.

const
  UpstreamRepo* = "Farama-Foundation/MAgent2"
  UpstreamPath* = "magent2/environments/battle/battle.py"
  UpstreamCommit* = "0d2e0e344fa84411eeba4baf03dc3b7273c4f14d"
  UpstreamSha256* =
    "c5f589f0d81437bd55c3381b2bcf23a09b8f200f1049e84464cb3f20e26c37ed"

  # --- agent type "small" (battle.py, get_config options block) -------------
  HpUpstream* = "10"          ## "hp": 10
  SpeedUpstream* = "2"        ## "speed": 2
  DamageUpstream* = "2"       ## "damage": 2
  StepRecoverUpstream* = "0.1"      ## "step_recover": 0.1
  ViewRangeUpstream* = "6"          ## "view_range": gw.CircleRange(6)
  AttackRangeUpstream* = "1.5"      ## "attack_range": gw.CircleRange(1.5)
  KillRewardUpstream* = "5"         ## KILL_REWARD = 5
  StepRewardUpstream* = "-0.005"    ## step_reward=-0.005
  DeadPenaltyUpstream* = "-0.1"     ## dead_penalty=-0.1
  AttackPenaltyUpstream* = "-0.1"   ## attack_penalty=-0.1
  AttackOpponentRewardUpstream* = "0.2"  ## attack_opponent_reward=0.2
  DefaultMapSizeUpstream* = "45"    ## default_map_size = 45
  MaxCyclesUpstream* = "1000"       ## max_cycles_default = 1000
  MinMapSizeUpstream* = "12"        ## assert map_size >= 12
  SpawnInitNumFactorUpstream* = "0.04"  ## init_num = map_size * map_size * 0.04
  SpawnGapUpstream* = "3"           ## gap = 3
  SpawnStrideUpstream* = "2"        ## range(..., ..., 2)
  MinimapModeUpstream* = "False"    ## minimap_mode_default = False
  ExtraFeaturesUpstream* = "False"  ## extra_features=False

  # --- the integer forms the sim runs on ------------------------------------
  HpMax* = 100              ## 10.0 hp, in tenths
  Damage* = 20              ## 2.0 hp, in tenths
  StepRecover* = 1          ## 0.1 hp per tick, in tenths
  Speed* = 2                ## moves up to 2 cells (CircleRange(2))
  ViewRadius* = 6           ## CircleRange(6)
  ViewRadiusSq* = 36        ## dx*dx + dy*dy <= 36
  AttackRadiusSq* = 2       ## CircleRange(1.5): dx*dx+dy*dy <= 2 (the 8 Moore
                            ## neighbours; 2.25 floored to the integer grid)
  ActionCount* = 21         ## Discrete(21) = do_nothing + 12 moves + 8 attacks

  # Rewards in THOUSANDTHS of an upstream reward unit.
  StepRewardMilli* = -5
  DeadPenaltyMilli* = -100
  AttackPenaltyMilli* = -100
  AttackOpponentRewardMilli* = 200
  KillRewardMilli* = 5000

  DefaultMapSize* = 45
  MinMapSize* = 12
  MaxCyclesDefault* = 1000
  SpawnGap* = 3
  SpawnStride* = 2
  MinimapMode* = false
  ExtraFeatures* = false
