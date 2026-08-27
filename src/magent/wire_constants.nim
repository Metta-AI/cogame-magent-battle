## The JS wire-constants block: the handful of engine constants the browser
## chrome must agree with (playback speeds, the playback tick rate, the rune
## caps the text layout reserves room for). Rendered ONCE, from the same Nim
## consts the engine runs on; server.nim splices the block into every served
## client page and tools/gen_wire_constants.nim emits it for the static wasm
## bundle. Clients read `window.MAGENT_WIRE`.

import std/strutils
import sim_types, replay_runtime

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, v in values:
    if i > 0: result.add ","
    result.add $v
  result.add "]"

const WireConstantsJs* =
  "window.MAGENT_WIRE={speeds:" & jsIntArray(PlaybackSpeeds) &
  ",fps:" & $TargetFps &
  ",tickRate:" & $TicksPerSecondBase &
  ",maxSayRunes:" & $MaxSayRunes &
  ",maxUnits:" & $MaxUnits &
  ",squads:" & $SquadCount &
  ",gameVersion:\"" & GameVersion & "\"" &
  "};"

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"
  ## The placeholder the client HTML carries where the block belongs (before
  ## any script that reads window.MAGENT_WIRE).

proc spliceWireConstants*(page: string): string =
  ## Replaces the marker with the inline constants script. A page without the
  ## marker passes through unchanged.
  page.replace(WireConstantsMarker,
    "<script>" & WireConstantsJs & "</script>")
