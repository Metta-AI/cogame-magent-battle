# Porting MAgent battle

## What was ported

MAgent2's `battle_v4`, from
`Farama-Foundation/MAgent2:magent2/environments/battle/battle.py` at commit
`0d2e0e344fa84411eeba4baf03dc3b7273c4f14d`. The file is vendored **byte-pristine**
at `vendor/upstream/battle.py` and never edited; `vendor/UPSTREAM.md` records the
fetch URL and the sha256.

Everything ported is in one place, `src/magent/upstream.nim`, each constant beside
the upstream line it came from:

| Upstream fact | Value |
|---|---|
| `default_map_size` | 45 |
| Agents | 162 total, 81 per army |
| Agent type `small` | `width 1, length 1, hp 10, speed 2, damage 2, step_recover 0.1` |
| `view_range` | `CircleRange(6)` -> a 13x13 local view |
| `attack_range` | `CircleRange(1.5)` -> the 8 Moore neighbours |
| Action space | `Discrete(21)` = `[do_nothing, move_12, attack_8]` |
| `max_cycles` | 1000 |
| Rewards | `step -0.005`, `dead -0.1`, `attack -0.1`, `attack_opponent +0.2`, `KILL_REWARD 5` |
| Friendly fire | not registered |
| Spawn | `generate_map`: two blocks, `init_num = map_size**2 * 0.04`, `side = int(sqrt(init_num)) * 2`, `gap = 3`, stride 2, right block truncated to the left block's size |
| Defaults kept | `minimap_mode = False`, `extra_features = False` |

## The four gates that keep it ported

Nothing else in the build reads upstream, so nothing else could notice a drift.

1. **`vendor/upstream/battle.py`, byte-pristine at a pinned commit**, with its
   sha256 in `vendor/UPSTREAM.md`.
2. **The tripwire** — `tests/test_magent_upstream.nim` parses the vendored file
   and asserts byte-equality against every constant in `upstream.nim`: hp, speed,
   damage, step_recover, view_range, attack_range, KILL_REWARD, the four reward
   terms, default_map_size, max_cycles, the minimum map size, and the
   `init_num`/`side`/`gap`/stride spawn arithmetic. A re-vendor that changes a
   number **fails tests**.
3. **The spawn transcription** — `tests/test_magent_spawn.nim` runs an
   INDEPENDENT transcription of `generate_map` (written from the Python text, and
   the one place this port is allowed a float) for
   `mapSize in {12, 31, 45, 64}` and asserts equality position for position; it
   asserts 81/81 at 45 and 30/30 at 31; and it asserts the two-column asymmetry
   is still **present**, so a future tidy-up that mirrors the spawn fails loudly.
4. **Determinism** — `tests/test_magent_determinism.nim` records an episode,
   re-simulates it from the replay's seed and order records alone on a fresh sim,
   and asserts identical final tick, winner, survivor counts and per-tick
   `gameHash`. The browser viewer runs that same comparison live, every tick.

## Why the arithmetic is integer

`HpMax = 100` (tenths), `Damage = 20`, `StepRecover = 1`; rewards in thousandths.
`0.1` is not binary exact, so upstream's own float accumulation drifts, while a
tenth is exactly the intended quantity — this port is *more* faithful, not less.
It is also the precondition for the native <-> wasm hash chain: the same
`src/magent/sim.nim` compiles natively for the server and to wasm32 for the
viewer, and no float path would survive that comparison. A source grep in
`tests/test_magent_sim.nim` mechanically enforces the absence of `float`, `/` and
`sqrt` in `sim`, `units`, `arena`, `control` and `baselines`.

## What changed, and why

Every divergence is enumerated in [`vendor/PATCHES.md`](../vendor/PATCHES.md) with
its reason. The short list:

1. hp and rewards in integers;
2. resolution order pinned (attacks by ascending id, then moves, then recovery),
   with the attack phase reading a start-of-tick snapshot;
3. **who chooses the action** changed — two commander seats and a deterministic
   squad controller instead of 162 per-unit RL policies — while the 21-action
   space, both `CircleRange` tables, damage, recovery, the no-friendly-fire rule
   and all five reward terms are upstream's;
4. `maxTicks 300 x maxGames 2` instead of one 1000-cycle game;
5. the spawn asymmetry **kept** and neutralised by swapping sides;
6. the squad controller reads occupancy at DECISION time (without this the game
   deadlocks — measured);
7. `mapSize 31` yields 30 per army, not the 25 the design note guessed;
8. `minimap_mode` / `extra_features` at their upstream defaults.

## Out of scope

The other four MAgent scenarios (`battlefield`, `gather`, `tiger_deer`,
`adversarial_pursuit`); N-squad seating (one policy per squad, 18 seats);
per-unit RL policies and pretrained MAgent weights — no weights are vendored, no
inference module ships, and no seat ever receives the 13x13x5 observation tensor;
army sizes above upstream's own 81 per side; and anything per-soldier from the
LLM — commanders issue nine squad orders and never name a soldier, a path or a
raw action index.
