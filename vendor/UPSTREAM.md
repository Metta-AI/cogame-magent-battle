# Upstream provenance

The rules this coworld reproduces are **MAgent2's `battle_v4`**.

| Field | Value |
|---|---|
| Repo | `Farama-Foundation/MAgent2` |
| Path | `magent2/environments/battle/battle.py` |
| Commit | `0d2e0e344fa84411eeba4baf03dc3b7273c4f14d` |
| Fetch URL | `https://raw.githubusercontent.com/Farama-Foundation/MAgent2/0d2e0e344fa84411eeba4baf03dc3b7273c4f14d/magent2/environments/battle/battle.py` |
| sha256 | `c5f589f0d81437bd55c3381b2bcf23a09b8f200f1049e84464cb3f20e26c37ed` |

`vendor/upstream/battle.py` is **byte-pristine** and is never edited. Verify it:

```bash
sha256sum vendor/upstream/battle.py
# c5f589f0d81437bd55c3381b2bcf23a09b8f200f1049e84464cb3f20e26c37ed
```

Every constant the game runs on is written down once, in
`src/magent/upstream.nim`, each beside the upstream line it came from.
`tests/test_magent_upstream.nim` regex-parses the vendored file and asserts
byte-equality against every one of them, so a re-vendor that changes a number
**fails tests** instead of silently desyncing the game.

To re-vendor: fetch the new file, update the commit and sha256 above, run the
tests, and record any behavioural change in `vendor/PATCHES.md` together with a
`GameVersion` bump in `src/magent/sim_types.nim`.

The upstream licence is in `vendor/LICENSE-magent2`.
