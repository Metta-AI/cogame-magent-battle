# Rules

## The board

A `mapSize x mapSize` grid of cells, no obstacles. Cells outside the board read
as "obstacle / off-map". One soldier per cell. `mapSize` is **45** in the
`battle` variant (81 soldiers per army) and **31** in `skirmish` (30 per army);
both numbers come out of upstream's own `generate_map` arithmetic.

## The soldier

| | |
|---|---|
| hp | 10.0, carried internally in tenths (`HpMax = 100`) |
| damage | 2.0 to ONE adjacent enemy per tick |
| recovery | 0.1 hp per tick, capped at 10.0 |
| movement | up to 2 cells per tick (`CircleRange(2)`, 12 offsets) |
| attack reach | the 8 Moore neighbours (`CircleRange(1.5)`) |
| action space | 21: `do_nothing`, 12 moves, 8 attacks |

A soldier can move **or** attack, never both. A soldier that is not attacking is
healing. Nine soldiers on one enemy kill it in one tick; one soldier on one enemy
takes five ticks and takes damage back the whole time. **Local numbers are
everything.**

An attack against a soldier of your own army **is not registered** (upstream's
rule) — it deals no damage and earns no reward, but it still costs the attack
penalty.

## The seats

Exactly **two**, always. Each is an army commander, not a soldier. In game they
are `Alpha` (seat 0) and `Bravo` (seat 1), and those aliases are the only names
that appear in an observation, a prompt, an order or a label. The seats' real
policy names are spectator-side only.

Each army is partitioned into **exactly nine squads**, `A1`..`A9` for Alpha and
`B1`..`B9` for Bravo. Membership is fixed at spawn, by distance from the army's
own back edge: **squad 1 is the rearmost rank and squad 9 the front rank**, for
both armies, whichever side of the board they hold. At `mapSize 45` each squad is
exactly one spawn column.

## The clock

A **tick** is one MAgent cycle. A **command turn** is one order round, every
`turnTicks = 20` ticks, beginning with turn 1 at tick 0 before any stepping.
`maxTicks = 300` per game and `maxGames = 2`, so 15 command turns a game and 30
an episode.

## One tick, in order

1. `tick += 1`. Snapshot positions, hp and who is alive. Every rule below reads
   the snapshot, never a partially updated world.
2. **Choose one action per living soldier**, in ascending unit id, from its
   squad's current order via the squad controller.
3. **Resolve attacks**, in ascending attacker id. A hit subtracts 2.0 hp. At
   hp <= 0 the victim dies immediately: removed from the grid, its cell freed for
   step 4, the attacker paid the kill reward. Overkill therefore depends on
   attacker order, which is why that order is pinned.
4. **Resolve moves**, in ascending unit id. A move succeeds iff the destination
   is on the board and unoccupied at the moment of application, so a cell vacated
   in step 3 or by an earlier mover is available.
5. **Recover**: every living soldier gains 0.1 hp, capped at 10.0.
6. **Reward** (recorded, never scored — see below).
7. Mix the tick into `gameHash` and append it to the replay's chain.
8. Evaluate the game-end conditions.

## The orders

| Order | Target cell | May attack | Prefers |
|---|---|---|---|
| `advance` | the nearest living enemy | yes | the lowest-hp adjacent enemy |
| `hold x y` | `(x, y)` | yes | the lowest-hp adjacent enemy |
| `focus S` | the centroid of living enemy squad `S`; if `S` is extinct, behaves as `advance` | yes | members of `S` first, then lowest hp |
| `flank left`/`right` | the enemy centroid displaced 8 cells; once within 6 cells of that point, the enemy centroid itself | yes | the lowest-hp adjacent enemy |
| `retreat` | `(own back edge, own y)` | **no** | — |

Given a target cell: if the soldier may attack and a living enemy occupies one of
the 8 attack offsets, it attacks. Otherwise it takes the move offset that gets
strictly closer to the target; if no move does, it does nothing. There is **no
randomness in the controller at all**.

A squad the commander does not mention keeps the order it had. Turn 1's default
for every squad is `advance`. An order whose fields do not validate is
**repaired to the squad's previous order**, never dropped — no failure mode ever
leaves a soldier unactuated.

## Winning

A **game** ends at the first of: **annihilation** (an army reaches 0 living
soldiers; both at once is a draw) -> `wipe`; the **tick cap**, settled by
survivor count -> `tickCap`; or the engine's **wall-clock stop** -> `wallClock`.

Per game, with `survivors[s]` the seat's living soldiers when the game ends:

```
outcome[s] = +1 if survivors[s] > survivors[opp], 0 if equal, -1 if fewer
score[s]   = sum over both games of ( 100 * outcome[s]
                                      + survivors[s] - survivors[opp] )
```

**Higher is better**, and the formula is exactly zero-sum: `score[0] + score[1]`
is always 0, so no pair of seats can raise their joint total by cooperating. The
`100 x` term makes winning the two games dominate; the survivor differential is
the tiebreak that rewards winning cleanly rather than by one soldier. At
`mapSize 45` the range is `[-362, +362]`.

MAgent's own per-soldier rewards (`step -0.005`, `dead -0.1`, `attack -0.1`,
`attack_opponent +0.2`, `kill +5`) are summed per seat into
`results.magentReward` and shown on the endcard, but do **not** enter the score:
they are the port's fidelity evidence and a spectator readout, and scoring off
them would reward attack-spam over winning.

## Sides swap

Seat 0 is **red** (the left spawn) in game 1 and **blue** in game 2; seat 1 the
reverse. Both games use the same seed, so both seats play the identical starting
position from both sides. This is not decoration: upstream's `generate_map` is
asymmetric by two columns (see `vendor/PATCHES.md` divergence 5), and playing
both sides is how that is neutralised without editing upstream.

## Degrade, never hang

Every wait is bounded. A commander gets 9 s for its first reply and 4 s for one
retry, both issued as ONE parallel batch across the two seats; the whole turn
sits inside a 14 s monotonic deadline. A seat that times out, errors or returns
unusable JSON twice plays the `pincer` scripted orders for that turn and a
`fallback` record names the cause. If two more full turns would not fit inside
the engine's own 660 s stop, the LLM is switched off for the rest of the episode
and the remaining ticks run at full speed — so the episode ends `complete`, not
`deadline`. A seat that never connects does not end the episode: its army plays
`pincer` and both games run to their natural end.
