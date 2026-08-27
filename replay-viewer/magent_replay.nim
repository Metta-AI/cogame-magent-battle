## The wasm replay entry. Keeps the starter's wasm-entry structure
## exactly: the `stampStage` fixed progress buffer that survives an allocation
## abort, `bytesFromPointer`, the try/except publishing `lastError`, and the
## `emscripten_exit_with_live_runtime()` epilogue that stops Nim's generated
## `main` from running module destructors while JS keeps calling in.
##
## It imports the SAME `magent/sim` the native server runs, so the browser
## re-derives every frame from the recorded orders and compares the per-tick
## `gameHash` against the recording -- one divergent bit is caught at the tick
## it happens and surfaced as `mismatchTick` in #mmwarn.

import std/json
import magent/[broadcast, replay_runtime, replays, roster, sim]

var
  runtimeLoaded = false
  player: ReplayPlayer
  game: SimServer
  tracker: BroadcastTracker
  packet: string
  lastError: string

## --- Progress stage note ---
## wasm32 has no memory protection: when emscripten's malloc fails, a write
## through the nil pointer lands at address 0 and silently corrupts the
## module's own globals instead of trapping. The bundle is therefore linked
## with -s ABORTING_MALLOC=1 -- allocation failure aborts the runtime loudly --
## and this fixed buffer, stamped BEFORE each risky phase, stays readable from
## JS after the abort (aborting kills the call stack, not linear memory), so
## the page can still report what the runtime was doing.
var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string
  frameStage: string

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc renderCurrent(events: JsonNode) =
  packet = buildStateJson(game, player, tracker, events, live = false)

proc magentLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "magent_load_replay", cdecl.} =
  try:
    lastError = ""
    stampStage("parse replay")
    let replayData = parseReplayBytes(data.bytesFromPointer(int(length)))
    stampStage("pre-scan the episode")
    ## The load-time PRE-SCAN re-simulates the whole episode once headlessly
    ## (integer work over a couple of hundred frames -- single-digit
    ## milliseconds in wasm), recording the per-frame alive counts, the lull
    ## spans and the beat ticks, then resets and renders frame 0. That is what
    ## lets the unit-count sparkline and the scrubber beats draw at FULL WIDTH
    ## on the first frame instead of growing in.
    var initialized = initReplayRuntime(replayData, mismatchQuit = false)
    game = move(initialized.sim)
    player = move(initialized.player)
    game.applyJoinRecords(replayData)
    for record in replayData.chats:
      game.applyReplayChat(record.text)
    tracker = initBroadcastTracker()
    runtimeLoaded = true
    let note = " (board " & $game.units.mapSize & "x" & $game.units.mapSize &
      ", " & $player.maxFrame & " frames)"
    frameStage = "advance replay" & note
    stampStage("render first frame" & note)
    renderCurrent(newJArray())
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = currentStage & ": " & error.msg & "\n" & error.getStackTrace()
    return 0

proc magentInput(data: ptr uint8, length: cint)
    {.exportc: "magent_input", cdecl.} =
  if runtimeLoaded:
    try:
      player.applyCommand(game, data.bytesFromPointer(int(length)))
    except Exception as error:
      lastError = "apply input: " & error.msg

proc magentFrame(): cint {.exportc: "magent_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  stampStage(frameStage)
  try:
    player.advanceReplayFrame(game)
    renderCurrent(stepEvents(game, tracker, player.pending))
    return 1
  except Exception as error:
    lastError = "advance replay: " & error.msg & "\n" & error.getStackTrace()
    return -1

proc magentPacketPointer(): ptr uint8
    {.exportc: "magent_packet_ptr", cdecl.} =
  if packet.len == 0: nil else: cast[ptr uint8](packet[0].addr)

proc magentPacketLength(): cint {.exportc: "magent_packet_len", cdecl.} =
  cint(packet.len)

proc magentMismatchTick(): cint {.exportc: "magent_mismatch_tick", cdecl.} =
  if runtimeLoaded: cint(player.hashMismatchTick) else: -1

proc magentErrorPointer(): ptr uint8 {.exportc: "magent_error_ptr", cdecl.} =
  if lastError.len == 0: nil else: cast[ptr uint8](lastError[0].addr)

proc magentErrorLength(): cint {.exportc: "magent_error_len", cdecl.} =
  cint(lastError.len)

proc magentStagePointer(): ptr uint8 {.exportc: "magent_stage_ptr", cdecl.} =
  ## Unlike magent_error_*, this stays valid after an allocation-failure abort,
  ## so JS can report what the runtime was doing when it happened.
  if stageNoteLen == 0: nil else: cast[ptr uint8](stageNote[0].addr)

proc magentStageLength(): cint {.exportc: "magent_stage_len", cdecl.} =
  cint(stageNoteLen)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  # Nim's generated main runs every module-global destructor when it returns,
  # freeing the sim, the replay data and the packet buffer -- everything --
  # while the wasm module stays alive and JS keeps calling magent_load_replay /
  # magent_frame. Unwinding main through emscripten's live-runtime exit skips
  # the destructor epilogue entirely, so globals stay valid for the life of the
  # page.
  emscriptenExitWithLiveRuntime()
