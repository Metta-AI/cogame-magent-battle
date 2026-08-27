# Documented divergences — from upstream `battle_v4` and from the design note

Every difference between this port and `vendor/upstream/battle.py`, and why.
Anything not listed here is upstream's, and `tests/test_magent_upstream.nim`
plus `tests/test_magent_spawn.nim` are the gates that keep it that way.

Sections 1-5 and 8 are divergences from **upstream**. Sections 6, 7 and above
are divergences from the **design note** (`docs/plans/`): the note said one
thing, the build measured another, and the file records which and why. Both
kinds live here so there is exactly one place to look.

## 1. HP and rewards are integers

Upstream carries `hp` as a float (`10`, recovering `0.1` a tick) and the five
reward terms as floats. This port carries **hp in tenths** (`HpMax = 100`,
`Damage = 20`, `StepRecover = 1`) and **rewards in thousandths** (`step -5`,
`dead -100`, `attack -100`, `attackOpponent +200`, `kill +5000`), dividing by
1000 only when a number is written out.

Semantics are identical and determinism is strictly better: `0.1` is not binary
exact, so upstream's own accumulation drifts, while a tenth is exactly the
intended quantity. It is also the precondition for the native <-> wasm hash
chain — the browser re-simulates the episode and compares a per-tick
`gameHash`, which no float path could survive.

## 2. Resolution order is pinned

All attacks in ascending unit id, then all moves in ascending unit id, then
recovery. MAgent's C++ engine resolves in an internal order that cannot be
verified from the Python layer; a fixed order is required for a replay to be
re-derivable at all.

The attack phase reads a **snapshot** of who was alive at the start of the tick,
so a soldier killed by a lower id in the same phase still lands the blow it had
already thrown. That is what makes mutual annihilation reachable and keeps the
phase a function of the snapshot rather than of its own partial results.

## 3. Who chooses the action changed, not what the actions are

Per-unit RL policies are replaced by a deterministic **squad controller** under
**two commander seats** — the source idea's explicit "policy-per-army" seating.
The 21-action space, both `CircleRange` tables, damage, recovery, the
no-friendly-fire rule and all five reward terms are upstream's.

## 4. `maxTicks` 300 x `maxGames` 2 instead of `max_cycles = 1000` in one game

To fit the 720 s play budget and, more importantly, to neutralise the spawn
asymmetry of divergence 5 by swapping sides. Recorded in the replay config so a
viewer can never mistake it for the upstream default. The `skirmish` variant is
200 x 2 on a 31x31 board.

## 5. The spawn asymmetry is KEPT, not fixed

`generate_map`'s `0 < x` filter makes the two blocks asymmetric: at
`map_size = 45` red holds columns `{1,3,…,17}` and blue `{25,27,…,41}`, where
red's mirror about the centre column would be `{27,…,43}` — so blue starts two
columns closer to contact. It is small and it is upstream's, so the port keeps
it **byte for byte** and neutralises it by playing every position from both
sides. `tests/test_magent_spawn.nim` asserts the asymmetry is still PRESENT, so
a future "tidy-up" that mirrors the spawn fails the gate loudly.

## 6. The squad controller reads occupancy at DECISION time

The controller picks, among the twelve move offsets, the destination minimising
squared distance to its target cell, and emits `do_nothing` when no move
improves on where it already stands. **Destinations occupied in the tick
snapshot are skipped.**

This is a deliberate departure from the design note, which said occupancy is not
consulted here at all. That rule deadlocks: for `advance` and `focus` the target
IS the enemy's own cell, so the argmin move is always onto the enemy and always
blocked. Two lines two cells apart each pick a blocked cell, neither ever
becomes adjacent, and **every game ends 81 v 81 at the tick cap with zero
kills** — measured, not theorised.

A blocked move can still fail at resolution — two soldiers may pick the same
empty cell, and a cell freed by a kill or taken by an earlier mover changes
underneath the decision — so a dense formation still shuffles rather than
teleports, which is the property the original rule existed to preserve.

## 7. `mapSize = 31` yields 30 soldiers per army, not 25

Running upstream's own arithmetic at `map_size = 31`: `init_num = 38.44`,
`side = int(sqrt(38.44)) * 2 = 12`, the x range is `range(0, 12, 2)` which the
`0 < x` filter cuts to `{2,4,6,8,10}` (5 columns), and the y range is
`range(9, 21, 2)` = `{9,11,13,15,17,19}` (6 rows) — so 30 positions, truncated
to 30 on the right. The design note said 25/25; the transcription says 30/30 and
`tests/test_magent_spawn.nim` asserts the transcription, exactly as the note
itself instructed ("asserts the number rather than trusting this paragraph").
The `skirmish` variant name and description carry 30.

## 8. `minimap_mode` and `extra_features`

Upstream defaults (`False` / `False`) are kept. The commander's fog-of-war
summary replaces them; no seat ever receives the 13x13x5 observation tensor.

## 9. Playback is 8 SIM TICKS A SECOND, and the speed chips are `[1,2,4,8]`

The design note specified "1 tick per animation frame at 30 fps (speed chips
`[0.5, 1, 2, 4, 8]`, default 1)", i.e. a 600-tick episode playing for 20 s.
What ships is `replay_runtime.TicksPerSecondBase = 8`: `advanceReplayFrame`
adds `speed * 8` to an integer accumulator every presentation frame and runs
one sim frame per `TargetFps` (30) accumulated, capped at 8 frames a call.
`PlaybackSpeeds = [1, 2, 4, 8]` and `applyCommand` maps the keys `1/2/4/8`, so
there is no 0.5 chip.

One MAgent cycle is a whole exchange of blows and a decided game runs 30-60
ticks, so one tick per animation frame flashes a whole episode past in four
seconds -- which is exactly what the note's own reason for the rate (a soak
must observe advancement rather than a finished replay) needs not to happen. At
8 ticks/s the CI replay (123 frames) plays for ~15 s and a full 600-tick
episode for ~75 s. `TargetFps` stays 30 because it is still the presentation
rate and the accumulator's denominator.
