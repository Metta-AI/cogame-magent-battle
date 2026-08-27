# Board art

The board sprites are **nano-banana renders of the Softmax cog**, one kit per
army, generated with `gemini-2.5-flash-image` from the starter's own
`data/soldier_red.png` as the style anchor. The source render and the script
that turns it into sprites are both committed, so the assets are reproducible
rather than mysterious. CI does not regenerate art.

| File | What it is |
|---|---|
| `scripts/art/source/soldiers_sheet.png` | the single nano-banana render: the two armies' infantry cog side by side on a flat chroma backdrop |
| `scripts/art/split_cog_sheet.py` | key -> split -> trim -> pad -> resize to 128 px |
| `data/unit_red.png`, `data/unit_blue.png` | the derived board sprites the viewer bakes its chips from |
| `data/soldier_red.png`, `data/soldier_blue.png` | the starter's own cog art, carried BYTE FOR BYTE as the fallback |
| `data/arena_floor.png` | the starter's floor plate, tiled and darkened 18 % at load |
| `client/art/lockerroom/*` | the starter's muster-room curtain, red and blue cogs only |

Regenerate:

```bash
python3 -m pip install --user pillow
python3 scripts/art/split_cog_sheet.py
```

The prompt used for the sheet (one call, both armies in one render so the style
cannot drift between them):

> Using this wheeled robot character ("cog") as the exact character design
> reference, draw TWO of these cogs side by side in one row, evenly spaced, same
> size, full body, TOP-DOWN overhead view, same clean cartoon rendering, crisp
> readable silhouette at very small size. Background: perfectly flat, solid,
> uniform pure bright green (#00FF00), no shadows, no gradients, no floor - it
> will be chroma-keyed out. LEFT - RED ARMY INFANTRY: warm red (#E0523A)
> plating, a small dark rectangular back-plate, a short stubby weapon arm.
> RIGHT - BLUE ARMY INFANTRY: cool blue (#3F7CC4) plating, identical silhouette
> and pose to the left one, mirrored colour scheme only. The two must be
> IDENTICAL in shape and size and differ ONLY in colour: they are the two armies
> of the same infantry unit. No text, no labels, no numbers, no shields, no
> capes.

The key is passed as the header `x-goog-api-key: $GEMINI_API_KEY` and is never
written to a file, a URL or a log.

## Why chips, not a rig

Each sprite is baked ONCE at load into three chip sizes (6, 10 and 16 px) with a
1 px team rim and three hp-brightness bands -- 18 pre-baked chips -- so drawing
162 soldiers a frame is 162 blits and never a per-soldier rasterisation. At the
360 px featured-match embed a 45x45 board is 8 px per cell, which is a 6 px chip
with a 1 px rim and a 1 px gutter: a 128 px articulated rig would be invisible
there and would cost 162 rasterisations a frame to prove it.
