# Protocol

## The Coworld contract

| Direction | Env var / route | What |
|---|---|---|
| in | `COGAME_CONFIG_URI` | the episode's `game_config` JSON |
| out | `COGAME_RESULTS_URI` | the results document below |
| out | `COGAME_SAVE_REPLAY_URI` | the `COWLDMAG` replay bytes |
| out | `COGAME_PLAYER_FAILURE_URI` | `{"message", "failed_policy_index"}` and nothing else |
| out | `COGAME_EVENTS_URI` | the tier-2 JSON-lines analysis stream (`file://` only) |
| in | `COGAME_LOAD_REPLAY_URI` | local replay mode |
| in | `HOST` / `PORT` / `COGAME_HOST` / `COGAME_PORT` | the bind address |

Routes:

| Route | What |
|---|---|
| `GET /healthz` | the runner's liveness probe |
| `WS /player?slot=<i>&token=<t>` | one seat; the token is checked against the configured roster |
| `WS /global` | the spectator status feed; one JSON state object per frame |
| `GET /client/player?slot&token` | served for real, token-checked, and it does **not** open the player socket |
| `GET /client/global` | served for real |
| `GET /client/replay` | the developer-local broadcast page (never declared to the platform) |
| `GET /client/*` | the font and the muster-room art |
| `GET /replay-data` | the recorded bytes, for local tooling |

Both `/client` routes are registered **before** any catch-all asset route, and
`/healthz` and `/global` keep answering for a bounded 20 s grace after the
artifacts are written — the certifier pings them **after** the player pods start,
and a short episode can already have finished by then.

The serve thread runs independently of the game loop, so a 14 s LLM stall cannot
drop a connection or stall `/healthz`. Global broadcasts are fire and forget, so
a slow viewer can never stall the episode.

## The seat

`/bin/magent-battle-player` is deliberately thin. It dials its seat with bounded
retries, sends ONE Sprite v1 chat message carrying its registration, and then only
receives:

```json
{"policy": "<label>", "prompt": "<PLAYER_PROMPT or empty>",
 "scripted": "line" | "pincer" | null}
```

`prompt` is rune-truncated at 4000 runes and `policy` at 64. Every decision is
made **inside the game server**, because that is the only container the platform
injects the `anthropic_api_key` coworld secret into.

Two details are scar tissue, not style:

- **The registration is re-sent** for the first ~10 s of received frames. Joins
  are slot-sequential, and the lobby sends frames to a socket before it is
  admitted, so a first registration can land while the seat has no index yet.
- **The seat exits 0 on a dead socket.** whisky's `receiveMessage` raises on a
  close frame and mummy's `send` only queues, so the game's own `quit(0)` can
  outrun the flushed frame. Exiting 1 there fails certification intermittently.

A seat's chat is its **registration** and nothing else: it is consumed by the
server, never applied as a shout and never written to the replay chat stream (the
prompt is a secret). What the replay gets is a redacted `register` record with the
policy label and kind only. Any other chat text from a seat is dropped —
commanders speak through `say`, seats do not shout.

## The observation

A JSON object appended to the user message, and mirrored (minus `your_notes`)
into the replay's `directive` record so the replay explains every decision.

```json
{
  "you": "Alpha", "opponent": "Bravo",
  "game": 1, "of_games": 2, "your_side": "red",
  "turn": 7, "of": 15, "tick": 120, "turn_ticks": 20, "ticks_left": 180,
  "map": {"width": 45, "height": 45},
  "soldier": {"hp_max": "10.0", "damage": "2.0", "recover_per_tick": "0.1",
              "move_up_to": 2, "attack_reach": 1, "view_radius": 6},
  "your_army": {"alive": 63, "started": 81, "lost_last_turn": 4,
    "squads": [{"id": "A1", "alive": 9, "x": 12, "y": 30, "hp": "9.4",
                "order": "advance"}]},
  "enemy": {"visible_soldiers": 22, "killed_last_turn": 6,
    "squads": [{"id": "B1", "seen": 6, "x": 30, "y": 28, "hp": "6.1",
                "last_seen_turn": 7},
               {"id": "B7", "seen": 0, "x": null, "y": null, "hp": null,
                "last_seen_turn": null}]},
  "score_now": 3,
  "your_notes": "wrapping their left with A7-A9"
}
```

All nine squads of each side are always listed, in id order, so the array shape
never changes. `x`/`y` are the integer centroid of the living, visible members;
`hp` is their mean in upstream units to one decimal; `seen` is the count of
currently visible enemy members; `last_seen_turn` is `null` if that squad has
never been seen.

**Hidden**: the positions and hp of unseen enemy soldiers, every enemy squad's
order, the opponent's `notes`, the opponent's real player name and policy name,
the opponent's fallback and decision statistics, and the other game's result
while a game is in progress. Nothing about the opponent's identity ever reaches a
prompt.

## The reply

```json
{"orders": [{"squad": "A1", "verb": "advance"},
            {"squad": "A2", "verb": "hold", "x": 22, "y": 30},
            {"squad": "A3", "verb": "focus", "target": "B5"},
            {"squad": "A4", "verb": "flank", "side": "left"},
            {"squad": "A5", "verb": "retreat"}],
 "say": "wrap their left, A2 holds the gap",
 "notes": "A7-A9 going wide; pull A2 back if it drops under 5 hp"}
```

| Field | Cap / domain |
|---|---|
| `orders` | <= 9 entries; entries beyond the ninth are dropped |
| `orders[].squad` | <= 2 runes; one of this seat's nine ids; duplicates: last wins |
| `orders[].verb` | <= 8 runes; `advance` \| `hold` \| `focus` \| `flank` \| `retreat`, lower-cased before matching |
| `orders[].x`, `.y` | required iff `hold`; clamped into `[0, mapSize)` |
| `orders[].target` | required iff `focus`; <= 2 runes; must be an **enemy** squad id |
| `orders[].side` | required iff `flank`; <= 5 runes; `left` \| `right` |
| `say` | <= 120 runes; spectator chatter, rendered in the feed |
| `notes` | <= 240 runes; private, echoed to this seat only next turn |
| whole reply | <= 8192 bytes read from the provider before parsing |
| `PLAYER_PROMPT` | <= 4000 runes at registration |

Unknown top-level keys are ignored. A missing `orders` with a present `say` is a
**usable** reply (every squad keeps its order). A reply that is not a JSON object,
or whose `orders` is not an array, is a parse failure — one retry, then the
`pincer` fallback. An individual malformed order is **repaired to that squad's
previous order**, not dropped, and counted in `ordersRejected`.

### Why a turn fell back

Every fallback is written to the replay as a `fallback` chat record carrying the
seat, the attempt and a `cause` from exactly this set:

| `cause` | The turn fell back because |
|---|---|
| `timeout` | the per-turn budget was exhausted before this attempt could start |
| `transport_error` | the request failed at the transport (connection, TLS, non-timeout curl error) |
| `parse_error` | a reply arrived and was not a usable directive after the retry |
| `throttled` | the provider answered 429 and no other candidate model was left, so the retry batch is skipped |
| `no_credentials` | no API key (or the provider rejected it), so the LLM leg is off |
| `budget_guard` | two more turns would not fit the wall-clock budget; the rest of the episode plays scripted |
| `disconnected` | the seat never joined, so nobody is issuing orders for that army |

`throttled` is a divergence from the design note's enum, which folded 429 into
`transport_error`; it is kept separate because a throttled episode and a broken
one need different answers. Nothing consumes the set as closed —
`tools/replay_summary.py` counts fallbacks and prints the causes it finds.

**Every string that lands in the replay** — `say`, `notes`, the policy label,
`stopDetail`, recorded error text — is truncated on **rune** boundaries. Byte
truncation is what makes a replay that renders in a browser fail a strict UTF-8
parser.

## The results document

Closed schema; `game.results_schema` in the manifest lists exactly these keys and
`tests/test_magent_manifest.nim` asserts the two agree.

```json
{
  "names": ["daveey", "daveey-1"], "aliases": ["Alpha", "Bravo"],
  "scores": [222, -222], "win": [true, false], "winner": 0,
  "reason": "complete", "games": 2, "gameWins": [2, 0],
  "survivors": [63, 12], "kills": [150, 99],
  "finalTick": 287, "turnsPlayed": 28, "seed": 1734029581,
  "magentReward": ["612.415", "-238.09"],
  "policyKinds": ["llm", "scripted"],
  "llmTurns": [28, 0], "fallbackTurns": [1, 0], "ordersRejected": [0, 0],
  "deadSeats": [false, false],
  "gameResults": [
    {"game": 1, "redSlot": 0, "survivors": [41, 0], "kills": [81, 40],
     "ticks": 287, "endRule": "wipe"},
    {"game": 2, "redSlot": 1, "survivors": [22, 12], "kills": [69, 59],
     "ticks": 300, "endRule": "tickCap"}
  ],
  "stopDetail": ""
}
```

`winner` is `0`, `1` or `null` (draw). `survivors`/`kills` are summed over the two
games; the per-game split is in `gameResults`. `reason` is a closed enum:
`complete` (both games ended by `wipe` or `tickCap`), `deadline` (the wall-clock
stop fired — declared acceptable, and the budget guard exists so it should never
happen), `fault` (an unexpected exception; the episode is settled from the last
completed tick, `stopDetail` names it, and the artifacts are still written).

Adding a key means updating `armyResultsJson`, the manifest's `results_schema` and
`tools/ci/docker_smoke.sh`'s expected-key set in the same commit — Coworld schemas
are closed and undeclared keys are dropped.

## The replay

`COWLDMAG` — magic, format version, game name and version, the **resolved config
JSON**, then a record stream and one `gameHash` per frame. Little-endian,
length-prefixed. Everything is re-derived from those bytes; no server is
contacted except S3 for the file.

| Content | Carries |
|---|---|
| header | magic `COWLDMAG`, format version, `magent-battle`, `gameVersion` |
| config JSON | seed, `num_agents`, `mapSize`, `maxTicks`, `maxGames`, `turnTicks`, every upstream constant, `players[].name` (real names), `slots[]`, `fastMode` |
| joins | per seat: name, slot, token |
| gameStart | per game: the frame, the game index, which seat holds red |
| orders | per turn, per seat: the nine accepted squad orders — this game's entire input log |
| chats | `register` / `directive` / `fallback` / `budget_guard` / `result` records |
| stop | the load-bearing wall-clock or fault stop |
| hashes | one `gameHash` per frame — the integrity chain the viewer checks |

The **stop is a record, not an inference**: a wall-clock fact cannot be
re-derived from sim state, so it is written once and applied by the *same proc*
(`sim.applyStop`) on record and on playback. `tests/test_magent_replay.nim` runs
the record -> re-derive check for **every** end reason, not just the healthy one.

`gameHash` mixes, in this fixed order: per soldier `(id, x, y, hp, alive)`; per
army `(aliveCount, killsDealt, magentRewardMilli)`; per squad
`(order kind, targetX, targetY, targetSquad, side)`; then `tick`, `gameIndex` and
`redSlot`.

### The derived event vocabulary

Nine kinds, derived from state deltas and the frame's chat records during
playback, so they cost no replay bytes and are identical live and in replay:

`turn {n, game}`, `order {slot, squad, verb, arg}`, `say {slot, text}`,
`fallback {slot, cause}`, `firstblood {slot, unit, victim}`,
`kill {a, v, cell}`, `rout {army, lost}`, `wipe {army}`,
`end {reason, winner, survivors}`.

Only `firstblood`, `rout`, `wipe`, `fallback` and `end` become scrubber **beats**;
`kill`, `turn`, `order` and `say` drive the feed — forty-plus kill markers would
make the scrubber unreadable.

### Reading a replay with no toolchain

```bash
curl -sSL "$replay_url" -o /tmp/ep.replay
python3 tools/replay_summary.py /tmp/ep.replay > /tmp/ep.json
jq -e . /tmp/ep.json >/dev/null                       # strict UTF-8 JSON: ok
jq -r '.protocol, .results.reason, .results.kills[0]' /tmp/ep.json
jq -r '[.directives[]|select(.source=="llm")]|length, .fallbacks' /tmp/ep.json
```
