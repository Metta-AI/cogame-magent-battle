# cogame-magent-battle

**A port of [MAgent2](https://github.com/Farama-Foundation/MAgent2)'s `battle_v4`
to a Coworld, with two ARMY COMMANDERS instead of 162 per-unit RL policies.**

Two armies of 81 identical soldiers meet on an open 45x45 integer grid. Every
soldier has 10 hp, deals 2 damage to one adjacent enemy per tick, moves up to two
cells per tick, and regains 0.1 hp per tick. Nobody plays a soldier.

Each of the **two seats is an army commander**. Once every 20 simulation ticks it
issues **one order to each of its nine squads** — `advance`, `hold x y`,
`focus <enemy squad>`, `flank left|right`, `retreat` — and a deterministic squad
controller turns those orders into the MAgent actions its soldiers actually take.
A commander sees only what its own soldiers can see: an enemy is visible only
when one of its own soldiers is within 6 cells of it.

The army with more soldiers standing when the game ends wins it. **An episode is
two games with the sides swapped**, so upstream's own two-column spawn asymmetry
cancels, and the seat that wins the pair wins the episode. Scoring is exactly
zero-sum:

```
score[s] = sum over both games of ( 100 * outcome + survivors[s] - survivors[opp] )
```

**A policy is just a prompt.** A champion sets `PLAYER_PROMPT` to a strategy in
plain English; the game server composes that prompt with the seat's own fogged
view and asks Claude for nine squad orders. A filler sets
`PLAYER_SCRIPTED=line|pincer` instead. Both come out of the same image.

- Rules, in full: [docs/RULES.md](docs/RULES.md)
- The protocol and the replay format: [docs/PROTOCOL.md](docs/PROTOCOL.md)
- What was ported, and every divergence: [docs/PORTING-MAGENT.md](docs/PORTING-MAGENT.md),
  [vendor/PATCHES.md](vendor/PATCHES.md)
- The design note this was built from:
  [docs/plans/2026-08-27-magent-battle-design.md](docs/plans/2026-08-27-magent-battle-design.md)

## Layout

```
src/magent_battle.nim          the game server entrypoint (seed randomisation lives HERE)
src/magent_battle_player.nim   the thin seat registrar -> /bin/magent-battle-player
src/magent/
  upstream.nim      every ported constant, beside the upstream line it came from
  arena.nim         the grid, the two CircleRange tables, upstream's generate_map
  units.nim         the soldiers, the occupancy grid, army-scale visibility
  sim.nim           the step loop; imports and RE-EXPORTS the sim modules
  sim_types.nim     GameVersion, the rune caps, GameConfig
  sim_config.nim    GameConfig lifecycle, config.update, the replay config JSON
  sim_state.nim     gameHash, the event sink, the lobby/game-over lifecycle
  control.nim       the deterministic squad controller
  directives.nim    the order schema and the tolerant, repairing validator
  baselines.nim     the `line` and `pincer` scripted baselines
  llm.nim           the Bedrock/Anthropic transport
  decide.nim        the per-turn PARALLEL batch, the deadlines, the fallback ladder
  episode.nim       one episode frame, shared by the server and the e2e test
  server.nim        the mummy server and the Coworld contract
  roster.nim        join/auth, the two name spaces, the results document
  replays.nim       the COWLDMAG codec
  replay_runtime.nim playback, the per-tick hash check, the load-time pre-scan
  broadcast.nim     the viewer state packet and the nine derived event kinds
  global.nim        the board payload (cell space, no pixel arena)
  labels.nim        the label vocabulary contract
  events.nim        the tier-2 JSON-lines analysis stream
client/             the broadcast chrome (see "The viewer" below)
replay-viewer/      the static wasm bundle: the SAME sim compiled to wasm
tests/              four balanced shards; run from the repo ROOT
tools/              CI, forensics and the art pipeline
vendor/upstream/    battle.py, byte-pristine at a pinned commit
```

## Building and testing

Dependencies come from [nimby](https://github.com/treeform/nimby); the
`Dockerfile` is the canonical build recipe.

```bash
nimby use 2.2.4
nimby --global sync nimby.lock
nim c -r --path:src tests/tests.nim        # the whole suite
nim r -d:release --path:src tests/shard_1.nim   # one CI shard
```

CI runs the four shards as separate binaries. The repo variable `NIM_TESTS` is
set to `tests/shard_1.nim tests/shard_2.nim tests/shard_3.nim tests/shard_4.nim`
so the shard binaries are what run; with the variable unset, `ci.yml` falls back
to every `tests/*.nim`, which is the same coverage and only slower.

One episode end to end, in raw docker, with the certification fixture's seat mix:

```bash
docker build --platform=linux/amd64 -t coworld-magent-battle:ci .
SMOKE_REQUIRE_REPLAY_JSON=0 ./tools/ci/docker_smoke.sh coworld-magent-battle:ci
```

## The viewer

**A static wasm bundle, never a pod.** The manifest declares
`game.replay_viewer = {"bundle": "static-replay-viewer"}` and
`tools/build_replay_viewer.sh` (the `coworld build` hook, committed executable)
compiles **the same `src/magent/sim.nim`** to wasm through
`Dockerfile.replay-viewer`. In the browser the module re-derives every frame from
the recorded orders and compares the per-tick `gameHash` against the recording,
so one divergent bit is caught at the tick it happens and surfaced in `#mmwarn`.

The chrome is coworld-ctf's. `client/chrome_common.js` is copied **byte for
byte** (a test pins its length and hash); `client/replay_broadcast.html` is the
starter's page with the elements the design note removes deleted and a
**MAGENT-BATTLE block appended** under a banner comment.
`tools/build_broadcast_page.py` performs exactly that transformation and is
committed, so the fork is auditable rather than a 4,700-line rewrite:

```bash
python3 tools/build_broadcast_page.py \
  --starter /path/to/coworld-ctf/client/replay_broadcast.html \
  --page-script client/page_script.js \
  --game-block client/game_block.html \
  --out client/replay_broadcast.html
```

What a spectator sees: the grid edge to edge with a baked cog chip per soldier,
an army heat overlay, a chalk front line that breaks where the front breaks, a
unit-count sparkline over the whole episode, two scorebug plates
(real policy name + in-game alias + side chip + alive count), the match feed in
plain language, and clickable labelled scrubber beats for `firstblood`, `rout`,
`wipe`, `fallback` and `end`. Legibility is checked at **360 px**, the width of
the featured-match iframe, not at desktop width.

## Forensics

```bash
curl -sSL "$replay_url" -o /tmp/ep.replay
python3 tools/replay_summary.py /tmp/ep.replay | jq .
```

`tools/replay_summary.py` is Python 3 stdlib only — no Nim, no Docker — and
prints one **strict-UTF-8 JSON** object describing the whole episode: the config,
the seed, the seat names, every squad order, every commander line and the full
results document. Every string that lands in the replay is truncated on a **rune**
boundary, which is what keeps that parse honest.

## Licence

MIT (see `LICENSE`). The vendored upstream file keeps its own licence in
`vendor/LICENSE-magent2`.
